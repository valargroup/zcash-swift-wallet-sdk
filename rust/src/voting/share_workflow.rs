use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;

use crate::unwrap_exc_or_null;

use super::helpers::{bytes_from_ptr, json_to_boxed_slice};

/// Return the random byte count required to apply a share workflow request.
///
/// `request_json` must be a JSON-encoded `ShareWorkflowRequest` from
/// `zcash_voting::share_workflow`. Returns a JSON-encoded unsigned integer, or
/// null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_share_workflow_random_bytes_required(
    request_json: *const u8,
    request_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let request_bytes = unsafe { bytes_from_ptr(request_json, request_json_len) }?;
        let request: voting::share_workflow::ShareWorkflowRequest =
            serde_json::from_slice(request_bytes)?;
        let required = voting::share_workflow::share_workflow_random_bytes_required(&request)
            .map_err(|e| anyhow!("share_workflow_random_bytes_required failed: {}", e))?;
        let required = u64::try_from(required)
            .map_err(|_| anyhow!("random byte count does not fit in u64"))?;
        json_to_boxed_slice(&required)
    });
    unwrap_exc_or_null(res)
}

/// Apply a share workflow request and return the host actions to execute.
///
/// `request_json` must be a JSON-encoded `ShareWorkflowRequest` from
/// `zcash_voting::share_workflow`. `random_bytes` must contain the count
/// returned by `zcashlc_voting_share_workflow_random_bytes_required` for the
/// same request. Returns JSON-encoded `ShareWorkflowResponse`, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_apply_share_workflow(
    request_json: *const u8,
    request_json_len: usize,
    random_bytes: *const u8,
    random_bytes_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let request_bytes = unsafe { bytes_from_ptr(request_json, request_json_len) }?;
        let random_bytes = unsafe { bytes_from_ptr(random_bytes, random_bytes_len) }?;
        let request: voting::share_workflow::ShareWorkflowRequest =
            serde_json::from_slice(request_bytes)?;
        let response = voting::share_workflow::apply_share_workflow_request(request, random_bytes)
            .map_err(|e| anyhow!("apply_share_workflow failed: {}", e))?;
        json_to_boxed_slice(&response)
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use serde::de::DeserializeOwned;
    use serde_json::json;
    use zcash_voting as voting;

    use super::*;

    fn decode_boxed_json<T: DeserializeOwned>(ptr: *mut crate::ffi::BoxedSlice) -> T {
        assert!(!ptr.is_null(), "expected non-null BoxedSlice");
        let slice = unsafe { (*ptr).as_slice() };
        let value = serde_json::from_slice(slice).expect("json");
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) };
        value
    }

    #[test]
    fn share_workflow_ffi_plans_delivery_actions() {
        let request = json!({
            "kind": "start_delivery",
            "shares": [{
                "key": {
                    "round_id": "aabb",
                    "bundle_index": 0,
                    "proposal_id": 1,
                    "share_index": 0
                },
                "submit_at": 100,
                "target_count": 1,
                "target_servers": ["https://one.example.com"]
            }],
            "available_server_urls": ["https://one.example.com"]
        });
        let request = serde_json::to_vec(&request).unwrap();
        let ptr = unsafe {
            zcashlc_voting_apply_share_workflow(request.as_ptr(), request.len(), [].as_ptr(), 0)
        };
        let response: voting::share_workflow::ShareWorkflowResponse = decode_boxed_json(ptr);
        assert!(matches!(
            response.actions.first(),
            Some(voting::share_workflow::ShareWorkflowAction::PostShare { .. })
        ));
    }
}
