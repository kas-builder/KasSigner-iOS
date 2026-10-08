#![cfg(test)]

use kaspa_consensus_core::{
    hashing::{
        sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
        sighash_type::SIG_HASH_ALL,
    },
    subnets::SubnetworkId,
    tx::{
        CovenantBinding, GenesisCovenantGroup, MutableTransaction, PopulatedTransaction,
        ScriptPublicKey, Transaction, TransactionInput, TransactionOutpoint, TransactionOutput,
        UtxoEntry,
    },
};
use kaspa_hashes::Hash;
use kaspa_txscript::{
    caches::Cache,
    covenants::CovenantsContext,
    opcodes::codes::{OpFalse, OpTrue},
    pay_to_script_hash_script,
    script_builder::ScriptBuilder,
    EngineCtx, EngineFlags, TxScriptEngine,
};
use kaspa_txscript_errors::TxScriptError;
use kassee_web::{
    build_protected_vault_pending_script, build_protected_vault_script,
    build_protected_vault_script_with_destinations,
    build_protected_vault_pending_script_with_recovery,
    build_protected_vault_script_with_recovery,
};
use secp256k1::{Keypair, Message, SecretKey};

const INPUT_VALUE: u64 = 500_000_000;
const FEE: u64 = 100_000;
const MAX_FEE: u64 = 200_000;
const DELAY_DAA: u64 = 600;

#[test]
fn funding_pskb_signatures_match_pinned_consensus_sighash() {
    let secret = SecretKey::from_slice(&[21u8; 32]).unwrap();
    let owner = Keypair::from_secret_key(secp256k1::SECP256K1, &secret);
    let owner_pubkey = owner.x_only_public_key().0.serialize();
    let input_spk = ScriptPublicKey::from_vec(0, {
        let mut script = vec![0x20];
        script.extend_from_slice(&owner_pubkey);
        script.push(0xac);
        script
    });
    let output_spk = p2pk_spk(33);
    let outpoint_hash = Hash::from_u64_word(9);
    let input = TransactionInput::new(
        TransactionOutpoint::new(outpoint_hash, 2),
        vec![],
        0,
        1,
    );
    let mut tx = Transaction::new(
        0,
        vec![input],
        vec![TransactionOutput::new(99_999_000, output_spk.clone())],
        0,
        SubnetworkId::default(),
        0,
        vec![],
    );
    tx.finalize();
    let entry = UtxoEntry::new(100_000_000, input_spk.clone(), 10, false, None);
    let sig = signature(&tx, &entry, &owner);
    let sig_hex = hex::encode(&sig[..64]);
    let key_hex = format!("02{}", hex::encode(owner_pubkey));
    let body = serde_json::json!([{
        "global": {"version":0,"txVersion":0,"fallbackLockTime":null,"inputsModifiable":false,"outputsModifiable":false,"inputCount":1,"outputCount":1,"xpubs":{},"id":null,"proprietaries":{}},
        "inputs": [{
            "utxoEntry":{"amount":100_000_000u64,"scriptPublicKey":hex::encode(versioned(&input_spk)),"blockDaaScore":10,"isCoinbase":false},
            "previousOutpoint":{"transactionId":outpoint_hash.to_string(),"index":2},"sequence":0,"minTime":null,
            "partialSigs":{key_hex:{"schnorr":sig_hex}},"sighashType":1,"redeemScript":null,"sigOpCount":1,
            "bip32Derivations":{},"finalScriptSig":null,"proprietaries":{}
        }],
        "outputs":[{"amount":99_999_000u64,"scriptPublicKey":hex::encode(versioned(&output_spk)),"redeemScript":null,"bip32Derivations":{},"proprietaries":{}}]
    }]);
    let mut wire = b"PSKB".to_vec();
    wire.extend_from_slice(hex::encode(serde_json::to_vec(&body).unwrap()).as_bytes());
    let wire_hex = hex::encode(wire);
    kassee_web::verify_standard_p2pk_signatures_native(&wire_hex).unwrap();

    let encoded_sig = hex::encode(hex::encode(sig_hex.as_bytes()).as_bytes());
    let replacement = if sig_hex.starts_with("ff") { "00" } else { "ff" };
    let forged_text = format!("{}{}", replacement, &sig_hex[2..]);
    let forged_sig = hex::encode(hex::encode(forged_text.as_bytes()).as_bytes());
    let forged = wire_hex.replacen(&encoded_sig, &forged_sig, 1);
    assert!(kassee_web::verify_standard_p2pk_signatures_native(&forged).is_err());
}

