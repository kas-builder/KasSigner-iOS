//! Consensus-oriented two-stage protected-vault script builders.
//!
//! V1 is deliberately narrow: one input, one full-balance output, one exact
//! approved P2PK destination, and one owner key. An approved withdrawal is
//! terminal and immediate. Every other withdrawal must first create a P2SH
//! output whose redeem script commits the eventual destination; that new UTXO
//! then enforces CSV. Putting CSV on the original vault would be unsafe because
//! its relative age would eventually elapse while the vault merely sat funded.

use super::{blake2b_hash, covenant_ops, push_data, push_int, push_pubkey};

const SCRIPT_PUBLIC_KEY_VERSION_0: [u8; 2] = [0x00, 0x00];
const P2SH_PREFIX: [u8; 4] = [0x00, 0x00, 0xaa, 0x20];
const P2SH_SUFFIX: [u8; 1] = [0x87];
const VERSIONED_P2PK_SPK_LEN: u64 = 36;

/// Maximum fee accepted by the covenant on either stage.
/// This is embedded policy, not a fee estimate.
pub const PROTECTED_VAULT_V1_MAX_FEE_SOMPI: u64 = 10_000_000;

/// Build the second-stage pending redeem script for one exact P2PK destination.
/// CSV is evaluated relative to this pending UTXO's own creation DAA score.
pub fn build_protected_vault_pending_script(
    owner_pubkey: &[u8; 32],
    destination_versioned_spk: &[u8],
    delay_daa: u64,
    max_fee: u64,
) -> Result<Vec<u8>, String> {
    validate_v1_destination(destination_versioned_spk)?;
    if delay_daa == 0 {
        return Err("Protected-vault delay must be greater than zero".into());
    }

    let mut script = Vec::with_capacity(192);
    push_pubkey(&mut script, owner_pubkey);
    script.push(covenant_ops::OP_CHECKSIGVERIFY);
    push_data(&mut script, destination_versioned_spk);
    push_int(&mut script, delay_daa);
    script.push(covenant_ops::OP_CHECKSEQUENCEVERIFY);
    append_single_authorized_output_checks(&mut script);
    append_fee_ceiling_check(&mut script, max_fee);
    push_int(&mut script, 0);
    script.push(covenant_ops::OP_TX_OUTPUT_SPK);
    script.push(covenant_ops::OP_EQUALVERIFY);
    script.push(covenant_ops::OP_1);
    Ok(script)
}

/// Build the first-stage protected vault.
///
/// Signature stack contracts:
/// - approved: `<OP_TRUE> <owner signature> <redeem>`
/// - delayed: `<versioned destination SPK> <OP_FALSE> <owner signature> <redeem>`
///
/// The delayed branch reconstructs and hashes the exact pending redeem script
/// inside consensus, then requires output 0 to be that P2SH. App metadata is
/// therefore not trusted to preserve the destination commitment.
pub fn build_protected_vault_script(
    owner_pubkey: &[u8; 32],
    approved_versioned_spk: &[u8],
    delay_daa: u64,
    max_fee: u64,
) -> Result<Vec<u8>, String> {
    build_protected_vault_script_with_destinations(
        owner_pubkey,
        &[approved_versioned_spk.to_vec()],
        delay_daa,
        max_fee,
    )
}

