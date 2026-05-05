use serde::{Deserialize, Serialize};
use zcash_voting as voting;

/// JSON-serializable mirror of `zcash_voting::DelegationPirPrecomputeResult`.
/// Used by future stateful PIR FFIs (`precompute_delegation_pir`).
#[allow(dead_code)]
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonDelegationPirPrecomputeResult {
    pub cached_count: u32,
    pub fetched_count: u32,
}

impl From<voting::DelegationPirPrecomputeResult> for JsonDelegationPirPrecomputeResult {
    fn from(r: voting::DelegationPirPrecomputeResult) -> Self {
        Self {
            cached_count: r.cached_count,
            fetched_count: r.fetched_count,
        }
    }
}
