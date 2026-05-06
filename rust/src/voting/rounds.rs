//! Round and vote-record FFI (`[T2.H]` Swift surface).
//!
//! Prototype: JSON in/out across the C boundary, matching `zcash_voting::storage::VotingDb`
//! round APIs. Swift decodes with `VotingTypes` once `[#1706]` lands.

use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use serde::{Deserialize, Serialize};
use zcash_voting::types::{NoteInfo, VotingRoundParams, validate_round_params};

use crate::ffi::BoxedSlice;
use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, str_from_ptr};

#[derive(Debug, Deserialize)]
struct JsonVotingRoundParams {
    vote_round_id: String,
    snapshot_height: u64,
    ea_pk: Vec<u8>,
    nc_root: Vec<u8>,
    nullifier_imt_root: Vec<u8>,
}

#[derive(Debug, Deserialize, Serialize)]
struct JsonNoteInfo {
    commitment: Vec<u8>,
    nullifier: Vec<u8>,
    value: u64,
    position: u64,
    diversifier: Vec<u8>,
    rho: Vec<u8>,
    rseed: Vec<u8>,
    scope: u32,
    ufvk_str: String,
}

impl From<JsonNoteInfo> for NoteInfo {
    fn from(n: JsonNoteInfo) -> Self {
        NoteInfo {
            commitment: n.commitment,
            nullifier: n.nullifier,
            value: n.value,
            position: n.position,
            diversifier: n.diversifier,
            rho: n.rho,
            rseed: n.rseed,
            scope: n.scope,
            ufvk_str: n.ufvk_str,
        }
    }
}

#[derive(Debug, Serialize)]
struct JsonRoundState {
    round_id: String,
    phase: i32,
    snapshot_height: u64,
    hotkey_address: Option<String>,
    delegated_weight: Option<u64>,
    proof_generated: bool,
}

#[derive(Debug, Serialize)]
struct JsonRoundSummary {
    round_id: String,
    wallet_id: String,
    phase: i32,
    snapshot_height: u64,
    created_at: u64,
}

#[derive(Debug, Serialize)]
struct JsonVoteRecord {
    proposal_id: u32,
    bundle_index: u32,
    choice: u32,
    submitted: bool,
}

#[derive(Debug, Serialize)]
struct JsonSetupBundlesResult {
    bundle_count: u32,
    eligible_weight: u64,
}

#[derive(Debug, Serialize)]
struct JsonBundleCount {
    bundle_count: u32,
}

#[derive(Debug, Serialize)]
struct JsonDeletedBundles {
    deleted: u64,
}

fn voting_err(e: zcash_voting::types::VotingError) -> anyhow::Error {
    anyhow!("{}", e)
}

fn encode_json<T: Serialize>(v: &T) -> anyhow::Result<*mut BoxedSlice> {
    let bytes = serde_json::to_vec(v)?;
    Ok(BoxedSlice::some(bytes))
}

/// Initialize a voting round from JSON `VotingRoundParams`.
///
/// Returns `0` on success, `-1` on error.
///
/// # Safety
///
/// See `VotingDatabaseHandle` and `bytes_from_ptr` / `str_from_ptr` contracts.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_init_round(
    db: *mut VotingDatabaseHandle,
    params_json: *const u8,
    params_json_len: usize,
    session_json: *const u8,
    session_json_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let params_bytes = unsafe { bytes_from_ptr(params_json, params_json_len)? };
        let json: JsonVotingRoundParams = serde_json::from_slice(params_bytes)?;
        let params = VotingRoundParams {
            vote_round_id: json.vote_round_id,
            snapshot_height: json.snapshot_height,
            ea_pk: json.ea_pk,
            nc_root: json.nc_root,
            nullifier_imt_root: json.nullifier_imt_root,
        };
        validate_round_params(&params).map_err(voting_err)?;
        let session = if session_json_len == 0 {
            None
        } else {
            Some(unsafe { str_from_ptr(session_json, session_json_len)? })
        };
        handle
            .db
            .init_round(&params, session)
            .map_err(voting_err)?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Returns JSON [`JsonRoundState`] or null on error. Free with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_round_state(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> *mut BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len)? };
        let s = handle.db.get_round_state(round_id).map_err(voting_err)?;
        let out = JsonRoundState {
            round_id: s.round_id,
            phase: s.phase as i32,
            snapshot_height: s.snapshot_height,
            hotkey_address: s.hotkey_address,
            delegated_weight: s.delegated_weight,
            proof_generated: s.proof_generated,
        };
        encode_json(&out)
    });
    unwrap_exc_or_null(res)
}