/// Commit one to five exact P2PK destinations in the vault redeem script.
/// The single-destination encoding remains byte-for-byte compatible with V1.
pub fn build_protected_vault_script_with_destinations(
    owner_pubkey: &[u8; 32],
    approved_versioned_spks: &[Vec<u8>],
    delay_daa: u64,
    max_fee: u64,
) -> Result<Vec<u8>, String> {
    if approved_versioned_spks.is_empty() || approved_versioned_spks.len() > 5 {
        return Err("Protected Vault requires 1 to 5 approved destinations".into());
    }
    for (index, approved_spk) in approved_versioned_spks.iter().enumerate() {
        validate_v1_destination(approved_spk)?;
        if approved_versioned_spks[..index].contains(approved_spk) {
            return Err("Protected Vault approved destinations must be unique".into());
        }
    }
    if delay_daa == 0 {
        return Err("Protected-vault delay must be greater than zero".into());
    }

    let pending_prefix = pending_script_prefix(owner_pubkey);
    let pending_suffix = pending_script_suffix(delay_daa, max_fee);
    let mut script = Vec::with_capacity(360 + approved_versioned_spks.len() * 42);

    push_pubkey(&mut script, owner_pubkey);
    script.push(covenant_ops::OP_CHECKSIGVERIFY);
    script.push(covenant_ops::OP_IF);

    append_single_authorized_output_checks(&mut script);
    append_fee_ceiling_check(&mut script, max_fee);
    for (index, approved_spk) in approved_versioned_spks.iter().enumerate() {
        push_int(&mut script, 0);
        script.push(covenant_ops::OP_TX_OUTPUT_SPK);
        push_data(&mut script, approved_spk);
        if index == 0 && approved_versioned_spks.len() == 1 {
            script.push(covenant_ops::OP_EQUALVERIFY);
        } else {
            script.push(covenant_ops::OP_EQUAL);
            if index > 0 {
                script.push(covenant_ops::OP_BOOLOR);
            }
        }
    }
    if approved_versioned_spks.len() > 1 {
        script.push(covenant_ops::OP_VERIFY);
    }
    script.push(covenant_ops::OP_1);

    script.push(covenant_ops::OP_ELSE);
    script.push(covenant_ops::OP_SIZE);
    push_int(&mut script, VERSIONED_P2PK_SPK_LEN);
    script.push(covenant_ops::OP_EQUALVERIFY);

    // pending_prefix || push(destination) || pending_suffix
    push_data(&mut script, &pending_prefix);
    script.push(covenant_ops::OP_SWAP);
    push_data(&mut script, &[VERSIONED_P2PK_SPK_LEN as u8]);
    script.push(covenant_ops::OP_SWAP);
    script.push(covenant_ops::OP_CAT);
    script.push(covenant_ops::OP_CAT);
    push_data(&mut script, &pending_suffix);
    script.push(covenant_ops::OP_CAT);

    // Hash the reconstructed redeem script into its versioned P2SH SPK.
    script.push(covenant_ops::OP_BLAKE2B);
    push_data(&mut script, &P2SH_PREFIX);
    script.push(covenant_ops::OP_SWAP);
    script.push(covenant_ops::OP_CAT);
    push_data(&mut script, &P2SH_SUFFIX);
    script.push(covenant_ops::OP_CAT);

    append_single_authorized_output_checks(&mut script);
    append_fee_ceiling_check(&mut script, max_fee);
    push_int(&mut script, 0);
    script.push(covenant_ops::OP_TX_OUTPUT_SPK);
    script.push(covenant_ops::OP_EQUALVERIFY);
    script.push(covenant_ops::OP_1);
    script.push(covenant_ops::OP_ENDIF);
    if script.len() > 520 {
        return Err("Protected Vault redeem script exceeds the 520-byte witness limit".into());
    }
    Ok(script)
}

