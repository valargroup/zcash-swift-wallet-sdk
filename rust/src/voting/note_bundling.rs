use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;

use crate::unwrap_exc_or_null;

use super::helpers::{bytes_from_ptr, json_to_boxed_slice};
use super::json::JsonNoteInfo;

/// Plan value-aware note bundles using the shared `zcash_voting` policy.
///
/// `notes_json` must be a JSON-encoded `Vec<NoteInfo>`.
///
/// Returns JSON-encoded `BundlePlan`, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_plan_note_bundles(
    notes_json: *const u8,
    notes_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let notes_bytes = unsafe { bytes_from_ptr(notes_json, notes_json_len) }?;
        let json_notes: Vec<JsonNoteInfo> = serde_json::from_slice(notes_bytes)
            .map_err(|e| anyhow!("invalid bundle notes JSON: {}", e))?;
        let core_notes: Vec<voting::NoteInfo> = json_notes.into_iter().map(Into::into).collect();
        let plan = voting::note_bundling::plan_note_info_bundles(&core_notes);
        json_to_boxed_slice(&plan)
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use serde::Serialize;
    use serde::de::DeserializeOwned;

    use super::*;

    fn decode_boxed_json<T: DeserializeOwned>(ptr: *mut crate::ffi::BoxedSlice) -> T {
        assert!(!ptr.is_null(), "expected non-null BoxedSlice");
        let slice = unsafe { (*ptr).as_slice() };
        let value = serde_json::from_slice(slice).expect("json");
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) };
        value
    }

    fn json_bytes<T: Serialize>(value: &T) -> Vec<u8> {
        serde_json::to_vec(value).expect("json")
    }

    fn note(value: u64, position: u64) -> JsonNoteInfo {
        JsonNoteInfo {
            commitment: vec![1; 32],
            nullifier: vec![2; 32],
            value,
            position,
            diversifier: vec![3; 11],
            rho: vec![4; 32],
            rseed: vec![5; 32],
            scope: 0,
            ufvk_str: "uview-test".to_string(),
        }
    }

    #[test]
    fn note_bundling_uses_shared_plan() {
        let notes = json_bytes(&vec![
            note(50_000_000, 10),
            note(13_000_000, 0),
            note(50_000_000, 12),
            note(13_000_000, 1),
            note(50_000_000, 11),
            note(13_000_000, 2),
            note(50_000_000, 14),
            note(13_000_000, 3),
            note(50_000_000, 13),
            note(13_000_000, 4),
        ]);

        let plan: voting::note_bundling::BundlePlan = decode_boxed_json(unsafe {
            zcashlc_voting_plan_note_bundles(notes.as_ptr(), notes.len())
        });

        assert_eq!(plan.bundles.len(), 2);
        assert_eq!(plan.eligible_weight, 312_500_000);
        assert_eq!(plan.dropped_count, 0);
        assert_eq!(
            plan.bundles[0]
                .iter()
                .map(|note| note.position)
                .collect::<Vec<_>>(),
            vec![10, 11, 12, 13, 14]
        );
    }

    #[test]
    fn note_bundling_rejects_invalid_json() {
        let ptr = unsafe { zcashlc_voting_plan_note_bundles(b"not-json".as_ptr(), 8) };
        assert!(ptr.is_null());
    }
}