/// Returns JSON `Vec<JsonRoundSummary>` or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_list_rounds(db: *mut VotingDatabaseHandle) -> *mut BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let list = handle.db.list_rounds().map_err(voting_err)?;
        let out: Vec<JsonRoundSummary> = list
            .into_iter()
            .map(|r| JsonRoundSummary {
                round_id: r.round_id,
                wallet_id: r.wallet_id,
                phase: r.phase as i32,
                snapshot_height: r.snapshot_height,
                created_at: r.created_at,
            })
            .collect();
        encode_json(&out)
    });
    unwrap_exc_or_null(res)
}

/// Returns JSON `Vec<JsonVoteRecord>` or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_votes(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> *mut BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len)? };
        let votes = handle.db.get_votes(round_id).map_err(voting_err)?;
        let out: Vec<JsonVoteRecord> = votes
            .into_iter()
            .map(|v| JsonVoteRecord {
                proposal_id: v.proposal_id,
                bundle_index: v.bundle_index,
                choice: v.choice,
                submitted: v.submitted,
            })
            .collect();
        encode_json(&out)
    });
    unwrap_exc_or_null(res)
}

/// Delete all data for a round. Returns `0` on success, `-1` on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_clear_round(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len)? };
        handle.db.clear_round(round_id).map_err(voting_err)?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// `notes_json`: JSON array of `JsonNoteInfo` (same shape as `zcash_voting::NoteInfo`).
///
/// Returns JSON [`JsonSetupBundlesResult`] or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_setup_bundles(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    notes_json: *const u8,
    notes_json_len: usize,
) -> *mut BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len)? };
        let notes_bytes = unsafe { bytes_from_ptr(notes_json, notes_json_len)? };
        let parsed: Vec<JsonNoteInfo> = serde_json::from_slice(notes_bytes)?;
        let notes: Vec<NoteInfo> = parsed.into_iter().map(Into::into).collect();
        let (bundle_count, eligible_weight) = handle
            .db
            .setup_bundles(round_id, &notes)
            .map_err(voting_err)?;
        encode_json(&JsonSetupBundlesResult {
            bundle_count,
            eligible_weight,
        })
    });
    unwrap_exc_or_null(res)
}

/// Returns JSON [`JsonBundleCount`] or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_bundle_count(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> *mut BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len)? };
        let n = handle.db.get_bundle_count(round_id).map_err(voting_err)?;
        encode_json(&JsonBundleCount {
            bundle_count: n,
        })
    });
    unwrap_exc_or_null(res)
}