/// V2 commits a separate recovery P2PK key and output. The recovery key can
/// always redirect a pending withdrawal to that output. When
/// `emergency_anytime` is true it can also spend the original vault.
pub fn build_protected_vault_script_with_recovery(
    owner_pubkey: &[u8; 32],
    approved_versioned_spks: &[Vec<u8>],
    recovery_versioned_spk: &[u8],
    delay_daa: u64,
    max_fee: u64,
    emergency_anytime: bool,
) -> Result<Vec<u8>, String> {
    if approved_versioned_spks.is_empty() || approved_versioned_spks.len() > 5 {
        return Err("Protected Vault requires 1 to 5 approved destinations".into());
    }
    for (index, approved_spk) in approved_versioned_spks.iter().enumerate() {
        validate_v1_destination(approved_spk)?;
        if approved_versioned_spks[..index].contains(approved_spk) {
            return Err("Protected Vault approved destinations must be unique".into());
        }
    }
    validate_v1_destination(recovery_versioned_spk)?;
    if delay_daa == 0 {
        return Err("Protected-vault delay must be greater than zero".into());
    }
    let recovery_pubkey: [u8; 32] = recovery_versioned_spk[3..35].try_into().unwrap();
    if &recovery_pubkey == owner_pubkey {
        return Err("Recovery key must differ from the owner key".into());
    }

    let pending_prefix = pending_recovery_prefix(owner_pubkey, recovery_versioned_spk);
    let pending_suffix = pending_recovery_suffix(delay_daa, max_fee);
    let mut script = Vec::with_capacity(520);
    if emergency_anytime {
        script.push(covenant_ops::OP_IF);
        append_recovery_signature_check(&mut script, recovery_versioned_spk);
        script.push(covenant_ops::OP_ELSE);
    }

    push_pubkey(&mut script, owner_pubkey);
    script.push(covenant_ops::OP_CHECKSIGVERIFY);
    script.push(covenant_ops::OP_IF);
    for (index, approved_spk) in approved_versioned_spks.iter().enumerate() {
        push_int(&mut script, 0);
        script.push(covenant_ops::OP_TX_OUTPUT_SPK);
        push_data(&mut script, approved_spk);
        script.push(covenant_ops::OP_EQUAL);
        if index > 0 {
            script.push(covenant_ops::OP_BOOLOR);
        }
    }
    script.push(covenant_ops::OP_VERIFY);
    push_int(&mut script, 0);
    script.push(covenant_ops::OP_TX_OUTPUT_SPK);

    script.push(covenant_ops::OP_ELSE);
    script.push(covenant_ops::OP_SIZE);
    push_int(&mut script, VERSIONED_P2PK_SPK_LEN);
    script.push(covenant_ops::OP_EQUALVERIFY);
    push_data(&mut script, &pending_prefix);
    script.push(covenant_ops::OP_SWAP);
    push_data(&mut script, &[VERSIONED_P2PK_SPK_LEN as u8]);
    script.push(covenant_ops::OP_SWAP);
    script.push(covenant_ops::OP_CAT);
    script.push(covenant_ops::OP_CAT);
    push_data(&mut script, &pending_suffix);
    script.push(covenant_ops::OP_CAT);
    script.push(covenant_ops::OP_BLAKE2B);
    push_data(&mut script, &P2SH_PREFIX);
    script.push(covenant_ops::OP_SWAP);
    script.push(covenant_ops::OP_CAT);
    push_data(&mut script, &P2SH_SUFFIX);
    script.push(covenant_ops::OP_CAT);
    script.push(covenant_ops::OP_ENDIF);
    if emergency_anytime {
        script.push(covenant_ops::OP_ENDIF);
    }

    append_single_authorized_output_checks(&mut script);
    append_fee_ceiling_check(&mut script, max_fee);
    push_int(&mut script, 0);
    script.push(covenant_ops::OP_TX_OUTPUT_SPK);
    script.push(covenant_ops::OP_EQUALVERIFY);
    script.push(covenant_ops::OP_1);
    if script.len() > 520 {
        return Err(format!(
            "Protected Vault recovery script is {} bytes; the consensus limit is 520",
            script.len()
        ));
    }
    Ok(script)
}