struct Fixture {
    owner: Keypair,
    owner_pubkey: [u8; 32],
    approved_spk: ScriptPublicKey,
    other_spk: ScriptPublicKey,
    covenant_id: Hash,
    vault_script: Vec<u8>,
    vault_entry: UtxoEntry,
}

impl Fixture {
    fn new() -> Self {
        let secret = SecretKey::from_slice(&[7u8; 32]).unwrap();
        let owner = Keypair::from_secret_key(secp256k1::SECP256K1, &secret);
        let owner_pubkey = owner.x_only_public_key().0.serialize();
        let approved_spk = p2pk_spk(11);
        let other_spk = p2pk_spk(12);
        let vault_script = build_protected_vault_script(
            &owner_pubkey,
            &versioned(&approved_spk),
            DELAY_DAA,
            MAX_FEE,
        )
        .unwrap();
        let covenant_id = Hash::from_u64_word(42);
        let vault_entry = UtxoEntry::new(
            INPUT_VALUE,
            pay_to_script_hash_script(&vault_script),
            1_000,
            false,
            Some(covenant_id),
        );
        Self {
            owner,
            owner_pubkey,
            approved_spk,
            other_spk,
            covenant_id,
            vault_script,
            vault_entry,
        }
    }

    fn vault_tx(&self, output_spk: ScriptPublicKey, output_value: u64) -> Transaction {
        transaction(output_spk, output_value, 0, self.covenant_id)
    }
}

#[test]
fn approved_destination_executes_immediately() {
    let fixture = Fixture::new();
    let mut tx = fixture.vault_tx(fixture.approved_spk.clone(), INPUT_VALUE - FEE);
    sign_vault_branch(
        &mut tx,
        &fixture.vault_entry,
        &fixture.owner,
        &fixture.vault_script,
        true,
        None,
    );
    assert!(run_vm(&tx, &fixture.vault_entry).is_ok());
}

#[test]
fn each_committed_destination_is_immediate_and_an_unlisted_one_is_rejected() {
    let fixture = Fixture::new();
    let second = p2pk_spk(13);
    let vault_script = build_protected_vault_script_with_destinations(
        &fixture.owner_pubkey,
        &[versioned(&fixture.approved_spk), versioned(&second)],
        DELAY_DAA,
        MAX_FEE,
    )
    .unwrap();
    let vault_entry = UtxoEntry::new(
        INPUT_VALUE,
        pay_to_script_hash_script(&vault_script),
        1_000,
        false,
        Some(fixture.covenant_id),
    );
    for destination in [&fixture.approved_spk, &second] {
        let mut tx = fixture.vault_tx(destination.clone(), INPUT_VALUE - FEE);
        sign_vault_branch(&mut tx, &vault_entry, &fixture.owner, &vault_script, true, None);
        assert!(run_vm(&tx, &vault_entry).is_ok());
    }
    let mut unlisted = fixture.vault_tx(fixture.other_spk.clone(), INPUT_VALUE - FEE);
    sign_vault_branch(&mut unlisted, &vault_entry, &fixture.owner, &vault_script, true, None);
    assert!(run_vm(&unlisted, &vault_entry).is_err());
}

#[test]
fn five_committed_destinations_all_remain_spendable() {
    let fixture = Fixture::new();
    let destinations: Vec<_> = (20..25).map(p2pk_spk).collect();
    let approved_spks: Vec<_> = destinations.iter().map(versioned).collect();
    let vault_script = build_protected_vault_script_with_destinations(
        &fixture.owner_pubkey, &approved_spks, DELAY_DAA, MAX_FEE,
    )
    .unwrap();
    assert!(vault_script.len() <= 520);
    let vault_entry = UtxoEntry::new(
        INPUT_VALUE,
        pay_to_script_hash_script(&vault_script),
        1_000,
        false,
        Some(fixture.covenant_id),
    );
    for destination in destinations {
        let mut tx = fixture.vault_tx(destination, INPUT_VALUE - FEE);
        sign_vault_branch(&mut tx, &vault_entry, &fixture.owner, &vault_script, true, None);
        assert!(run_vm(&tx, &vault_entry).is_ok());
    }
}

