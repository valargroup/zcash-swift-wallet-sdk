//! Change note discovery — trial-decrypt compact actions from a spending transaction.
//!
//! The core function [`try_decrypt_compact_actions`] is designed to work with
//! both the RPC block download path (v1) and a future decryption PIR path (v2).
//! [`extract_actions_from_block`] is the v1-only data source that will be replaced
//! by decryption PIR queries in the future.

use anyhow::anyhow;
use orchard::keys::{FullViewingKey, PreparedIncomingViewingKey, Scope};
use orchard::note_encryption::{CompactAction, OrchardDomain};
use prost::Message;
use serde::Serialize;
use zcash_client_backend::proto::compact_formats::CompactBlock;
use zcash_note_encryption::try_compact_note_decryption;

/// A note discovered via trial decryption of compact actions.
///
/// Contains all the data needed to reconstruct the note for spending
/// once a witness is obtained via PIR.
#[derive(Serialize, Debug, Clone)]
pub(crate) struct DiscoveredNote {
    pub position: u64,
    pub diversifier: [u8; 11],
    pub value: u64,
    pub rseed: [u8; 32],
    pub rho: [u8; 32],
    pub nullifier: [u8; 32],
    pub cmx: [u8; 32],
}

/// Trial-decrypts compact actions using the given IVK and returns any wallet-owned notes.
///
/// This is the shared core that persists across v1 (RPC block download) and
/// future v2 (decryption PIR). It is agnostic to the data source that produced
/// the `(position, CompactAction)` pairs.
pub(crate) fn try_decrypt_compact_actions(
    ivk: &PreparedIncomingViewingKey,
    fvk: &FullViewingKey,
    actions: &[(u64, CompactAction)],
) -> Vec<DiscoveredNote> {
    let mut discovered = Vec::new();

    for (position, action) in actions {
        let domain = OrchardDomain::for_compact_action(action);

        if let Some((note, _recipient)) = try_compact_note_decryption(&domain, ivk, action) {
            let nf = note.nullifier(fvk);
            discovered.push(DiscoveredNote {
                position: *position,
                diversifier: *note.recipient().diversifier().as_array(),
                value: note.value().inner(),
                rseed: *note.rseed().as_bytes(),
                rho: note.rho().to_bytes(),
                nullifier: nf.to_bytes(),
                cmx: action.cmx().to_bytes(),
            });
        }
    }

    discovered
}

/// Tries both internal and external IVK scopes, returning all discovered notes.
///
/// Change notes use the internal scope, but we try both for completeness
/// (the spending transaction could also contain outputs to our external address).
pub(crate) fn discover_notes_both_scopes(
    fvk: &FullViewingKey,
    actions: &[(u64, CompactAction)],
) -> Vec<DiscoveredNote> {
    let mut all_discovered = Vec::new();

    for scope in [Scope::Internal, Scope::External] {
        let ivk = fvk.to_ivk(scope);
        let prepared_ivk = PreparedIncomingViewingKey::new(&ivk);
        let notes = try_decrypt_compact_actions(&prepared_ivk, fvk, actions);
        all_discovered.extend(notes);
    }

    all_discovered
}

/// Metadata about the spending transaction and block, extracted alongside compact actions.
#[derive(Debug, Clone)]
pub(crate) struct BlockTxMetadata {
    /// The 32-byte txid from CompactTx.hash.
    pub tx_hash: [u8; 32],
    /// The fee from CompactTx.fee (0 if unavailable).
    pub fee: u64,
    /// Unix epoch timestamp from CompactBlock.time.
    pub block_time: u32,
}

/// Result of extracting actions from a compact block: the actions themselves
/// plus metadata about the containing transaction and block.
#[derive(Debug)]
pub(crate) struct ExtractedActions {
    pub actions: Vec<(u64, CompactAction)>,
    pub metadata: Option<BlockTxMetadata>,
}