/// The delayed output is destination-specific. Its recovery branch is
/// immediately spendable with the independent recovery key; its owner branch
/// becomes spendable only after the pending output ages by `delay_daa`.
pub fn build_protected_vault_pending_script_with_recovery(
    owner_pubkey: &[u8; 32],
    destination_versioned_spk: &[u8],
    recovery_versioned_spk: &[u8],
    delay_daa: u64,
    max_fee: u64,
) -> Result<Vec<u8>, String> {
    validate_v1_destination(destination_versioned_spk)?;
    validate_v1_destination(recovery_versioned_spk)?;
    if delay_daa == 0 {
        return Err("Protected-vault delay must be greater than zero".into());
    }
    let recovery_pubkey: [u8; 32] = recovery_versioned_spk[3..35].try_into().unwrap();
    if &recovery_pubkey == owner_pubkey {
        return Err("Recovery key must differ from the owner key".into());
    }
    let mut script = pending_recovery_prefix(owner_pubkey, recovery_versioned_spk);
    push_data(&mut script, destination_versioned_spk);
    script.extend_from_slice(&pending_recovery_suffix(delay_daa, max_fee));
    if script.len() > 520 {
        return Err("Protected Vault pending script exceeds the consensus limit".into());
    }
    Ok(script)
}

fn pending_recovery_prefix(owner_pubkey: &[u8; 32], recovery_versioned_spk: &[u8]) -> Vec<u8> {
    let mut prefix = Vec::with_capacity(110);
    prefix.push(covenant_ops::OP_IF);
    append_recovery_signature_check(&mut prefix, recovery_versioned_spk);
    prefix.push(covenant_ops::OP_ELSE);
    push_pubkey(&mut prefix, owner_pubkey);
    prefix.push(covenant_ops::OP_CHECKSIGVERIFY);
    prefix
}

fn append_recovery_signature_check(script: &mut Vec<u8>, recovery_spk: &[u8]) {
    // Keep the committed SPK below the signature while extracting its x-only
    // key. The SPK itself remains as the expected sole output.
    push_data(script, recovery_spk);
    script.push(covenant_ops::OP_SWAP);
    script.push(covenant_ops::OP_OVER);
    push_int(script, 3);
    push_int(script, 35);
    script.push(covenant_ops::OP_SUBSTR);
    script.push(covenant_ops::OP_CHECKSIGVERIFY);
}

fn pending_recovery_suffix(delay_daa: u64, max_fee: u64) -> Vec<u8> {
    let mut suffix = Vec::with_capacity(80);
    push_int(&mut suffix, delay_daa);
    suffix.push(covenant_ops::OP_CHECKSEQUENCEVERIFY);
    suffix.push(covenant_ops::OP_ENDIF);
    append_single_authorized_output_checks(&mut suffix);
    append_fee_ceiling_check(&mut suffix, max_fee);
    push_int(&mut suffix, 0);
    suffix.push(covenant_ops::OP_TX_OUTPUT_SPK);
    suffix.push(covenant_ops::OP_EQUALVERIFY);
    suffix.push(covenant_ops::OP_1);
    suffix
}

/// Return the raw P2SH script carried by RPC UTXO entries and PSKB fields.
pub fn protected_vault_p2sh_script(redeem_script: &[u8]) -> Vec<u8> {
    let hash = blake2b_hash(redeem_script);
    let mut script = Vec::with_capacity(35);
    script.extend_from_slice(&P2SH_PREFIX[2..]);
    script.extend_from_slice(&hash);
    script.extend_from_slice(&P2SH_SUFFIX);
    script
}

/// Return the versioned P2SH script public key consumed by covenant opcodes.
pub fn protected_vault_p2sh_spk(redeem_script: &[u8]) -> Vec<u8> {
    let script = protected_vault_p2sh_script(redeem_script);
    let mut spk = Vec::with_capacity(37);
    spk.extend_from_slice(&SCRIPT_PUBLIC_KEY_VERSION_0);
    spk.extend_from_slice(&script);
    spk
}

fn pending_script_prefix(owner_pubkey: &[u8; 32]) -> Vec<u8> {
    let mut prefix = Vec::with_capacity(34);
    push_pubkey(&mut prefix, owner_pubkey);
    prefix.push(covenant_ops::OP_CHECKSIGVERIFY);
    prefix
}