#[test]
fn untagged_funding_utxo_cannot_enter_approved_path() {
    let fixture = Fixture::new();
    let untagged_entry = UtxoEntry::new(
        INPUT_VALUE,
        pay_to_script_hash_script(&fixture.vault_script),
        1_000,
        false,
        None,
    );
    let mut tx = fixture.vault_tx(fixture.approved_spk.clone(), INPUT_VALUE - FEE);
    tx.outputs[0].covenant = None;
    tx.populate_genesis_covenants(&[GenesisCovenantGroup::new(0, vec![0])])
        .unwrap();
    tx.finalize();
    sign_vault_branch(
        &mut tx,
        &untagged_entry,
        &fixture.owner,
        &fixture.vault_script,
        true,
        None,
    );
    assert!(run_vm(&tx, &untagged_entry).is_err());
}

#[test]
fn untagged_funding_utxo_cannot_enter_pending_path() {
    let fixture = Fixture::new();
    let untagged_entry = UtxoEntry::new(
        INPUT_VALUE,
        pay_to_script_hash_script(&fixture.vault_script),
        1_000,
        false,
        None,
    );
    let destination = versioned(&fixture.other_spk);
    let pending_script = build_protected_vault_pending_script(
        &fixture.owner_pubkey,
        &destination,
        DELAY_DAA,
        MAX_FEE,
    )
    .unwrap();
    let mut tx = fixture.vault_tx(
        pay_to_script_hash_script(&pending_script),
        INPUT_VALUE - FEE,
    );
    tx.outputs[0].covenant = None;
    tx.populate_genesis_covenants(&[GenesisCovenantGroup::new(0, vec![0])])
        .unwrap();
    tx.finalize();
    sign_vault_branch(
        &mut tx,
        &untagged_entry,
        &fixture.owner,
        &fixture.vault_script,
        false,
        Some(&destination),
    );
    assert!(run_vm(&tx, &untagged_entry).is_err());
}

#[test]
fn unapproved_destination_cannot_bypass_pending_stage() {
    let fixture = Fixture::new();
    let destination = versioned(&fixture.other_spk);
    let mut tx = fixture.vault_tx(fixture.other_spk.clone(), INPUT_VALUE - FEE);
    sign_vault_branch(
        &mut tx,
        &fixture.vault_entry,
        &fixture.owner,
        &fixture.vault_script,
        false,
        Some(&destination),
    );
    assert!(run_vm(&tx, &fixture.vault_entry).is_err());
}

#[test]
fn delayed_stage_commits_destination_and_rejects_substitution() {
    let fixture = Fixture::new();
    let destination = versioned(&fixture.other_spk);
    let pending_script = build_protected_vault_pending_script(
        &fixture.owner_pubkey,
        &destination,
        DELAY_DAA,
        MAX_FEE,
    )
    .unwrap();
    let mut tx = fixture.vault_tx(
        pay_to_script_hash_script(&pending_script),
        INPUT_VALUE - FEE,
    );
    sign_vault_branch(
        &mut tx,
        &fixture.vault_entry,
        &fixture.owner,
        &fixture.vault_script,
        false,
        Some(&destination),
    );
    assert!(run_vm(&tx, &fixture.vault_entry).is_ok());

    let substituted = versioned(&p2pk_spk(99));
    let substituted_pending = build_protected_vault_pending_script(
        &fixture.owner_pubkey,
        &substituted,
        DELAY_DAA,
        MAX_FEE,
    )
    .unwrap();
    let mut bad_tx = fixture.vault_tx(
        pay_to_script_hash_script(&substituted_pending),
        INPUT_VALUE - FEE,
    );
    sign_vault_branch(
        &mut bad_tx,
        &fixture.vault_entry,
        &fixture.owner,
        &fixture.vault_script,
        false,
        Some(&destination),
    );
    assert!(run_vm(&bad_tx, &fixture.vault_entry).is_err());
}

