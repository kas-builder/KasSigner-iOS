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
use kassee_web::{build_protected_vault_pending_script, build_protected_vault_script};
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