fn pending_script_suffix(delay_daa: u64, max_fee: u64) -> Vec<u8> {
    let mut suffix = Vec::with_capacity(128);
    push_int(&mut suffix, delay_daa);
    suffix.push(covenant_ops::OP_CHECKSEQUENCEVERIFY);
    append_single_authorized_output_checks(&mut suffix);
    append_fee_ceiling_check(&mut suffix, max_fee);
    push_int(&mut suffix, 0);
    suffix.push(covenant_ops::OP_TX_OUTPUT_SPK);
    suffix.push(covenant_ops::OP_EQUALVERIFY);
    suffix.push(covenant_ops::OP_1);
    suffix
}

fn append_single_authorized_output_checks(script: &mut Vec<u8>) {
    push_int(script, 1);
    script.push(covenant_ops::OP_TX_INPUT_COUNT);
    script.push(covenant_ops::OP_EQUALVERIFY);
    push_int(script, 1);
    script.push(covenant_ops::OP_TX_OUTPUT_COUNT);
    script.push(covenant_ops::OP_EQUALVERIFY);
    script.push(covenant_ops::OP_TX_INPUT_INDEX);
    push_int(script, 0);
    script.push(covenant_ops::OP_EQUALVERIFY);
    push_int(script, 0);
    script.push(covenant_ops::OP_AUTH_OUTPUT_COUNT);
    push_int(script, 1);
    script.push(covenant_ops::OP_EQUALVERIFY);
    push_int(script, 0);
    push_int(script, 0);
    script.push(covenant_ops::OP_AUTH_OUTPUT_IDX);
    push_int(script, 0);
    script.push(covenant_ops::OP_EQUALVERIFY);
}

fn append_fee_ceiling_check(script: &mut Vec<u8>, max_fee: u64) {
    push_int(script, 0);
    script.push(covenant_ops::OP_TX_INPUT_AMOUNT);
    push_int(script, max_fee);
    script.push(covenant_ops::OP_GREATERTHANOREQUAL);
    script.push(covenant_ops::OP_VERIFY);
    push_int(script, 0);
    script.push(covenant_ops::OP_TX_OUTPUT_AMOUNT);
    push_int(script, 0);
    script.push(covenant_ops::OP_TX_INPUT_AMOUNT);
    push_int(script, max_fee);
    script.push(covenant_ops::OP_SUB);
    script.push(covenant_ops::OP_GREATERTHANOREQUAL);
    script.push(covenant_ops::OP_VERIFY);
}