#[test]
fn pending_stage_rejects_early_sequence_and_accepts_boundary() {
    let fixture = Fixture::new();
    let destination = versioned(&fixture.other_spk);
    let pending_script = build_protected_vault_pending_script(
        &fixture.owner_pubkey,
        &destination,
        DELAY_DAA,
        MAX_FEE,
    )
    .unwrap();
    let pending_entry = UtxoEntry::new(
        INPUT_VALUE - FEE,
        pay_to_script_hash_script(&pending_script),
        2_000,
        false,
        Some(fixture.covenant_id),
    );

    let mut early = transaction(
        fixture.other_spk.clone(),
        INPUT_VALUE - (2 * FEE),
        DELAY_DAA - 1,
        fixture.covenant_id,
    );
    sign_pending(&mut early, &pending_entry, &fixture.owner, &pending_script);
    assert!(run_vm(&early, &pending_entry).is_err());

    let mut boundary = transaction(
        fixture.other_spk.clone(),
        INPUT_VALUE - (2 * FEE),
        DELAY_DAA,
        fixture.covenant_id,
    );
    sign_pending(
        &mut boundary,
        &pending_entry,
        &fixture.owner,
        &pending_script,
    );
    assert!(run_vm(&boundary, &pending_entry).is_ok());
}

#[test]
fn approved_branch_rejects_excessive_fee_and_extra_output() {
    let fixture = Fixture::new();
    let mut excessive_fee =
        fixture.vault_tx(fixture.approved_spk.clone(), INPUT_VALUE - MAX_FEE - 1);
    sign_vault_branch(
        &mut excessive_fee,
        &fixture.vault_entry,
        &fixture.owner,
        &fixture.vault_script,
        true,
        None,
    );
    assert!(run_vm(&excessive_fee, &fixture.vault_entry).is_err());

    let mut extra_output = fixture.vault_tx(fixture.approved_spk.clone(), INPUT_VALUE - FEE - 1);
    extra_output
        .outputs
        .push(TransactionOutput::new(1, p2pk_spk(13)));
    extra_output.finalize();
    sign_vault_branch(
        &mut extra_output,
        &fixture.vault_entry,
        &fixture.owner,
        &fixture.vault_script,
        true,
        None,
    );
    assert!(run_vm(&extra_output, &fixture.vault_entry).is_err());
}

#[test]
fn spend_without_authorized_covenant_binding_is_rejected() {
    let fixture = Fixture::new();
    let mut tx = fixture.vault_tx(fixture.approved_spk.clone(), INPUT_VALUE - FEE);
    tx.outputs[0].covenant = None;
    tx.finalize();
    sign_vault_branch(
        &mut tx,
        &fixture.vault_entry,
        &fixture.owner,
        &fixture.vault_script,
        true,
        None,
    );
    assert!(run_vm(&tx, &fixture.vault_entry).is_err());
}