/// Extracts compact actions at specific tree positions from a serialized CompactBlock.
///
/// Given `first_output_position` and `action_count` (from [`SpendMetadata`]),
/// decodes the block, computes each action's global tree position, and returns
/// the actions in `[first_output_position, first_output_position + action_count)`
/// along with the spending transaction's metadata (txid, fee, block time).
///
/// This is the v1 data source (RPC block download). It will be replaced by
/// decryption PIR in v2.
pub(crate) fn extract_actions_from_block(
    block_bytes: &[u8],
    first_output_position: u32,
    action_count: u8,
) -> anyhow::Result<ExtractedActions> {
    if action_count == 0 {
        return Ok(ExtractedActions {
            actions: Vec::new(),
            metadata: None,
        });
    }

    let block = CompactBlock::decode(block_bytes)
        .map_err(|e| anyhow!("failed to decode CompactBlock: {e}"))?;

    let block_time = block.time;

    let chain_meta = block
        .chain_metadata
        .as_ref()
        .ok_or_else(|| anyhow!("CompactBlock missing chain_metadata"))?;

    let total_actions_in_block: u32 = block
        .vtx
        .iter()
        .map(|tx| tx.actions.len() as u32)
        .sum();

    let tree_size_at_block_start = chain_meta
        .orchard_commitment_tree_size
        .checked_sub(total_actions_in_block)
        .ok_or_else(|| {
            anyhow!(
                "invalid chain_metadata: orchard_commitment_tree_size ({}) < total actions ({})",
                chain_meta.orchard_commitment_tree_size,
                total_actions_in_block,
            )
        })?;

    let first_pos = first_output_position;
    let last_pos = first_pos
        .checked_add(u32::from(action_count))
        .ok_or_else(|| anyhow!("action range overflow"))?;

    if first_pos < tree_size_at_block_start
        || last_pos > chain_meta.orchard_commitment_tree_size
    {
        return Err(anyhow!(
            "requested range [{first_pos}, {last_pos}) outside block range [{}, {})",
            tree_size_at_block_start,
            chain_meta.orchard_commitment_tree_size,
        ));
    }

    let mut result = Vec::with_capacity(action_count as usize);
    let mut current_position = tree_size_at_block_start;
    let mut matched_tx_meta: Option<BlockTxMetadata> = None;

    for tx in &block.vtx {
        let tx_start_pos = current_position;
        let tx_end_pos = tx_start_pos + tx.actions.len() as u32;

        for proto_action in &tx.actions {
            if current_position >= first_pos && current_position < last_pos {
                let compact_action = CompactAction::try_from(proto_action).map_err(|_| {
                    anyhow!("invalid CompactOrchardAction at position {current_position}")
                })?;
                result.push((u64::from(current_position), compact_action));

                if matched_tx_meta.is_none() && first_pos >= tx_start_pos && first_pos < tx_end_pos {
                    if let Ok(tx_hash) = <[u8; 32]>::try_from(tx.hash.as_slice()) {
                        matched_tx_meta = Some(BlockTxMetadata {
                            tx_hash,
                            fee: u64::from(tx.fee),
                            block_time,
                        });
                    }
                }
            }
            current_position += 1;

            if result.len() == action_count as usize {
                return Ok(ExtractedActions {
                    actions: result,
                    metadata: matched_tx_meta,
                });
            }
        }
    }

    if result.len() != action_count as usize {
        return Err(anyhow!(
            "expected {} actions but found {} in block",
            action_count,
            result.len(),
        ));
    }

    Ok(ExtractedActions {
        actions: result,
        metadata: matched_tx_meta,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use orchard::keys::SpendingKey;
    use orchard::note_encryption::testing::fake_compact_action;
    use zcash_client_backend::proto::compact_formats::{
        ChainMetadata, CompactOrchardAction, CompactTx,
    };
    use zip32::AccountId;

    fn make_test_block(
        num_txs: usize,
        actions_per_tx: usize,
        tree_size_before_block: u32,
    ) -> Vec<u8> {
        let total_actions = (num_txs * actions_per_tx) as u32;
        let mut block = CompactBlock {
            proto_version: 1,
            height: 100,
            time: 1_700_000_000,
            chain_metadata: Some(ChainMetadata {
                orchard_commitment_tree_size: tree_size_before_block + total_actions,
                ..Default::default()
            }),
            ..Default::default()
        };

        for tx_idx in 0..num_txs {
            let mut tx_hash = [0u8; 32];
            tx_hash[0] = 0xAA;
            tx_hash[1] = tx_idx as u8;
            let mut tx = CompactTx {
                index: tx_idx as u64,
                hash: tx_hash.to_vec(),
                fee: 10_000,
                ..Default::default()
            };
            for action_idx in 0..actions_per_tx {
                let mut nf = [0u8; 32];
                nf[0] = tx_idx as u8;
                nf[1] = action_idx as u8;
                let mut cmx = [0u8; 32];
                cmx[0] = tx_idx as u8;
                cmx[1] = action_idx as u8;
                cmx[31] = 0x01;
                let mut epk = [0u8; 32];
                epk[0] = tx_idx as u8;
                epk[1] = action_idx as u8;
                epk[31] = 0x02;

                tx.actions.push(CompactOrchardAction {
                    nullifier: nf.to_vec(),
                    cmx: cmx.to_vec(),
                    ephemeral_key: epk.to_vec(),
                    ciphertext: vec![0u8; 52],
                });
            }
            block.vtx.push(tx);
        }

        block.encode_to_vec()
    }

    #[test]
    fn extract_single_action() {
        let block_bytes = make_test_block(1, 3, 1000);
        let extracted = extract_actions_from_block(&block_bytes, 1001, 1).unwrap();
        assert_eq!(extracted.actions.len(), 1);
        assert_eq!(extracted.actions[0].0, 1001);

        let meta = extracted.metadata.expect("metadata should be present");
        assert_eq!(meta.block_time, 1_700_000_000);
        assert_eq!(meta.fee, 10_000);
        assert_eq!(meta.tx_hash[0], 0xAA);
        assert_eq!(meta.tx_hash[1], 0x00);
    }

    #[test]
    fn extract_multiple_actions() {
        let block_bytes = make_test_block(2, 4, 500);
        let extracted = extract_actions_from_block(&block_bytes, 502, 3).unwrap();
        assert_eq!(extracted.actions.len(), 3);
        assert_eq!(extracted.actions[0].0, 502);
        assert_eq!(extracted.actions[1].0, 503);
        assert_eq!(extracted.actions[2].0, 504);
    }

    #[test]
    fn extract_spanning_transactions() {
        let block_bytes = make_test_block(2, 2, 0);
        let extracted = extract_actions_from_block(&block_bytes, 1, 2).unwrap();
        assert_eq!(extracted.actions.len(), 2);
        assert_eq!(extracted.actions[0].0, 1);
        assert_eq!(extracted.actions[1].0, 2);

        let meta = extracted.metadata.expect("metadata should be present");
        assert_eq!(meta.tx_hash[1], 0x00, "metadata should come from the first tx containing the range start");
    }

    #[test]
    fn extract_all_actions_in_block() {
        let block_bytes = make_test_block(1, 5, 100);
        let extracted = extract_actions_from_block(&block_bytes, 100, 5).unwrap();
        assert_eq!(extracted.actions.len(), 5);
        for (i, (pos, _)) in extracted.actions.iter().enumerate() {
            assert_eq!(*pos, 100 + i as u64);
        }
    }

    #[test]
    fn extract_out_of_range_before_block() {
        let block_bytes = make_test_block(1, 3, 100);
        assert!(extract_actions_from_block(&block_bytes, 99, 1).is_err());
    }

    #[test]
    fn extract_out_of_range_past_block() {
        let block_bytes = make_test_block(1, 3, 100);
        assert!(extract_actions_from_block(&block_bytes, 103, 1).is_err());
    }

    #[test]
    fn extract_zero_actions() {
        let block_bytes = make_test_block(1, 3, 100);
        let extracted = extract_actions_from_block(&block_bytes, 100, 0).unwrap();
        assert!(extracted.actions.is_empty());
        assert!(extracted.metadata.is_none());
    }

    #[test]
    fn extract_missing_metadata() {
        let block = CompactBlock {
            proto_version: 1,
            height: 100,
            chain_metadata: None,
            ..Default::default()
        };
        assert!(extract_actions_from_block(&block.encode_to_vec(), 0, 1).is_err());
    }

    #[test]
    fn extract_captures_tx_metadata() {
        let mut block = CompactBlock {
            proto_version: 1,
            height: 100,
            time: 1700000000,
            chain_metadata: Some(ChainMetadata {
                orchard_commitment_tree_size: 1003,
                ..Default::default()
            }),
            ..Default::default()
        };
        let mut tx = CompactTx {
            index: 0,
            hash: vec![0xAB; 32],
            fee: 10_000,
            ..Default::default()
        };
        for i in 0..3u8 {
            tx.actions.push(CompactOrchardAction {
                nullifier: [i; 32].to_vec(),
                cmx: [i; 32].to_vec(),
                ephemeral_key: [i; 32].to_vec(),
                ciphertext: vec![0u8; 52],
            });
        }
        block.vtx.push(tx);
        let block_bytes = block.encode_to_vec();

        let extracted = extract_actions_from_block(&block_bytes, 1001, 1).unwrap();
        let meta = extracted.metadata.unwrap();
        assert_eq!(meta.tx_hash, [0xAB; 32]);
        assert_eq!(meta.fee, 10_000);
        assert_eq!(meta.block_time, 1700000000);
    }

    // -- Trial decryption tests --

    fn test_keys() -> (FullViewingKey, PreparedIncomingViewingKey) {
        let sk = SpendingKey::from_zip32_seed(&[0u8; 32], 133, AccountId::ZERO).unwrap();
        let fvk = FullViewingKey::from(&sk);
        let ivk = fvk.to_ivk(Scope::Internal);
        let prepared = PreparedIncomingViewingKey::new(&ivk);
        (fvk, prepared)
    }

    fn make_encrypted_action_with_scope(
        fvk: &FullViewingKey,
        scope: Scope,
        value_raw: u64,
        nf_seed: u8,
    ) -> (CompactAction, orchard::Note) {
        use rand::rngs::OsRng;

        let recipient = fvk.address_at(0u64, scope);
        let nf_old = orchard::note::Nullifier::from_bytes(&[nf_seed; 32]).unwrap();
        let value = orchard::value::NoteValue::from_raw(value_raw);
        let ovk = fvk.to_ovk(scope);

        fake_compact_action(&mut OsRng, nf_old, recipient, value, Some(ovk))
    }

    fn make_encrypted_action(
        fvk: &FullViewingKey,
    ) -> (CompactAction, orchard::Note) {
        make_encrypted_action_with_scope(fvk, Scope::Internal, 50_000, 7)
    }

    #[test]
    fn decrypt_single_note() {
        let (fvk, prepared_ivk) = test_keys();
        let (action, expected_note) = make_encrypted_action(&fvk);

        let actions = vec![(1000u64, action)];
        let discovered = try_decrypt_compact_actions(&prepared_ivk, &fvk, &actions);

        assert_eq!(discovered.len(), 1);
        let note = &discovered[0];
        assert_eq!(note.position, 1000);
        assert_eq!(note.value, 50_000);
        assert_eq!(
            note.diversifier,
            *expected_note.recipient().diversifier().as_array(),
        );
        assert_eq!(note.rho, expected_note.rho().to_bytes());
        assert_eq!(
            note.nullifier,
            expected_note.nullifier(&fvk).to_bytes(),
        );
        assert_eq!(note.cmx, actions[0].1.cmx().to_bytes());
    }

    #[test]
    fn decrypt_wrong_ivk_finds_nothing() {
        let (fvk, _) = test_keys();
        let (action, _) = make_encrypted_action(&fvk);

        let other_sk = SpendingKey::from_zip32_seed(&[1u8; 32], 133, AccountId::ZERO).unwrap();
        let other_fvk = FullViewingKey::from(&other_sk);
        let other_ivk = other_fvk.to_ivk(Scope::Internal);
        let other_prepared = PreparedIncomingViewingKey::new(&other_ivk);

        let actions = vec![(500u64, action)];
        let discovered = try_decrypt_compact_actions(&other_prepared, &other_fvk, &actions);

        assert!(discovered.is_empty());
    }

    #[test]
    fn discover_both_scopes() {
        let sk = SpendingKey::from_zip32_seed(&[0u8; 32], 133, AccountId::ZERO).unwrap();
        let fvk = FullViewingKey::from(&sk);
        let (action, _) = make_encrypted_action(&fvk);

        let actions = vec![(2000u64, action)];
        let discovered = discover_notes_both_scopes(&fvk, &actions);

        assert_eq!(discovered.len(), 1);
        assert_eq!(discovered[0].position, 2000);
        assert_eq!(discovered[0].value, 50_000);
    }

    #[test]
    fn full_roundtrip_extract_then_decrypt() {
        use rand::rngs::OsRng;
        use zcash_note_encryption::ShieldedOutput;

        let (fvk, _) = test_keys();
        let recipient = fvk.address_at(0u64, Scope::Internal);
        let nf_old = orchard::note::Nullifier::from_bytes(&[42u8; 32]).unwrap();
        let value = orchard::value::NoteValue::from_raw(100_000);
        let ovk = fvk.to_ovk(Scope::Internal);

        let (compact_action, expected_note) = fake_compact_action(
            &mut OsRng,
            nf_old,
            recipient,
            value,
            Some(ovk),
        );

        let tree_size_before = 5000u32;
        let target_position = tree_size_before + 2; // action at index 2

        let proto_action = CompactOrchardAction {
            nullifier: compact_action.nullifier().to_bytes().to_vec(),
            cmx: compact_action.cmx().to_bytes().to_vec(),
            ephemeral_key: compact_action.ephemeral_key().0.to_vec(),
            ciphertext: compact_action.enc_ciphertext()[..52].to_vec(),
        };

        let mut block = CompactBlock {
            proto_version: 1,
            height: 3200000,
            ..Default::default()
        };

        let mut tx = CompactTx {
            index: 0,
            ..Default::default()
        };
        // Two dummy actions before the real one
        for i in 0..2u8 {
            tx.actions.push(CompactOrchardAction {
                nullifier: [i; 32].to_vec(),
                cmx: [i; 32].to_vec(),
                ephemeral_key: [i; 32].to_vec(),
                ciphertext: vec![0u8; 52],
            });
        }
        tx.actions.push(proto_action);
        // One dummy after
        tx.actions.push(CompactOrchardAction {
            nullifier: [99u8; 32].to_vec(),
            cmx: [99u8; 32].to_vec(),
            ephemeral_key: [99u8; 32].to_vec(),
            ciphertext: vec![0u8; 52],
        });
        block.vtx.push(tx);

        block.chain_metadata = Some(ChainMetadata {
            orchard_commitment_tree_size: tree_size_before + 4,
            ..Default::default()
        });

        let block_bytes = block.encode_to_vec();

        let extracted = extract_actions_from_block(
            &block_bytes,
            target_position,
            1,
        )
        .unwrap();
        assert_eq!(extracted.actions.len(), 1);
        assert_eq!(extracted.actions[0].0, target_position as u64);

        let discovered = discover_notes_both_scopes(&fvk, &extracted.actions);
        assert_eq!(discovered.len(), 1);

        let note = &discovered[0];
        assert_eq!(note.position, target_position as u64);
        assert_eq!(note.value, 100_000);
        assert_eq!(
            note.diversifier,
            *expected_note.recipient().diversifier().as_array(),
        );
        assert_eq!(note.rseed, *expected_note.rseed().as_bytes());
        assert_eq!(note.rho, expected_note.rho().to_bytes());
        assert_eq!(
            note.nullifier,
            expected_note.nullifier(&fvk).to_bytes(),
        );
        assert_eq!(note.cmx, compact_action.cmx().to_bytes());
    }

    #[test]
    fn discover_external_scope_note() {
        let sk = SpendingKey::from_zip32_seed(&[0u8; 32], 133, AccountId::ZERO).unwrap();
        let fvk = FullViewingKey::from(&sk);
        let (action, expected_note) =
            make_encrypted_action_with_scope(&fvk, Scope::External, 75_000, 11);

        let actions = vec![(3000u64, action.clone())];
        let discovered = discover_notes_both_scopes(&fvk, &actions);

        assert_eq!(discovered.len(), 1);
        assert_eq!(discovered[0].position, 3000);
        assert_eq!(discovered[0].value, 75_000);
        assert_eq!(
            discovered[0].diversifier,
            *expected_note.recipient().diversifier().as_array(),
        );
        assert_eq!(discovered[0].cmx, action.cmx().to_bytes());
    }

    #[test]
    fn discover_multiple_notes_in_one_call() {
        let sk = SpendingKey::from_zip32_seed(&[0u8; 32], 133, AccountId::ZERO).unwrap();
        let fvk = FullViewingKey::from(&sk);

        let (action1, _) = make_encrypted_action_with_scope(&fvk, Scope::Internal, 10_000, 1);
        let (action2, _) = make_encrypted_action_with_scope(&fvk, Scope::Internal, 20_000, 2);
        let (action3, _) = make_encrypted_action_with_scope(&fvk, Scope::Internal, 30_000, 3);

        let actions = vec![
            (100u64, action1),
            (101u64, action2),
            (102u64, action3),
        ];
        let discovered = discover_notes_both_scopes(&fvk, &actions);

        assert_eq!(discovered.len(), 3);

        let values: Vec<u64> = discovered.iter().map(|n| n.value).collect();
        assert!(values.contains(&10_000));
        assert!(values.contains(&20_000));
        assert!(values.contains(&30_000));

        let positions: Vec<u64> = discovered.iter().map(|n| n.position).collect();
        assert!(positions.contains(&100));
        assert!(positions.contains(&101));
        assert!(positions.contains(&102));
    }
}