fn validate_v1_destination(versioned_spk: &[u8]) -> Result<(), String> {
    if versioned_spk.len() != VERSIONED_P2PK_SPK_LEN as usize
        || versioned_spk[0..2] != SCRIPT_PUBLIC_KEY_VERSION_0
        || versioned_spk[2] != 0x20
        || versioned_spk[35] != covenant_ops::OP_CHECKSIG
    {
        return Err("Protected Vault V1 supports only version-0 P2PK destinations".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn versioned_p2pk(byte: u8) -> Vec<u8> {
        let mut spk = vec![0x00, 0x00, 0x20];
        spk.extend_from_slice(&[byte; 32]);
        spk.push(covenant_ops::OP_CHECKSIG);
        spk
    }

    #[test]
    fn pending_script_is_destination_specific() {
        let owner = [7u8; 32];
        let a =
            build_protected_vault_pending_script(&owner, &versioned_p2pk(1), 600, 100_000).unwrap();
        let b =
            build_protected_vault_pending_script(&owner, &versioned_p2pk(2), 600, 100_000).unwrap();
        assert_ne!(a, b);
        assert_ne!(protected_vault_p2sh_spk(&a), protected_vault_p2sh_spk(&b));
    }

    #[test]
    fn recovery_scripts_fit_and_commit_every_rule() {
        let owner = [7u8; 32];
        let recovery = versioned_p2pk(9);
        let approved: Vec<_> = (1..=5).map(versioned_p2pk).collect();
        for count in 1..=5 {
            for emergency in [false, true] {
                let script = build_protected_vault_script_with_recovery(
                    &owner,
                    &approved[..count],
                    &recovery,
                    18_000,
                    100_000,
                    emergency,
                )
                .unwrap();
                assert!(script.len() <= 520);
                assert_ne!(
                    script,
                    build_protected_vault_script_with_recovery(
                        &owner,
                        &approved[..count],
                        &recovery,
                        18_001,
                        100_000,
                        emergency,
                    )
                    .unwrap()
                );
            }
        }
        let pending = build_protected_vault_pending_script_with_recovery(
            &owner,
            &approved[0],
            &recovery,
            18_000,
            100_000,
        )
        .unwrap();
        let mut reconstructed = pending_recovery_prefix(&owner, &recovery);
        push_data(&mut reconstructed, &approved[0]);
        reconstructed.extend_from_slice(&pending_recovery_suffix(18_000, 100_000));
        assert_eq!(pending, reconstructed);
    }

    #[test]
    fn multi_destination_builder_preserves_single_address_v1_and_rejects_duplicates() {
        let owner = [7u8; 32];
        let first = versioned_p2pk(1);
        let second = versioned_p2pk(2);
        let legacy = build_protected_vault_script(&owner, &first, 600, 100_000).unwrap();
        let one =
            build_protected_vault_script_with_destinations(&owner, &[first.clone()], 600, 100_000)
                .unwrap();
        assert_eq!(legacy, one);
        let two = build_protected_vault_script_with_destinations(
            &owner,
            &[first.clone(), second],
            600,
            100_000,
        )
        .unwrap();
        assert_ne!(legacy, two);
        assert!(build_protected_vault_script_with_destinations(
            &owner,
            &[first.clone(), first],
            600,
            100_000,
        )
        .is_err());
        assert!(build_protected_vault_script_with_destinations(&owner, &[], 600, 100_000).is_err());
        let too_many = (0..6).map(versioned_p2pk).collect::<Vec<_>>();
        assert!(
            build_protected_vault_script_with_destinations(&owner, &too_many, 600, 100_000)
                .is_err()
        );
    }

    #[test]
    fn rejects_zero_delay_and_non_p2pk_destinations() {
        let owner = [7u8; 32];
        assert!(build_protected_vault_script(&owner, &versioned_p2pk(1), 0, 100_000).is_err());
        assert!(build_protected_vault_pending_script(&owner, &[0u8; 37], 600, 100_000).is_err());
    }

    #[test]
    fn vault_parameters_change_its_identity() {
        let owner = [7u8; 32];
        let approved = versioned_p2pk(1);
        let a = build_protected_vault_script(&owner, &approved, 600, 100_000).unwrap();
        let b = build_protected_vault_script(&owner, &approved, 1_200, 100_000).unwrap();
        let c = build_protected_vault_script(&owner, &approved, 600, 200_000).unwrap();
        assert_ne!(protected_vault_p2sh_spk(&a), protected_vault_p2sh_spk(&b));
        assert_ne!(protected_vault_p2sh_spk(&a), protected_vault_p2sh_spk(&c));
    }

    #[test]
    fn identical_wallet_key_and_settings_produce_identical_vault_address() {
        let owner = [7u8; 32];
        let approved = versioned_p2pk(9);
        let first = build_protected_vault_script(&owner, &approved, 18_000, 100_000).unwrap();
        let second = build_protected_vault_script(&owner, &approved, 18_000, 100_000).unwrap();

        assert_eq!(
            protected_vault_p2sh_spk(&first),
            protected_vault_p2sh_spk(&second)
        );
    }

    #[test]
    fn versioned_vault_spk_contains_the_raw_rpc_script_after_version() {
        let redeem =
            build_protected_vault_script(&[7u8; 32], &versioned_p2pk(9), 18_000, 100_000).unwrap();
        let versioned = protected_vault_p2sh_spk(&redeem);

        assert_eq!(&versioned[..2], &[0x00, 0x00]);
        assert_eq!(versioned.len(), 37);
        assert_eq!(&versioned[2..], protected_vault_p2sh_script(&redeem));
        assert_eq!(&versioned[2..4], &[0xaa, 0x20]);
        assert_eq!(versioned.last(), Some(&0x87));
    }
}