#[test]
fn recovery_paths_execute_and_keep_the_delay_for_the_owner() {
    let fixture = Fixture::new();
    let recovery_secret = SecretKey::from_slice(&[31u8; 32]).unwrap();
    let recovery = Keypair::from_secret_key(secp256k1::SECP256K1, &recovery_secret);
    let recovery_pubkey = recovery.x_only_public_key().0.serialize();
    let recovery_spk = ScriptPublicKey::from_vec(0, {
        let mut script = vec![0x20];
        script.extend_from_slice(&recovery_pubkey);
        script.push(0xac);
        script
    });
    let destination = versioned(&fixture.other_spk);
    let pending_script = build_protected_vault_pending_script_with_recovery(
        &fixture.owner_pubkey, &destination, &versioned(&recovery_spk),
        DELAY_DAA, MAX_FEE,
    ).unwrap();
    let pending_spk = pay_to_script_hash_script(&pending_script);

    for emergency in [false, true] {
        let vault_script = build_protected_vault_script_with_recovery(
            &fixture.owner_pubkey, &[versioned(&fixture.approved_spk)],
            &versioned(&recovery_spk), DELAY_DAA, MAX_FEE, emergency,
        ).unwrap();
        let vault_entry = UtxoEntry::new(
            INPUT_VALUE, pay_to_script_hash_script(&vault_script),
            1_000, false, Some(fixture.covenant_id),
        );
        let mut approved = fixture.vault_tx(fixture.approved_spk.clone(), INPUT_VALUE - FEE);
        sign_v2_vault(
            &mut approved, &vault_entry, &fixture.owner, &vault_script,
            Some(true), None, emergency,
        );
        assert!(run_vm(&approved, &vault_entry).is_ok());

        let mut delayed = fixture.vault_tx(pending_spk.clone(), INPUT_VALUE - FEE);
        sign_v2_vault(
            &mut delayed, &vault_entry, &fixture.owner, &vault_script,
            Some(false), Some(&destination), emergency,
        );
        assert!(run_vm(&delayed, &vault_entry).is_ok());

        let mut recovery_spend = fixture.vault_tx(recovery_spk.clone(), INPUT_VALUE - FEE);
        sign_v2_vault(
            &mut recovery_spend, &vault_entry, &recovery, &vault_script,
            None, None, true,
        );
        let recovery_result = run_vm(&recovery_spend, &vault_entry);
        assert_eq!(recovery_result.is_ok(), emergency, "{recovery_result:?}");

        let mut recovery_to_other = fixture.vault_tx(fixture.other_spk.clone(), INPUT_VALUE - FEE);
        sign_v2_vault(
            &mut recovery_to_other, &vault_entry, &recovery, &vault_script,
            None, None, true,
        );
        assert!(run_vm(&recovery_to_other, &vault_entry).is_err());
    }

    let pending_entry = UtxoEntry::new(
        INPUT_VALUE - FEE, pending_spk, 2_000, false, Some(fixture.covenant_id),
    );
    let mut early = transaction(
        fixture.other_spk.clone(), INPUT_VALUE - 2 * FEE, DELAY_DAA - 1,
        fixture.covenant_id,
    );
    sign_v2_pending(&mut early, &pending_entry, &fixture.owner, &pending_script, false);
    assert!(run_vm(&early, &pending_entry).is_err());

    let mut mature = transaction(
        fixture.other_spk.clone(), INPUT_VALUE - 2 * FEE, DELAY_DAA,
        fixture.covenant_id,
    );
    sign_v2_pending(&mut mature, &pending_entry, &fixture.owner, &pending_script, false);
    assert!(run_vm(&mature, &pending_entry).is_ok());

    let mut cancel = transaction(
        recovery_spk.clone(), INPUT_VALUE - 2 * FEE, 0, fixture.covenant_id,
    );
    sign_v2_pending(&mut cancel, &pending_entry, &recovery, &pending_script, true);
    assert!(run_vm(&cancel, &pending_entry).is_ok());

    let mut cancel_elsewhere = transaction(
        fixture.other_spk.clone(), INPUT_VALUE - 2 * FEE, 0, fixture.covenant_id,
    );
    sign_v2_pending(
        &mut cancel_elsewhere, &pending_entry, &recovery, &pending_script, true,
    );
    assert!(run_vm(&cancel_elsewhere, &pending_entry).is_err());
}

#[test]
fn every_approved_destination_executes_with_five_address_recovery_vault() {
    let fixture = Fixture::new();
    let recovery_spk = p2pk_spk(50);
    let approved = (60..65).map(p2pk_spk).collect::<Vec<_>>();
    let approved_versioned = approved.iter().map(versioned).collect::<Vec<_>>();
    for emergency in [false, true] {
        let script = build_protected_vault_script_with_recovery(
            &fixture.owner_pubkey, &approved_versioned,
            &versioned(&recovery_spk), DELAY_DAA, MAX_FEE, emergency,
        ).unwrap();
        let entry = UtxoEntry::new(
            INPUT_VALUE, pay_to_script_hash_script(&script),
            1_000, false, Some(fixture.covenant_id),
        );
        for destination in &approved {
            let mut tx = fixture.vault_tx(destination.clone(), INPUT_VALUE - FEE);
            sign_v2_vault(&mut tx, &entry, &fixture.owner, &script, Some(true), None, emergency);
            assert!(run_vm(&tx, &entry).is_ok());
        }
        let mut unapproved = fixture.vault_tx(fixture.other_spk.clone(), INPUT_VALUE - FEE);
        sign_v2_vault(&mut unapproved, &entry, &fixture.owner, &script, Some(true), None, emergency);
        assert!(run_vm(&unapproved, &entry).is_err());
    }
}

