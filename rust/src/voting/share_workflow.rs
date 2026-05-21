use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use rand::{RngCore, rngs::OsRng};
use zcash_voting as voting;

use crate::{unwrap_exc_or_null, voting::share_tracking::JsonShareDelegationRecord};

use super::helpers::{bytes_from_ptr, json_to_boxed_slice};

/// Plan the share mode for the current round timing.
///
/// Returns JSON-encoded `ShareModePlan`, or null on error.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_voting_plan_share_mode(
    now_seconds: u64,
    ceremony_start_seconds: u64,
    vote_end_time_seconds: u64,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let plan = voting::share_workflow::plan_share_mode(
            now_seconds,
            ceremony_start_seconds,
            vote_end_time_seconds,
        );
        json_to_boxed_slice(&plan)
    });
    unwrap_exc_or_null(res)
}

/// Plan per-share `submit_at` values.
///
/// Returns JSON-encoded `Vec<u64>`, or null on error.
///
/// # Safety
///
/// - `mode_json` must be valid JSON for `ShareModePlan`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_plan_share_submit_times(
    share_count: usize,
    now_seconds: u64,
    vote_end_time_seconds: u64,
    mode_json: *const u8,
    mode_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let mode_bytes = unsafe { bytes_from_ptr(mode_json, mode_json_len) }?;
        let mode: voting::share_workflow::ShareModePlan = serde_json::from_slice(mode_bytes)?;
        let entropy_len = voting::share_workflow::share_submit_time_entropy_bytes_per_share()
            .checked_mul(share_count)
            .ok_or_else(|| anyhow!("submit_at entropy length overflows usize"))?;
        let mut entropy = vec![0u8; entropy_len];
        OsRng.fill_bytes(&mut entropy);
        let submit_times = voting::share_workflow::plan_share_submit_times(
            share_count,
            now_seconds,
            vote_end_time_seconds,
            mode,
            &entropy,
        )
        .map_err(|e| anyhow!("plan_share_submit_times failed: {}", e))?;
        json_to_boxed_slice(&submit_times)
    });
    unwrap_exc_or_null(res)
}

/// Plan a share tracking pass for wallet-side polling.
///
/// Returns JSON-encoded `ShareTrackingPlan`, or null on error.
///
/// # Safety
///
/// - `shares_json` must be a JSON array of share delegation records.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_plan_share_tracking(
    shares_json: *const u8,
    shares_json_len: usize,
    now_seconds: u64,
    vote_end_time_seconds: u64,
) -> *mut crate::ffi::BoxedSlice {
    let shares_json = AssertUnwindSafe(shares_json);
    let res = catch_panic(|| {
        let shares_bytes = unsafe { bytes_from_ptr(*shares_json, shares_json_len) }?;
        let json_records: Vec<JsonShareDelegationRecord> = serde_json::from_slice(shares_bytes)?;
        let shares: Vec<voting::ShareDelegationRecord> = json_records
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<_, _>>()?;
        let plan = voting::share_workflow::plan_share_tracking(
            &shares,
            now_seconds,
            vote_end_time_seconds,
        );
        json_to_boxed_slice(&plan)
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use serde::de::DeserializeOwned;

    use super::*;
    use crate::ffi::zcashlc_free_boxed_slice;

    fn decode_boxed_json<T: DeserializeOwned>(ptr: *mut crate::ffi::BoxedSlice) -> T {
        assert!(!ptr.is_null());
        let json = unsafe { (*ptr).as_slice() }.to_vec();
        let value = serde_json::from_slice(&json).expect("decode boxed JSON");
        unsafe { zcashlc_free_boxed_slice(ptr) };
        value
    }

    fn share_json(submit_at: u64, created_at: u64, confirmed: bool) -> JsonShareDelegationRecord {
        JsonShareDelegationRecord {
            round_id: "round".to_string(),
            bundle_index: 0,
            proposal_id: 1,
            share_index: 2,
            sent_to_urls: vec!["https://helper.example.com".to_string()],
            nullifier: "00".repeat(32),
            confirmed,
            submit_at,
            created_at,
        }
    }

    #[test]
    fn plan_share_mode_returns_json_plan() {
        let ptr = zcashlc_voting_plan_share_mode(1_000, 0, 2_000);
        let plan: voting::share_workflow::ShareModePlan = decode_boxed_json(ptr);

        assert!(!plan.single_share);
        assert_eq!(plan.last_moment_buffer_seconds, Some(800));
        assert_eq!(plan.submit_at_delay_seconds, Some(200));
    }

    #[test]
    fn plan_share_submit_times_uses_internal_entropy() {
        let mode = voting::share_workflow::plan_share_mode(1_000, 0, 2_000);
        let mode_json = serde_json::to_vec(&mode).expect("mode json");
        let ptr = unsafe {
            zcashlc_voting_plan_share_submit_times(
                2,
                1_000,
                2_000,
                mode_json.as_ptr(),
                mode_json.len(),
            )
        };
        let submit_times: Vec<u64> = decode_boxed_json(ptr);

        assert_eq!(submit_times.len(), 2);
        assert!(
            submit_times
                .iter()
                .all(|value| (1_000..1_200).contains(value))
        );
    }

    #[test]
    fn plan_share_tracking_returns_ready_and_overdue_keys() {
        let shares = vec![share_json(1_000, 900, false), share_json(0, 900, true)];
        let shares_json = serde_json::to_vec(&shares).expect("shares json");
        let ptr = unsafe {
            zcashlc_voting_plan_share_tracking(
                shares_json.as_ptr(),
                shares_json.len(),
                1_100,
                1_400,
            )
        };
        let plan: voting::share_workflow::ShareTrackingPlan = decode_boxed_json(ptr);

        assert_eq!(plan.summary.total, 2);
        assert_eq!(plan.summary.confirmed, 1);
        assert_eq!(plan.ready_share_keys.len(), 1);
        assert_eq!(plan.overdue_share_keys, plan.ready_share_keys);
        assert_eq!(plan.next_delay_seconds, Some(15));
    }
}