/// Deletes bundle rows with index `>= keep_count`. Returns JSON [`JsonDeletedBundles`]
/// (`deleted` row count) or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_delete_skipped_bundles(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    keep_count: u32,
) -> *mut BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len)? };
        let deleted = handle
            .db
            .delete_skipped_bundles(round_id, keep_count)
            .map_err(voting_err)?;
        encode_json(&JsonDeletedBundles { deleted })
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::super::db::{
        zcashlc_voting_db_free, zcashlc_voting_db_open, zcashlc_voting_set_wallet_id,
    };
    use super::*;
    use crate::ffi::{BoxedSlice, zcashlc_free_boxed_slice};

    /// Mirrors `ffi::BoxedSlice` layout (`#[repr(C)]` ptr + len) for test-only reads.
    #[repr(C)]
    struct RawBoxedSlice {
        ptr: *mut u8,
        len: usize,
    }

    fn open_memory_db() -> *mut VotingDatabaseHandle {
        let path = b":memory:";
        let db = unsafe { zcashlc_voting_db_open(path.as_ptr(), path.len()) };
        assert!(!db.is_null());
        let wid = b"proto-wallet";
        assert_eq!(
            unsafe { zcashlc_voting_set_wallet_id(db, wid.as_ptr(), wid.len()) },
            0
        );
        db
    }

    fn params_json(round_id: &str) -> Vec<u8> {
        serde_json::json!({
            "vote_round_id": round_id,
            "snapshot_height": 1000u64,
            "ea_pk": vec![0xEAu8; 32],
            "nc_root": vec![0xAAu8; 32],
            "nullifier_imt_root": vec![0xBBu8; 32],
        })
        .to_string()
        .into_bytes()
    }

    unsafe fn read_boxed_json(ptr: *mut BoxedSlice) -> serde_json::Value {
        assert!(!ptr.is_null());
        unsafe {
            let raw = &*(ptr as *const RawBoxedSlice);
            let sl = if raw.ptr.is_null() {
                &[][..]
            } else {
                std::slice::from_raw_parts(raw.ptr, raw.len)
            };
            let v: serde_json::Value = serde_json::from_slice(sl).unwrap();
            zcashlc_free_boxed_slice(ptr);
            v
        }
    }

    #[test]
    fn round_lifecycle_via_ffi() {
        let db = open_memory_db();
        let pj = params_json("test-round-ffi");
        assert_eq!(
            unsafe {
                zcashlc_voting_init_round(
                    db,
                    pj.as_ptr(),
                    pj.len(),
                    std::ptr::null(),
                    0,
                )
            },
            0
        );

        let rid = b"test-round-ffi";
        let st = unsafe { zcashlc_voting_get_round_state(db, rid.as_ptr(), rid.len()) };
        let j = unsafe { read_boxed_json(st) };
        assert_eq!(j["round_id"], "test-round-ffi");
        assert_eq!(j["phase"], 0);
        assert_eq!(j["snapshot_height"], 1000);

        let list = unsafe { zcashlc_voting_list_rounds(db) };
        let arr = unsafe { read_boxed_json(list) };
        assert_eq!(arr.as_array().unwrap().len(), 1);

        assert_eq!(
            unsafe { zcashlc_voting_clear_round(db, rid.as_ptr(), rid.len()) },
            0
        );
        let empty = unsafe { zcashlc_voting_list_rounds(db) };
        let arr2 = unsafe { read_boxed_json(empty) };
        assert!(arr2.as_array().unwrap().is_empty());

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn setup_bundles_via_ffi() {
        let db = open_memory_db();
        let pj = params_json("bundle-round");
        assert_eq!(
            unsafe { zcashlc_voting_init_round(db, pj.as_ptr(), pj.len(), std::ptr::null(), 0) },
            0
        );

        let notes: Vec<JsonNoteInfo> = (0..5)
            .map(|i| JsonNoteInfo {
                commitment: vec![1u8; 32],
                nullifier: vec![2u8; 32],
                value: 13_000_000,
                position: i,
                diversifier: vec![0u8; 11],
                rho: vec![0u8; 32],
                rseed: vec![0u8; 32],
                scope: 0,
                ufvk_str: String::new(),
            })
            .collect();
        let nj = serde_json::to_vec(&notes).unwrap();
        let rid = b"bundle-round";
        let out = unsafe {
            zcashlc_voting_setup_bundles(db, rid.as_ptr(), rid.len(), nj.as_ptr(), nj.len())
        };
        let j = unsafe { read_boxed_json(out) };
        assert_eq!(j["bundle_count"], 1);
        assert_eq!(j["eligible_weight"], 62_500_000u64);

        let bc = unsafe { zcashlc_voting_get_bundle_count(db, rid.as_ptr(), rid.len()) };
        let cj = unsafe { read_boxed_json(bc) };
        assert_eq!(cj["bundle_count"], 1);

        let del = unsafe { zcashlc_voting_delete_skipped_bundles(db, rid.as_ptr(), rid.len(), 0) };
        let dj = unsafe { read_boxed_json(del) };
        assert_eq!(dj["deleted"], 1u64);
        let bc2 = unsafe { zcashlc_voting_get_bundle_count(db, rid.as_ptr(), rid.len()) };
        let cj2 = unsafe { read_boxed_json(bc2) };
        assert_eq!(cj2["bundle_count"], 0);

        unsafe { zcashlc_voting_db_free(db) };
    }
}