#[test]
fn testnet_hot_owner_can_sign_and_spend_the_built_v2_pskb() {
    let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    let recovery_mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
    let owner_secret = kassee_web::testnet_test_vector_private_key(mnemonic, 0, 0).unwrap();
    let owner_keypair = Keypair::from_secret_key(
        secp256k1::SECP256K1, &SecretKey::from_slice(&owner_secret).unwrap()
    );
    let owner = owner_keypair.x_only_public_key().0.serialize();
    let approved_spk = p2pk_spk(11);
    let approved_address = kassee_web::encode_p2pk_address(
        &hex::encode(&versioned(&approved_spk)[3..35]), Some("testnet-10".into())
    ).unwrap();
    let recovery_secret_bytes = kassee_web::testnet_test_vector_private_key(
        recovery_mnemonic, 0, 0
    ).unwrap();
    let recovery_secret = SecretKey::from_slice(&recovery_secret_bytes).unwrap();
    let recovery_key = Keypair::from_secret_key(secp256k1::SECP256K1, &recovery_secret);
    let recovery_pubkey = recovery_key.x_only_public_key().0.serialize();
    let recovery_spk = p2pk_spk_from_key(&recovery_pubkey);
    let recovery_address = kassee_web::encode_p2pk_address(
        &hex::encode(recovery_pubkey), Some("testnet-10".into())
    ).unwrap();
    let vault_script = build_protected_vault_script_with_recovery(
        &owner, &[versioned(&approved_spk)], &versioned(&recovery_spk),
        DELAY_DAA, 10_000_000, true,
    ).unwrap();
    let covenant_id = Hash::from_u64_word(42);
    let vault_entry = UtxoEntry::new(INPUT_VALUE,
        pay_to_script_hash_script(&vault_script), 1_000, false,
        Some(covenant_id));
    let vault_utxo = serde_json::json!({
        "tx_id": Hash::from_u64_word(1).to_string(), "index": 0,
        "amount": INPUT_VALUE,
        "script_public_key": vault_entry.script_public_key.script(),
        "block_daa_score": 1000,
        "covenant_id": covenant_id.to_string(),
    });
    let pskb = kassee_web::create_protected_vault_v2_spend_pskb(
        &vault_utxo.to_string(), &hex::encode(owner),
        &serde_json::json!([approved_address]).to_string(),
        &recovery_address, &approved_address, DELAY_DAA, true,
        "approved", FEE,
    ).unwrap();
    let signed = kassee_web::sign_testnet10_vault_v2_pskb(
        &pskb, mnemonic, 0, 0,
    ).unwrap();
    assert!(!kassee_web::finalize_protected_vault_test_pskb(&signed).unwrap().is_empty());
    let mut tx = transaction(approved_spk, INPUT_VALUE - FEE, 0, covenant_id);
    tx.inputs[0].signature_script = kassee_web::finalized_v2_sigscript_native(&signed).unwrap();
    tx.finalize();
    assert!(run_vm(&tx, &vault_entry).is_ok());

    let other_spk = p2pk_spk(12);
    let other_address = kassee_web::encode_p2pk_address(
        &hex::encode(&versioned(&other_spk)[3..35]), Some("testnet-10".into())
    ).unwrap();
    let pending_script = build_protected_vault_pending_script_with_recovery(
        &owner, &versioned(&other_spk), &versioned(&recovery_spk),
        DELAY_DAA, 10_000_000,
    ).unwrap();
    let pending_spk = pay_to_script_hash_script(&pending_script);
    let begin = kassee_web::create_protected_vault_v2_spend_pskb(
        &vault_utxo.to_string(), &hex::encode(owner),
        &serde_json::json!([approved_address]).to_string(),
        &recovery_address, &other_address, DELAY_DAA, true,
        "beginDelay", FEE,
    ).unwrap();
    let begin_signed = kassee_web::sign_testnet10_vault_v2_pskb(
        &begin, mnemonic, 0, 0,
    ).unwrap();
    assert!(!kassee_web::finalize_protected_vault_test_pskb(&begin_signed).unwrap().is_empty());
    let mut begin_tx = transaction(pending_spk.clone(), INPUT_VALUE - FEE, 0, covenant_id);
    begin_tx.inputs[0].signature_script = kassee_web::finalized_v2_sigscript_native(&begin_signed).unwrap();
    begin_tx.finalize();
    assert!(run_vm(&begin_tx, &vault_entry).is_ok());

    let pending_entry = UtxoEntry::new(INPUT_VALUE - FEE, pending_spk.clone(),
        2_000, false, Some(covenant_id));
    let pending_utxo = serde_json::json!({
        "tx_id": Hash::from_u64_word(1).to_string(), "index": 0,
        "amount": INPUT_VALUE - FEE,
        "script_public_key": pending_spk.script(),
        "block_daa_score": 2000,
        "covenant_id": covenant_id.to_string(),
    });
    let mature = kassee_web::create_protected_vault_v2_pending_spend_pskb(
        &pending_utxo.to_string(), &hex::encode(owner), &recovery_address,
        &other_address, DELAY_DAA, "mature", FEE,
    ).unwrap();
    let mature_signed = kassee_web::sign_testnet10_vault_v2_pskb(
        &mature, mnemonic, 0, 0,
    ).unwrap();
    assert!(!kassee_web::finalize_protected_vault_test_pskb(&mature_signed).unwrap().is_empty());
    let mut mature_tx = transaction(other_spk, INPUT_VALUE - 2 * FEE,
        DELAY_DAA, covenant_id);
    mature_tx.inputs[0].signature_script = kassee_web::finalized_v2_sigscript_native(&mature_signed).unwrap();
    mature_tx.finalize();
    assert!(run_vm(&mature_tx, &pending_entry).is_ok());

    let cancel = kassee_web::create_protected_vault_v2_pending_spend_pskb(
        &pending_utxo.to_string(), &hex::encode(owner), &recovery_address,
        &other_address, DELAY_DAA, "cancel", FEE,
    ).unwrap();
    let cancel_signed = kassee_web::sign_testnet10_vault_v2_pskb(
        &cancel, recovery_mnemonic, 0, 0,
    ).unwrap();
    assert!(!kassee_web::finalize_protected_vault_test_pskb(&cancel_signed).unwrap().is_empty());
    let mut cancel_tx = transaction(recovery_spk.clone(), INPUT_VALUE - 2 * FEE,
        0, covenant_id);
    cancel_tx.inputs[0].signature_script = kassee_web::finalized_v2_sigscript_native(&cancel_signed).unwrap();
    cancel_tx.finalize();
    assert!(run_vm(&cancel_tx, &pending_entry).is_ok());

    let emergency = kassee_web::create_protected_vault_v2_spend_pskb(
        &vault_utxo.to_string(), &hex::encode(owner),
        &serde_json::json!([approved_address]).to_string(),
        &recovery_address, &recovery_address, DELAY_DAA, true,
        "emergency", FEE,
    ).unwrap();
    let emergency_signed = kassee_web::sign_testnet10_vault_v2_pskb(
        &emergency, recovery_mnemonic, 0, 0,
    ).unwrap();
    assert!(!kassee_web::finalize_protected_vault_test_pskb(&emergency_signed).unwrap().is_empty());
    let mut emergency_tx = transaction(recovery_spk, INPUT_VALUE - FEE, 0, covenant_id);
    emergency_tx.inputs[0].signature_script = kassee_web::finalized_v2_sigscript_native(&emergency_signed).unwrap();
    emergency_tx.finalize();
    assert!(run_vm(&emergency_tx, &vault_entry).is_ok());
}

fn p2pk_spk_from_key(key: &[u8; 32]) -> ScriptPublicKey {
    let mut script = vec![0x20];
    script.extend_from_slice(key);
    script.push(0xac);
    ScriptPublicKey::from_vec(0, script)
}

fn sign_v2_vault(
    tx: &mut Transaction,
    entry: &UtxoEntry,
    signer: &Keypair,
    redeem_script: &[u8],
    approved: Option<bool>,
    destination: Option<&[u8]>,
    emergency: bool,
) {
    let signature = signature(tx, entry, signer);
    let mut builder = ScriptBuilder::new();
    if let Some(destination) = destination {
        builder.add_data(destination).unwrap();
    }
    if let Some(approved) = approved {
        builder.add_op(if approved { OpTrue } else { OpFalse }).unwrap();
    }
    builder.add_data(&signature).unwrap();
    if emergency {
        builder.add_op(if approved.is_none() { OpTrue } else { OpFalse }).unwrap();
    }
    builder.add_data(redeem_script).unwrap();
    tx.inputs[0].signature_script = builder.drain();
    tx.finalize();
}

fn sign_v2_pending(
    tx: &mut Transaction,
    entry: &UtxoEntry,
    signer: &Keypair,
    redeem_script: &[u8],
    recovery: bool,
) {
    let signature = signature(tx, entry, signer);
    tx.inputs[0].signature_script = ScriptBuilder::new()
        .add_data(&signature).unwrap()
        .add_op(if recovery { OpTrue } else { OpFalse }).unwrap()
        .add_data(redeem_script).unwrap()
        .drain();
    tx.finalize();
}

fn transaction(
    output_spk: ScriptPublicKey,
    output_value: u64,
    sequence: u64,
    covenant_id: Hash,
) -> Transaction {
    let input = TransactionInput::new_with_compute_budget(
        TransactionOutpoint::new(Hash::from_u64_word(1), 0),
        vec![],
        sequence,
        10,
    );
    let mut output = TransactionOutput::new(output_value, output_spk);
    output.covenant = Some(CovenantBinding::new(0, covenant_id));
    let mut tx = Transaction::new(
        1,
        vec![input],
        vec![output],
        0,
        SubnetworkId::default(),
        0,
        vec![],
    );
    tx.finalize();
    tx
}

fn sign_vault_branch(
    tx: &mut Transaction,
    entry: &UtxoEntry,
    owner: &Keypair,
    redeem_script: &[u8],
    approved: bool,
    destination: Option<&[u8]>,
) {
    let signature = signature(tx, entry, owner);
    let mut builder = ScriptBuilder::new();
    if let Some(destination) = destination {
        builder.add_data(destination).unwrap();
    }
    if approved {
        builder.add_op(OpTrue).unwrap();
    } else {
        builder.add_op(OpFalse).unwrap();
    }
    builder.add_data(&signature).unwrap();
    builder.add_data(redeem_script).unwrap();
    tx.inputs[0].signature_script = builder.drain();
    tx.finalize();
}

fn sign_pending(tx: &mut Transaction, entry: &UtxoEntry, owner: &Keypair, redeem_script: &[u8]) {
    let signature = signature(tx, entry, owner);
    tx.inputs[0].signature_script = ScriptBuilder::new()
        .add_data(&signature)
        .unwrap()
        .add_data(redeem_script)
        .unwrap()
        .drain();
    tx.finalize();
}

fn signature(tx: &Transaction, entry: &UtxoEntry, owner: &Keypair) -> Vec<u8> {
    let reused = SigHashReusedValuesUnsync::new();
    let mutable = MutableTransaction::with_entries(tx.clone(), vec![entry.clone()]);
    let hash = calc_schnorr_signature_hash(&mutable.as_verifiable(), 0, SIG_HASH_ALL, &reused);
    let message = Message::from_digest_slice(hash.as_bytes().as_slice()).unwrap();
    let mut signature = owner.sign_schnorr(message).as_ref().to_vec();
    signature.push(SIG_HASH_ALL.to_u8());
    signature
}

fn run_vm(tx: &Transaction, entry: &UtxoEntry) -> Result<(), TxScriptError> {
    let populated = PopulatedTransaction::new(tx, vec![entry.clone()]);
    let covenants = CovenantsContext::from_tx(&populated).unwrap();
    let sig_cache = Cache::new(10_000);
    let reused = SigHashReusedValuesUnsync::new();
    let ctx = EngineCtx::new(&sig_cache)
        .with_reused(&reused)
        .with_covenants_ctx(&covenants);
    let flags = EngineFlags {
        covenants_enabled: true,
        ..Default::default()
    };
    let mut vm =
        TxScriptEngine::from_transaction_input(&populated, &tx.inputs[0], 0, entry, ctx, flags);
    vm.execute()
}

fn p2pk_spk(byte: u8) -> ScriptPublicKey {
    let mut script = vec![0x20];
    script.extend_from_slice(&[byte; 32]);
    script.push(0xac);
    ScriptPublicKey::from_vec(0, script)
}

fn versioned(spk: &ScriptPublicKey) -> Vec<u8> {
    let mut bytes = spk.version().to_be_bytes().to_vec();
    bytes.extend_from_slice(spk.script());
    bytes
}
