// KasSee Web — KSPT binary format
// Copyright (C) 2025-2026 KasSigner Project (kassigner@proton.me)
// License: GPL-3.0
//
// kspt.rs — KSPT serialization for unsigned TX creation.
// Format: "KSPT" + version(1) + flags(1) + global + inputs + outputs
// Supports single and compound (multi-recipient) transactions.

//! Core KSPT/PSKB transaction construction plus the shared script-building
//! primitives (opcode table `covenant_ops`, push helpers, address conversion)
//! used by every covenant builder. The covenant redeem-script builders live in
//! the `kspt_*` submodules and are re-exported here as `kspt::build_*`.

use crate::bip32::WalletData;
use crate::rpc::UtxoEntry;
use k256::elliptic_curve::sec1::ToEncodedPoint;
use serde::{Deserialize, Serialize};

/// Blake2b-256 hash — unkeyed (matches firmware sighash::blake2b_hash for P2SH)
pub fn blake2b_hash(data: &[u8]) -> [u8; 32] {
    let h = blake2b_simd::Params::new().hash_length(32).hash(data);
    let mut out = [0u8; 32];
    out.copy_from_slice(h.as_bytes());
    out
}

const STORAGE_MASS_C: u64 = 1_000_000_000_000;
const MAX_STANDARD_MASS: u64 = 100_000;
const MINIMUM_RELAY_TRANSACTION_FEE: u64 = 100_000;
const STANDARD_OUTPUT_SIZE_PLUS_INPUT_SIZE_3X: u64 = (8 + 2 + 8 + 35 + 148) * 3;

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct ExplicitChangeOutput {
    pub address: String,
    pub amount_sompi: u64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct ExplicitRecipient {
    pub address: String,
    pub amount_sompi: u64,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct ExplicitChangeFeePlan {
    pub fee_sompi: u64,
    pub available_change_sompi: u64,
    pub amounts_sompi: Vec<u64>,
}

fn validate_transaction_mode_change_count(
    transaction_mode: &str,
    change_count: usize,
) -> Result<(), String> {
    match transaction_mode {
        "standard" if change_count <= 1 => Ok(()),
        "privacyFocused" if (2..=4).contains(&change_count) => Ok(()),
        "decoy" if change_count == 4 => Ok(()),
        "standard" => Err("Standard Send supports at most one change output".into()),
        "privacyFocused" => {
            Err("Privacy-Focused Send requires two to four change outputs".into())
        }
        "decoy" => Err("Decoy Transaction requires exactly four change outputs".into()),
        _ => Err("Unknown transaction type".into()),
    }
}

fn securely_shuffle_outputs<T>(outputs: &mut [T]) -> Result<(), String> {
    for upper in (1..outputs.len()).rev() {
        let mut bytes = [0u8; 8];
        getrandom::getrandom(&mut bytes)
            .map_err(|_| "Secure output randomization is unavailable".to_string())?;
        let index = (u64::from_le_bytes(bytes) % (upper as u64 + 1)) as usize;
        outputs.swap(upper, index);
    }
    Ok(())
}

fn validate_explicit_change_outputs(
    wallet: &WalletData,
    change_outputs: &[ExplicitChangeOutput],
) -> Result<(u64, Vec<Vec<u8>>), String> {
    if change_outputs.len() > 4 {
        return Err("A transaction can contain at most four change outputs".into());
    }
    let normalized_wallet_changes: std::collections::HashSet<String> = wallet
        .change_addresses
        .iter()
        .map(|address| address.trim().to_ascii_lowercase())
        .collect();
    let mut seen_change_addresses = std::collections::HashSet::new();
    let mut total = 0u64;
    let mut scripts = Vec::with_capacity(change_outputs.len());
    for output in change_outputs {
        let normalized = output.address.trim().to_ascii_lowercase();
        if normalized.is_empty() || !normalized_wallet_changes.contains(&normalized) {
            return Err("Every change output must use a wallet change address".into());
        }
        if !seen_change_addresses.insert(normalized) {
            return Err("Duplicate change addresses are not allowed".into());
        }
        if output.amount_sompi == 0 || is_dust(output.amount_sompi) {
            return Err("Every change output must be above the dust limit".into());
        }
        total = total
            .checked_add(output.amount_sompi)
            .ok_or_else(|| "Change output total overflow".to_string())?;
        scripts.push(crate::address::address_to_script_pubkey(&output.address)?);
    }
    Ok((total, scripts))
}

const MINIMUM_DECOY_CHANGE_SOMPI: u64 = 66_900;

fn split_decoy_remainder(
    remainder: u64,
    decoy_amount: u64,
    weights: [u8; 3],
) -> Result<[u64; 3], String> {
    if remainder < MINIMUM_DECOY_CHANGE_SOMPI * 3 {
        return Err("Insufficient selected funds for four valid Decoy Transaction change outputs".into());
    }
    let weight_total = weights.iter().map(|weight| *weight as u128).sum::<u128>();
    let first = (remainder as u128 * weights[0] as u128 / weight_total) as u64;
    let second = (remainder as u128 * weights[1] as u128 / weight_total) as u64;

    // A second output matching the payment would defeat the one-decoy rule.
    // Small adjustments preserve both the total and the balanced shape.
    let adjustments = [0i64, -1, 1, -2, 2, -3, 3, -4, 4];
    for first_adjustment in adjustments {
        for second_adjustment in adjustments {
            let adjusted_first = first.checked_add_signed(first_adjustment);
            let adjusted_second = second.checked_add_signed(second_adjustment);
            let (Some(adjusted_first), Some(adjusted_second)) =
                (adjusted_first, adjusted_second)
            else {
                continue;
            };
            let Some(adjusted_third) = remainder
                .checked_sub(adjusted_first)
                .and_then(|value| value.checked_sub(adjusted_second))
            else {
                continue;
            };
            let amounts = [adjusted_first, adjusted_second, adjusted_third];
            if amounts.iter().all(|amount| {
                *amount >= MINIMUM_DECOY_CHANGE_SOMPI
                    && !is_dust(*amount)
                    && *amount != decoy_amount
            }) {
                return Ok(amounts);
            }
        }
    }
    Err("This payment amount cannot produce exactly one matching decoy output with the selected funds".into())
}

/// Mirrors rusty-kaspa wallet/core/src/tx/mass.rs `MassCalculator::is_dust`.
fn is_dust(amount: u64) -> bool {
    match amount.checked_mul(1000) {
        Some(value_1000) => {
            value_1000 / STANDARD_OUTPUT_SIZE_PLUS_INPUT_SIZE_3X < MINIMUM_RELAY_TRANSACTION_FEE
        }
        None => {
            (amount as u128 * 1000 / STANDARD_OUTPUT_SIZE_PLUS_INPUT_SIZE_3X as u128)
                < MINIMUM_RELAY_TRANSACTION_FEE as u128
        }
    }
}

/// Mainnet compute mass for a version-0, payload-free, single-signature P2PK
/// transaction. Constants and serialization sizes mirror rusty-kaspa's
/// `MassCalculator` at the pinned stable reference.
fn standard_compute_mass(
    input_count: usize,
    output_script_lengths: &[usize],
) -> Result<u64, String> {
    const BLANK_TRANSACTION_SERIALIZED_SIZE: u64 = 94;
    const UNSIGNED_STANDARD_INPUT_MASS: u64 = 36 + 8 + 8 + 66 + 1000;

    let inputs = UNSIGNED_STANDARD_INPUT_MASS
        .checked_mul(input_count as u64)
        .ok_or_else(|| "Transaction compute mass overflow".to_string())?;
    let outputs = output_script_lengths
        .iter()
        .try_fold(0u64, |mass, script_len| {
            let serialized_size = 8u64
                .checked_add(2)
                .and_then(|v| v.checked_add(8))
                .and_then(|v| v.checked_add(*script_len as u64))
                .ok_or_else(|| "Transaction output mass overflow".to_string())?;
            let script_mass = 10u64
                .checked_mul(2 + *script_len as u64)
                .ok_or_else(|| "Transaction script mass overflow".to_string())?;
            mass.checked_add(serialized_size)
                .and_then(|v| v.checked_add(script_mass))
                .ok_or_else(|| "Transaction compute mass overflow".to_string())
        })?;

    BLANK_TRANSACTION_SERIALIZED_SIZE
        .checked_add(inputs)
        .and_then(|v| v.checked_add(outputs))
        .ok_or_else(|| "Transaction compute mass overflow".to_string())
}

fn minimum_relay_fee(compute_mass: u64) -> u64 {
    let fee = compute_mass.saturating_mul(MINIMUM_RELAY_TRANSACTION_FEE) / 1000;
    if fee == 0 {
        MINIMUM_RELAY_TRANSACTION_FEE
    } else {
        fee
    }
}

fn fee_for_mass(compute_mass: u64, transaction_mass: u64, fee_rate: f64) -> Result<u64, String> {
    if !fee_rate.is_finite() || fee_rate < 0.0 {
        return Err("Invalid transaction fee rate".into());
    }
    let rate_fee_f64 = fee_rate * transaction_mass as f64;
    if rate_fee_f64 > u64::MAX as f64 {
        return Err("Transaction fee overflow".into());
    }
    // Matches rusty-kaspa Generator::calc_fee_rate.
    let rate_fee = rate_fee_f64 as u64;
    Ok(minimum_relay_fee(compute_mass).max(rate_fee))
}

pub fn plan_explicit_change_fee(
    wallet: &WalletData,
    transaction_mode: &str,
    recipients: Vec<ExplicitRecipient>,
    exact_fee_sompi: u64,
    fee_rate_sompi_per_gram: f64,
    mut change_outputs: Vec<ExplicitChangeOutput>,
    selected: &[crate::rpc::UtxoEntry],
) -> Result<ExplicitChangeFeePlan, String> {
    if selected.is_empty() {
        return Err("No UTXOs provided".into());
    }
    if change_outputs.is_empty() {
        return Err("Select at least one change address".into());
    }
    validate_transaction_mode_change_count(transaction_mode, change_outputs.len())?;
    if recipients.is_empty() || recipients.len() > 4 {
        return Err("A transaction requires one to four recipients".into());
    }
    if transaction_mode == "decoy" && recipients.len() != 1 {
        return Err("Decoy Transaction supports exactly one recipient".into());
    }
    if recipients.iter().any(|recipient| recipient.amount_sompi == 0 || is_dust(recipient.amount_sompi)) {
        return Err("Every destination amount must be above the dust limit".into());
    }
    let recipient_total = recipients.iter().try_fold(0u64, |total, recipient| {
        total.checked_add(recipient.amount_sompi)
            .ok_or_else(|| "Recipient total overflow".to_string())
    })?;
    let decoy_amount = recipients[0].amount_sompi;

    let selected_total = selected.iter().try_fold(0u64, |total, utxo| {
        total
            .checked_add(utxo.amount)
            .ok_or_else(|| "Selected UTXO total overflow".to_string())
    })?;
    let automatic_decoy_split = transaction_mode == "decoy"
        && change_outputs.iter().skip(1).all(|output| output.amount_sompi == 0);
    let decoy_weights = if automatic_decoy_split {
        let mut bytes = [0u8; 3];
        getrandom::getrandom(&mut bytes)
            .map_err(|_| "Secure decoy change splitting is unavailable".to_string())?;
        Some(bytes.map(|byte| 75 + byte % 51))
    } else {
        None
    };
    if transaction_mode == "decoy" {
        change_outputs[0].amount_sompi = decoy_amount;
        if let Some(weights) = decoy_weights {
            let tentative_remainder = selected_total
                .checked_sub(recipient_total)
                .and_then(|value| value.checked_sub(decoy_amount))
                .ok_or_else(|| "Selected UTXOs cannot fund the matching decoy amount".to_string())?;
            let amounts = split_decoy_remainder(tentative_remainder, decoy_amount, weights)?;
            for (output, amount) in change_outputs.iter_mut().skip(1).zip(amounts) {
                output.amount_sompi = amount;
            }
        }
    }

    let recipient_scripts = recipients.iter()
        .map(|recipient| crate::address::address_to_script_pubkey(&recipient.address))
        .collect::<Result<Vec<_>, _>>()?;
    let (_, change_scripts) = validate_explicit_change_outputs(wallet, &change_outputs)?;
    let fixed_change = change_outputs
        .iter()
        .take(change_outputs.len() - 1)
        .try_fold(0u64, |total, output| {
            total
                .checked_add(output.amount_sompi)
                .ok_or_else(|| "Change output total overflow".to_string())
        })?;
    let mut script_lengths = Vec::with_capacity(recipient_scripts.len() + change_scripts.len());
    script_lengths.extend(recipient_scripts.iter().map(Vec::len));
    script_lengths.extend(change_scripts.iter().map(Vec::len));
    let compute_mass = standard_compute_mass(selected.len(), &script_lengths)?;
    let inputs: Vec<(u64, u64)> = selected.iter().map(|utxo| (utxo.amount, 1)).collect();

    for _ in 0..64 {
        let mut storage_outputs = Vec::with_capacity(recipients.len() + change_outputs.len());
        storage_outputs.extend(recipients.iter().map(|recipient| (recipient.amount_sompi, 1)));
        storage_outputs.extend(change_outputs.iter().map(|output| (output.amount_sompi, 1)));
        let mass = compute_mass.max(storage_mass_estimate(&inputs, &storage_outputs));
        if mass > MAX_STANDARD_MASS {
            return Err(format!(
                "Transaction mass {} exceeds the standard limit {}",
                mass, MAX_STANDARD_MASS
            ));
        }
        let fee = if exact_fee_sompi > 0 {
            let minimum_fee = minimum_relay_fee(compute_mass);
            if exact_fee_sompi < minimum_fee {
                return Err(format!(
                    "Custom fee is below the minimum relay fee of {} sompi",
                    minimum_fee
                ));
            }
            exact_fee_sompi
        } else {
            fee_for_mass(compute_mass, mass, fee_rate_sompi_per_gram)?
        };
        let available_change = selected_total
            .checked_sub(recipient_total)
            .and_then(|value| value.checked_sub(fee))
            .ok_or_else(|| "Selected UTXOs cannot cover the amount and fee".to_string())?;
        if transaction_mode == "decoy" {
            let remainder = available_change
                .checked_sub(decoy_amount)
                .ok_or_else(|| "Selected UTXOs cannot fund the matching decoy amount".to_string())?;
            let remaining_amounts = if let Some(weights) = decoy_weights {
                split_decoy_remainder(remainder, decoy_amount, weights)?
            } else {
                let first = change_outputs[1].amount_sompi;
                let second = change_outputs[2].amount_sompi;
                let third = remainder
                    .checked_sub(first)
                    .and_then(|value| value.checked_sub(second))
                    .ok_or_else(|| "The other change amounts leave no value for the final output".to_string())?;
                let amounts = [first, second, third];
                if amounts.iter().any(|amount| {
                    *amount < MINIMUM_DECOY_CHANGE_SOMPI || is_dust(*amount)
                }) {
                    return Err("Insufficient selected funds for four valid Decoy Transaction change outputs".into());
                }
                if amounts.contains(&decoy_amount) {
                    return Err("Only one change output may match the destination amount".into());
                }
                amounts
            };
            let next_amounts = [
                decoy_amount,
                remaining_amounts[0],
                remaining_amounts[1],
                remaining_amounts[2],
            ];
            if change_outputs
                .iter()
                .map(|output| output.amount_sompi)
                .eq(next_amounts)
            {
                return Ok(ExplicitChangeFeePlan {
                    fee_sompi: fee,
                    available_change_sompi: available_change,
                    amounts_sompi: next_amounts.to_vec(),
                });
            }
            for (output, amount) in change_outputs.iter_mut().zip(next_amounts) {
                output.amount_sompi = amount;
            }
            continue;
        }

        let final_amount = available_change.checked_sub(fixed_change).ok_or_else(|| {
            "The earlier change amounts leave no value for the final output".to_string()
        })?;
        if final_amount == 0 || is_dust(final_amount) {
            return Err("The final change output would be dust".into());
        }
        let last = change_outputs.len() - 1;
        if change_outputs[last].amount_sompi == final_amount {
            return Ok(ExplicitChangeFeePlan {
                fee_sompi: fee,
                available_change_sompi: available_change,
                amounts_sompi: change_outputs
                    .iter()
                    .map(|output| output.amount_sompi)
                    .collect(),
            });
        }
        change_outputs[last].amount_sompi = final_amount;
    }

    Err("Change-output fee calculation did not converge".into())
}

#[derive(Clone, Copy, Debug)]
struct StandardSendPlan {
    amount: u64,
    fee: u64,
    change: u64,
    mass: u64,
}

fn standard_send_plan(
    selected: &[crate::rpc::UtxoEntry],
    requested_amount: u64,
    destination_script_len: usize,
    change_script_len: usize,
    fee_rate: f64,
    exact_fee: u64,
    send_max: bool,
) -> Result<StandardSendPlan, String> {
    let selected_total = selected.iter().try_fold(0u64, |total, utxo| {
        total
            .checked_add(utxo.amount)
            .ok_or_else(|| "Selected UTXO total overflow".to_string())
    })?;
    let inputs: Vec<(u64, u64)> = selected.iter().map(|u| (u.amount, 1)).collect();
    let compute_no_change = standard_compute_mass(selected.len(), &[destination_script_len])?;
    let compute_with_change =
        standard_compute_mass(selected.len(), &[destination_script_len, change_script_len])?;

    let policy_fee = |compute_mass: u64, transaction_mass: u64| -> Result<u64, String> {
        let minimum = minimum_relay_fee(compute_mass);
        if exact_fee > 0 {
            if exact_fee < minimum {
                return Err(format!(
                    "Custom fee is below the minimum relay fee of {} sompi",
                    minimum
                ));
            }
            Ok(exact_fee)
        } else {
            fee_for_mass(compute_mass, transaction_mass, fee_rate)
        }
    };

    if send_max {
        // Send Max has exactly one output. Stabilize the output-dependent storage
        // mass until the exact fee no longer changes; no safety multiplier is used.
        let mut fee = policy_fee(compute_no_change, compute_no_change)?;
        for _ in 0..64 {
            let amount = selected_total
                .checked_sub(fee)
                .ok_or_else(|| "Selected UTXOs cannot cover the transaction fee".to_string())?;
            if amount == 0 || is_dust(amount) {
                return Err("The Send Max output would be dust".into());
            }
            let storage = storage_mass_estimate(&inputs, &[(amount, 1)]);
            let mass = compute_no_change.max(storage);
            if mass > MAX_STANDARD_MASS {
                return Err(format!(
                    "Transaction mass {} exceeds the standard limit {}",
                    mass, MAX_STANDARD_MASS
                ));
            }
            let next_fee = policy_fee(compute_no_change, mass)?;
            if next_fee == fee {
                return Ok(StandardSendPlan {
                    amount,
                    fee,
                    change: 0,
                    mass,
                });
            }
            fee = next_fee;
        }
        return Err("Send Max fee calculation did not converge".into());
    }

    if requested_amount == 0 || is_dust(requested_amount) {
        return Err("The destination amount would be dust".into());
    }
    let preliminary_change = selected_total
        .checked_sub(requested_amount)
        .ok_or_else(|| "Selected UTXOs do not cover the destination amount".to_string())?;
    let storage_no_change = storage_mass_estimate(&inputs, &[(requested_amount, 1)]);
    let mass_no_change = compute_no_change.max(storage_no_change);
    let fee_no_change = policy_fee(compute_no_change, mass_no_change)?;

    let (mut mass, mut fee, mut change) = if preliminary_change == 0 || is_dust(preliminary_change)
    {
        (mass_no_change, fee_no_change, 0)
    } else {
        let storage_with_change =
            storage_mass_estimate(&inputs, &[(requested_amount, 1), (preliminary_change, 1)]);
        let mass_with_change = compute_with_change.max(storage_with_change);
        let fee_with_change = policy_fee(compute_with_change, mass_with_change)?;
        let additional_fee = fee_with_change.saturating_sub(fee_no_change);

        if additional_fee > preliminary_change {
            (mass_no_change, fee_no_change, 0)
        } else {
            let change = selected_total
                .checked_sub(requested_amount)
                .and_then(|v| v.checked_sub(fee_with_change))
                .ok_or_else(|| "Selected UTXOs cannot cover the amount and fee".to_string())?;
            (mass_with_change, fee_with_change, change)
        }
    };

    if change > 0 && is_dust(change) {
        if exact_fee > 0 {
            return Err(
                "The exact custom fee would leave dust change; adjust the amount or fee".into(),
            );
        }
        fee = selected_total
            .checked_sub(requested_amount)
            .ok_or_else(|| "Selected UTXOs cannot cover the amount".to_string())?;
        change = 0;
        mass = mass_no_change;
    }
    if change == 0 {
        let absorbed_fee = selected_total
            .checked_sub(requested_amount)
            .ok_or_else(|| "Selected UTXOs cannot cover the amount".to_string())?;
        if exact_fee > 0 && absorbed_fee != exact_fee {
            return Err(
                "The exact custom fee would require absorbing change; adjust the amount or fee"
                    .into(),
            );
        }
        fee = absorbed_fee;
    }
    if mass > MAX_STANDARD_MASS {
        return Err(format!(
            "Transaction mass {} exceeds the standard limit {}",
            mass, MAX_STANDARD_MASS
        ));
    }
    let needed = requested_amount
        .checked_add(fee)
        .ok_or_else(|| "Transaction amount overflow".to_string())?;
    if needed > selected_total {
        return Err(format!(
            "Selected UTXOs contain {} sompi but the transaction needs {} sompi",
            selected_total, needed
        ));
    }

    Ok(StandardSendPlan {
        amount: requested_amount,
        fee,
        change,
        mass,
    })
}

/// Consensus-mirroring storage mass (KIP-9 with v2.0.1 plurality).
///
/// Each element is (amount_sompi, plurality). Plurality is 1 for every
/// standard P2PK/P2SH UTXO and 2 for a covenant_id-tagged UTXO (the
/// 32-byte covenant hash pushes the entry past one 100-byte storage
/// unit). Integer math identical to rusty-kaspa v2.0.1
/// consensus/core/src/mass/mod.rs calc_storage_mass, with saturation
/// where consensus returns None (mass "too high" either way):
///
///   harmonic term per element:  C * p^2 / amount
///   relaxed path (|O|=1, |I|=1, or |O|=|I|=2, in plurality terms):
///       max(0, harmonic_outs - harmonic_ins)
///   otherwise:
///       max(0, harmonic_outs - |I| * (C / (sum_ins / |I|)))
///
/// The previous f64 version applied the harmonic formula to inputs
/// unconditionally; on the arithmetic path consensus subtracts LESS
/// (AM >= HM), so that version underestimated storage mass exactly in
/// the multi-input-plus-change case.
pub(crate) fn storage_mass_estimate(ins: &[(u64, u64)], outs: &[(u64, u64)]) -> u64 {
    const C: u64 = STORAGE_MASS_C;

    let mut outs_plurality: u64 = 0;
    let mut harmonic_outs: u64 = 0;
    for &(amount, p) in outs {
        outs_plurality += p;
        harmonic_outs =
            harmonic_outs.saturating_add(C.saturating_mul(p).saturating_mul(p) / amount.max(1));
    }

    let ins_plurality: u64 = ins.iter().map(|&(_, p)| p).sum();
    let relaxed =
        outs_plurality == 1 || ins_plurality == 1 || (outs_plurality == 2 && ins_plurality == 2);

    if relaxed {
        let harmonic_ins = ins.iter().fold(0u64, |acc, &(amount, p)| {
            acc.saturating_add(C.saturating_mul(p).saturating_mul(p) / amount.max(1))
        });
        return harmonic_outs.saturating_sub(harmonic_ins);
    }

    let sum_ins: u64 = ins.iter().fold(0u64, |acc, &(a, _)| acc.saturating_add(a));
    let mean_ins = (sum_ins / ins_plurality.max(1)).max(1);
    let arithmetic_ins = ins_plurality.saturating_mul(C / mean_ins);
    harmonic_outs.saturating_sub(arithmetic_ins)
}

/// Create unsigned KSPT: fetch UTXOs, select coins, build binary, return hex
pub async fn create_send_kspt(
    wallet: &WalletData,
    dest_address: &str,
    amount_sompi: u64,
    fee: u64,
    ws_url: &str,
) -> Result<String, String> {
    let dest_script = crate::address::address_to_script_pubkey(dest_address)?;

    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;
    all_utxos.sort_by(|a, b| b.amount.cmp(&a.amount));

    let total_needed = amount_sompi + fee;
    let mut selected = Vec::new();
    let mut selected_total: u64 = 0;

    for utxo in all_utxos {
        selected_total += utxo.amount;
        selected.push(utxo);
        if selected_total >= total_needed {
            break;
        }
    }

    if selected_total < total_needed {
        return Err(format!(
            "Insufficient funds: have {} sompi ({:.8} KAS), need {} sompi",
            selected_total,
            selected_total as f64 / 1e8,
            total_needed,
        ));
    }

    let change_amount = selected_total - amount_sompi - fee;

    if amount_sompi > 0 && is_dust(amount_sompi) {
        return Err(format!(
            "Amount too small: {:.8} KAS. Minimum ~0.1 KAS.",
            amount_sompi as f64 / 1e8
        ));
    }

    // Absorb dust change into fee
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    let change_script = if final_change > 0 {
        let chg_idx = wallet.next_change_index;
        if chg_idx >= wallet.change_addresses.len() {
            return Err("No more change addresses. Re-import kpub.".into());
        }
        Some(crate::address::address_to_script_pubkey(
            &wallet.change_addresses[chg_idx],
        )?)
    } else {
        None
    };

    // Build outputs
    let mut outputs = vec![(amount_sompi, dest_script)];
    if let Some(chg_script) = change_script {
        outputs.push((final_change, chg_script));
    }

    let kspt_hex = serialize_kspt_multi(&selected, &outputs)?;

    web_sys::console::log_1(
        &format!(
            "[KasSee] TX: {} inputs, send {}, change {}, {} bytes",
            selected.len(),
            amount_sompi,
            final_change,
            kspt_hex.len() / 2
        )
        .into(),
    );

    Ok(kspt_hex)
}

/// Send to a raw script_public_key (arbitrary bytes). Used for KasFreeze test.
/// Same as create_send_kspt but takes raw SPK bytes instead of an address.
// Kept: send-to-raw-script-pubkey helper, reusable primitive.
#[allow(dead_code)]
pub async fn create_send_to_raw_spk(
    wallet: &WalletData,
    spk_hex: &str,
    amount_sompi: u64,
    fee: u64,
    ws_url: &str,
) -> Result<String, String> {
    let dest_script = hex::decode(spk_hex).map_err(|e| format!("Bad SPK hex: {}", e))?;

    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;
    all_utxos.sort_by(|a, b| b.amount.cmp(&a.amount));

    let total_needed = amount_sompi + fee;
    let mut selected = Vec::new();
    let mut selected_total: u64 = 0;

    for utxo in all_utxos {
        selected_total += utxo.amount;
        selected.push(utxo);
        if selected_total >= total_needed {
            break;
        }
    }

    if selected_total < total_needed {
        return Err(format!(
            "Insufficient funds: have {} sompi ({:.8} KAS), need {} sompi",
            selected_total,
            selected_total as f64 / 1e8,
            total_needed,
        ));
    }

    let change_amount = selected_total - amount_sompi - fee;
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    let change_script = if final_change > 0 {
        let chg_idx = wallet.next_change_index;
        if chg_idx >= wallet.change_addresses.len() {
            return Err("No more change addresses. Re-import kpub.".into());
        }
        Some(crate::address::address_to_script_pubkey(
            &wallet.change_addresses[chg_idx],
        )?)
    } else {
        None
    };

    let mut outputs = vec![(amount_sompi, dest_script)];
    if let Some(chg_script) = change_script {
        outputs.push((final_change, chg_script));
    }

    let kspt_hex = serialize_kspt_multi(&selected, &outputs)?;

    web_sys::console::log_1(
        &format!(
            "[KasSee] KasFreeze TX: {} inputs, {} sompi to {} byte SPK, change {}, {} bytes",
            selected.len(),
            amount_sompi,
            spk_hex.len() / 2,
            final_change,
            kspt_hex.len() / 2
        )
        .into(),
    );

    Ok(kspt_hex)
}

/// Consolidate all UTXOs into one, sending to first receive address
pub async fn create_consolidate_kspt(
    wallet: &WalletData,
    fee: u64,
    ws_url: &str,
) -> Result<String, String> {
    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;

    if all_utxos.is_empty() {
        return Err("No UTXOs to consolidate".into());
    }
    if all_utxos.len() == 1 {
        return Err("Only 1 UTXO — nothing to consolidate".into());
    }

    // Sort largest first, cap at 5 inputs to stay within 1024-byte signed TX limit
    all_utxos.sort_by(|a, b| b.amount.cmp(&a.amount));
    let selected: Vec<_> = all_utxos.into_iter().take(5).collect();

    let total: u64 = selected.iter().map(|u| u.amount).sum();
    if total <= fee {
        return Err("Balance too low to cover fee".into());
    }

    let dest_addr = &wallet.receive_addresses[0];
    let dest_script = crate::address::address_to_script_pubkey(dest_addr)?;
    let send_amount = total - fee;

    let outputs = vec![(send_amount, dest_script)];
    let kspt_hex = serialize_kspt_multi(&selected, &outputs)?;

    web_sys::console::log_1(
        &format!(
            "[KasSee] Consolidate: {} inputs → {} sompi, fee {}, {} bytes",
            selected.len(),
            send_amount,
            fee,
            kspt_hex.len() / 2
        )
        .into(),
    );

    Ok(kspt_hex)
}

/// Create unsigned KSPT with specific UTXO indices
pub async fn create_send_kspt_selected(
    wallet: &WalletData,
    dest_address: &str,
    amount_sompi: u64,
    fee: u64,
    utxo_indices: &[usize],
    ws_url: &str,
) -> Result<String, String> {
    let dest_script = crate::address::address_to_script_pubkey(dest_address)?;

    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;
    // Sort to match the JS-side order (cachedUtxos.sort by amount desc,
    // then tx_id asc + index asc as tiebreakers for determinism).
    all_utxos.sort_by(|a, b| {
        b.amount
            .cmp(&a.amount)
            .then_with(|| a.tx_id.cmp(&b.tx_id))
            .then_with(|| a.index.cmp(&b.index))
    });

    let mut selected = Vec::new();
    for &idx in utxo_indices {
        if idx >= all_utxos.len() {
            return Err(format!(
                "UTXO index {} out of range (have {})",
                idx,
                all_utxos.len()
            ));
        }
        selected.push(all_utxos[idx].clone());
    }

    let selected_total: u64 = selected.iter().map(|u| u.amount).sum();
    let total_needed = amount_sompi + fee;

    if selected_total < total_needed {
        return Err(format!(
            "Selected UTXOs: {} sompi, need {} sompi",
            selected_total, total_needed,
        ));
    }

    let change_amount = selected_total - amount_sompi - fee;
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    let change_script = if final_change > 0 {
        let chg_idx = wallet.next_change_index;
        if chg_idx >= wallet.change_addresses.len() {
            return Err("No more change addresses".into());
        }
        Some(crate::address::address_to_script_pubkey(
            &wallet.change_addresses[chg_idx],
        )?)
    } else {
        None
    };

    let mut outputs = vec![(amount_sompi, dest_script)];
    if let Some(chg_script) = change_script {
        outputs.push((final_change, chg_script));
    }

    serialize_kspt_multi(&selected, &outputs)
}

/// Create compound unsigned KSPT: multiple recipients in one transaction
pub async fn create_compound_kspt(
    wallet: &WalletData,
    recipients_json: &str,
    fee: u64,
    ws_url: &str,
) -> Result<String, String> {
    // Parse recipients: [{"address":"kaspa:...","amount_sompi":"150000000"}, ...]
    let recipients: Vec<serde_json::Value> = serde_json::from_str(recipients_json)
        .map_err(|e| format!("Invalid recipients JSON: {}", e))?;

    if recipients.is_empty() {
        return Err("No recipients".into());
    }
    if recipients.len() > 10 {
        return Err("Maximum 10 recipients per transaction".into());
    }

    // Build output list
    let mut outputs: Vec<(u64, Vec<u8>)> = Vec::new();
    let mut total_send: u64 = 0;

    for (i, r) in recipients.iter().enumerate() {
        let addr = r["address"]
            .as_str()
            .ok_or_else(|| format!("Recipient {}: missing address", i + 1))?;
        let amount_sompi = r["amount_sompi"]
            .as_str()
            .ok_or_else(|| format!("Recipient {}: missing amount_sompi", i + 1))?
            .parse::<u64>()
            .map_err(|_| format!("Recipient {}: invalid amount_sompi", i + 1))?;

        if amount_sompi == 0 {
            return Err(format!("Recipient {}: amount must be > 0", i + 1));
        }
        if is_dust(amount_sompi) {
            return Err(format!(
                "Recipient {}: amount too small ({} sompi)",
                i + 1,
                amount_sompi
            ));
        }

        let script = crate::address::address_to_script_pubkey(addr)?;
        outputs.push((amount_sompi, script));
        total_send += amount_sompi;
    }

    // Fetch and select UTXOs
    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;
    all_utxos.sort_by(|a, b| b.amount.cmp(&a.amount));

    let total_needed = total_send + fee;
    let mut selected = Vec::new();
    let mut selected_total: u64 = 0;

    for utxo in all_utxos {
        selected_total += utxo.amount;
        selected.push(utxo);
        if selected_total >= total_needed {
            break;
        }
    }

    if selected_total < total_needed {
        return Err(format!(
            "Insufficient funds: have {} sompi ({:.8} KAS), need {} sompi",
            selected_total,
            selected_total as f64 / 1e8,
            total_needed,
        ));
    }

    // Change
    let change_amount = selected_total - total_send - fee;
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    if final_change > 0 {
        let chg_idx = wallet.next_change_index;
        if chg_idx >= wallet.change_addresses.len() {
            return Err("No more change addresses".into());
        }
        let chg_script =
            crate::address::address_to_script_pubkey(&wallet.change_addresses[chg_idx])?;
        outputs.push((final_change, chg_script));
    }

    let kspt_hex = serialize_kspt_multi(&selected, &outputs)?;

    web_sys::console::log_1(
        &format!(
            "[KasSee] Compound TX: {} inputs, {} recipients, total send {}, change {}, {} bytes",
            selected.len(),
            recipients.len(),
            total_send,
            final_change,
            kspt_hex.len() / 2
        )
        .into(),
    );

    Ok(kspt_hex)
}

/// Serialize unsigned KSPT binary with multiple outputs → hex string
fn serialize_kspt_multi(
    inputs: &[UtxoEntry],
    outputs: &[(u64, Vec<u8>)],
) -> Result<String, String> {
    let mut buf = Vec::with_capacity(512);

    // Header
    buf.extend_from_slice(b"KSPT");
    buf.push(0x01); // version
    buf.push(0x00); // flags (unsigned)

    // Global
    buf.extend_from_slice(&0u16.to_le_bytes()); // tx_version
    buf.push(inputs.len() as u8); // num_inputs
    buf.push(outputs.len() as u8); // num_outputs
    buf.extend_from_slice(&0u64.to_le_bytes()); // locktime
    buf.extend_from_slice(&[0u8; 20]); // subnetwork_id
    buf.extend_from_slice(&0u64.to_le_bytes()); // gas
    buf.extend_from_slice(&0u16.to_le_bytes()); // payload_len

    // Per input
    for utxo in inputs {
        let tx_id_bytes = hex::decode(&utxo.tx_id).map_err(|e| format!("Bad tx_id: {}", e))?;
        if tx_id_bytes.len() != 32 {
            return Err(format!("tx_id wrong length: {}", tx_id_bytes.len()));
        }
        buf.extend_from_slice(&tx_id_bytes); // prev_tx_id: 32
        buf.extend_from_slice(&utxo.index.to_le_bytes()); // prev_index: 4
        buf.extend_from_slice(&utxo.amount.to_le_bytes()); // amount: 8
        buf.extend_from_slice(&0u64.to_le_bytes()); // sequence: 8
        buf.push(1u8); // sig_op_count

        buf.extend_from_slice(&0u16.to_le_bytes()); // spk version
        buf.push(utxo.script_public_key.len() as u8); // spk len
        buf.extend_from_slice(&utxo.script_public_key); // spk
    }

    // Outputs
    for (amount, script) in outputs {
        buf.extend_from_slice(&amount.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes()); // spk version
        buf.push(script.len() as u8);
        buf.extend_from_slice(script);
    }

    Ok(hex::encode(&buf))
}

// ═══════════════════════════════════════════════════════════════════
// Multisig P2SH spend — create unsigned KSPT with redeem scripts
// ═══════════════════════════════════════════════════════════════════

/// Parse descriptor — supports both legacy and HD formats:
///
/// Legacy: "multi(M,pk1hex64,pk2hex64,...)" → x-only pubkeys directly
/// HD:     "multi_hd(M,pk1hex130,pk2hex130,...)" → compressed pubkey(33B) + chain_code(32B)
///         per cosigner, requiring derive_child at /0/addr_index to get x-only children.
///
/// Returns (M, Vec<[u8;32]>) — the lex-sorted x-only pubkeys for the redeem script.
fn parse_descriptor(desc: &str, addr_index: u32) -> Result<(u8, Vec<[u8; 32]>), String> {
    let desc = desc.trim();

    if desc.starts_with("multi_hd(") && desc.ends_with(')') {
        // ── HD format: multi_hd(M,<130hex>,<130hex>,...) ──
        let inner = &desc[9..desc.len() - 1]; // strip "multi_hd(" and ")"
        let parts: Vec<&str> = inner.split(',').collect();
        if parts.len() < 3 {
            return Err("Need at least M and 2 cosigner xpubs".into());
        }
        let m: u8 = parts[0]
            .trim()
            .parse()
            .map_err(|_| "Invalid M value in descriptor".to_string())?;

        let mut pubkeys = Vec::new();
        for xpub_hex in &parts[1..] {
            let xpub_hex = xpub_hex.trim();
            if xpub_hex.len() != 130 {
                return Err(format!(
                    "Cosigner xpub must be 130 hex chars (33B pubkey + 32B chain code), got {}",
                    xpub_hex.len()
                ));
            }
            let xpub_bytes =
                hex::decode(xpub_hex).map_err(|e| format!("Invalid xpub hex: {}", e))?;
            // First 33 bytes = compressed pubkey, next 32 = chain code
            let pubkey = k256::PublicKey::from_sec1_bytes(&xpub_bytes[..33])
                .map_err(|e| format!("Invalid compressed pubkey: {}", e))?;
            let mut chain_code = [0u8; 32];
            chain_code.copy_from_slice(&xpub_bytes[33..65]);

            // Derive child at /0/addr_index (matches KasSigner firmware path)
            let parent = crate::bip32::ExtPubKey {
                key: pubkey,
                chain_code,
                depth: 3, // account level
            };
            let receive_chain = parent.derive_child(0)?;
            let addr_child = receive_chain.derive_child(addr_index)?;

            // Extract x-only (32 bytes, strip 0x02/0x03 prefix)
            let compressed = addr_child.key.to_encoded_point(true);
            let compressed_bytes = compressed.as_bytes(); // 33 bytes
            let mut xonly = [0u8; 32];
            xonly.copy_from_slice(&compressed_bytes[1..33]);
            pubkeys.push(xonly);
        }

        if m == 0 || m as usize > pubkeys.len() {
            return Err(format!("Invalid M={} for N={}", m, pubkeys.len()));
        }
        pubkeys.sort();
        Ok((m, pubkeys))
    } else if desc.starts_with("multi(") && desc.ends_with(')') {
        // ── Legacy format: multi(M,pk1hex64,pk2hex64,...) ──
        let inner = &desc[6..desc.len() - 1];
        let parts: Vec<&str> = inner.split(',').collect();
        if parts.len() < 3 {
            return Err("Need at least M and 2 pubkeys".into());
        }
        let m: u8 = parts[0]
            .trim()
            .parse()
            .map_err(|_| "Invalid M value in descriptor".to_string())?;

        let mut pubkeys = Vec::new();
        for pk_hex in &parts[1..] {
            let pk_hex = pk_hex.trim();
            if pk_hex.len() != 64 {
                return Err(format!("Pubkey must be 64 hex chars, got {}", pk_hex.len()));
            }
            let pk_bytes = hex::decode(pk_hex).map_err(|e| format!("Invalid pubkey hex: {}", e))?;
            let mut pk = [0u8; 32];
            pk.copy_from_slice(&pk_bytes);
            pubkeys.push(pk);
        }

        if m == 0 || m as usize > pubkeys.len() {
            return Err(format!("Invalid M={} for N={}", m, pubkeys.len()));
        }
        pubkeys.sort();
        Ok((m, pubkeys))
    } else {
        Err("Descriptor must be multi(M,...) or multi_hd(M,...)".into())
    }
}

/// Build redeem script: OP_M OP_DATA_32 <pk1> ... OP_N OP_CHECKMULTISIG
fn build_redeem_script(m: u8, pubkeys: &[[u8; 32]]) -> Vec<u8> {
    let n = pubkeys.len() as u8;
    let mut script = Vec::with_capacity(1 + (n as usize) * 33 + 1 + 1);

    script.push(0x50 + m); // OP_M (OP_1=0x51, OP_2=0x52, etc.)
    for pk in pubkeys {
        script.push(0x20); // OP_DATA_32
        script.extend_from_slice(pk);
    }
    script.push(0x50 + n); // OP_N
    script.push(0xAE); // OP_CHECKMULTISIG

    script
}

/// Create unsigned multisig KSPT: fetch UTXOs for P2SH address, build TX with redeem scripts
#[allow(clippy::too_many_arguments)]
pub async fn create_multisig_kspt(
    descriptor: &str,
    source_address: &str,
    dest_address: &str,
    amount_sompi: u64,
    fee: u64,
    change_address: &str,
    ws_url: &str,
    addr_index: u32,
) -> Result<String, String> {
    // For HD descriptors, auto-discover the addr_index by trying indices
    // 0..99 and matching the derived P2SH address against source_address.
    // This saves the user from manually entering an index number.
    // For legacy multi(...) descriptors, addr_index is ignored (always 0).
    let final_index = if descriptor.trim().starts_with("multi_hd(") {
        let mut found: Option<u32> = None;
        for try_idx in 0..100u32 {
            let (m, pks) = parse_descriptor(descriptor, try_idx)?;
            let script = build_redeem_script(m, &pks);
            let script_hash = blake2b_hash(&script);
            let derived_addr = crate::address::encode_p2sh_address(&script_hash, "kaspa");
            if derived_addr == source_address {
                found = Some(try_idx);
                break;
            }
        }
        match found {
            Some(idx) => idx,
            None => {
                return Err(format!(
                    "Could not find address index (tried 0..99) that matches source address {}",
                    source_address
                ))
            }
        }
    } else {
        addr_index // legacy: use as-is (typically 0)
    };

    let (m, pubkeys) = parse_descriptor(descriptor, final_index)?;
    let redeem_script = build_redeem_script(m, &pubkeys);

    let dest_script = crate::address::address_to_script_pubkey(dest_address)?;

    // Fetch UTXOs for the P2SH address
    let mut utxos = crate::rpc::fetch_utxos_for_address(ws_url, source_address).await?;
    if utxos.is_empty() {
        return Err("No UTXOs found for multisig address".into());
    }

    utxos.sort_by(|a, b| b.amount.cmp(&a.amount));

    let total_needed = amount_sompi + fee;
    let mut selected = Vec::new();
    let mut selected_total: u64 = 0;

    for utxo in utxos {
        selected_total += utxo.amount;
        selected.push(utxo);
        if selected_total >= total_needed {
            break;
        }
    }

    if selected_total < total_needed {
        return Err(format!(
            "Insufficient funds in multisig: have {} sompi, need {}",
            selected_total, total_needed
        ));
    }

    if selected.len() > 3 {
        return Err(format!(
            "Multisig P2SH limited to 3 inputs (selected {}). Node rejects 4+ inputs. Consolidate UTXOs in batches of 3.",
            selected.len()
        ));
    }

    let change_amount = selected_total - amount_sompi - fee;
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    // Build outputs
    let mut outputs: Vec<(u64, Vec<u8>)> = vec![(amount_sompi, dest_script)];
    if final_change > 0 {
        // Change goes back to the same multisig address
        let change_script = crate::address::address_to_script_pubkey(change_address)?;
        outputs.push((final_change, change_script));
    }

    // Serialize KSPT with redeem scripts (flag 0x02)
    // sig_op_count = N (total pubkeys), not M (threshold) — Kaspa's
    // OP_CHECKMULTISIG checks all N pubkeys against the M signatures.
    let kspt_hex =
        serialize_kspt_multisig(&selected, &outputs, &redeem_script, pubkeys.len() as u8)?;

    web_sys::console::log_1(
        &format!(
            "[KasSee] Multisig TX: {} inputs, {}-of-{}, send {}, change {}, {} bytes",
            selected.len(),
            m,
            pubkeys.len(),
            amount_sompi,
            final_change,
            kspt_hex.len() / 2
        )
        .into(),
    );

    Ok(kspt_hex)
}

/// Serialize unsigned KSPT with redeem scripts for P2SH multisig inputs
fn serialize_kspt_multisig(
    inputs: &[crate::rpc::UtxoEntry],
    outputs: &[(u64, Vec<u8>)],
    redeem_script: &[u8],
    sig_op_count: u8,
) -> Result<String, String> {
    let mut buf = Vec::with_capacity(512);

    // Header
    buf.extend_from_slice(b"KSPT");
    buf.push(0x01); // version
    buf.push(0x02); // flags: bit 1 = has redeem scripts

    // Global
    buf.extend_from_slice(&0u16.to_le_bytes()); // tx_version
    buf.push(inputs.len() as u8);
    buf.push(outputs.len() as u8);
    buf.extend_from_slice(&0u64.to_le_bytes()); // locktime
    buf.extend_from_slice(&[0u8; 20]); // subnetwork_id
    buf.extend_from_slice(&0u64.to_le_bytes()); // gas
    buf.extend_from_slice(&0u16.to_le_bytes()); // payload_len

    // Per input
    for utxo in inputs {
        let tx_id_bytes = hex::decode(&utxo.tx_id).map_err(|e| format!("Bad tx_id: {}", e))?;
        if tx_id_bytes.len() != 32 {
            return Err(format!("tx_id wrong length: {}", tx_id_bytes.len()));
        }
        buf.extend_from_slice(&tx_id_bytes);
        buf.extend_from_slice(&utxo.index.to_le_bytes());
        buf.extend_from_slice(&utxo.amount.to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes()); // sequence
        buf.push(sig_op_count); // sig_op_count = M (threshold)

        buf.extend_from_slice(&0u16.to_le_bytes()); // spk version
        buf.push(utxo.script_public_key.len() as u8);
        buf.extend_from_slice(&utxo.script_public_key);

        // Redeem script for this input
        buf.push(redeem_script.len() as u8);
        buf.extend_from_slice(redeem_script);
    }

    // Outputs
    for (amount, script) in outputs {
        buf.extend_from_slice(&amount.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.push(script.len() as u8);
        buf.extend_from_slice(script);
    }

    Ok(hex::encode(&buf))
}

// ═══════════════════════════════════════════════════════════════════
// Single-sig PSKB creation — standard PSKT wire format for P2PK
// ═══════════════════════════════════════════════════════════════════
//
// Same input/output semantics as the KSPT single-sig constructors
// (create_send_kspt, create_consolidate_kspt, etc.) but emits an
// UNSIGNED PSKB (Kaspa-standard partially-signed bundle).
//
// Wire envelope: `PSKB` magic + hex-ASCII of a UTF-8 JSON array
// wrapping one PSKT object. KasSigner's `std_pskt::parse_pskt`
// already consumes this (camera_loop.rs routes PSKB magic to the
// PSKT parser, signing.rs handles P2PK inputs via the existing
// PSKT path). No firmware changes needed.
//
// The UI routes PSKB output through the existing PSKT review screen
// — same flow as multisig PSKB: Review → Relay (standard PSKB for
// any wallet, or compact KSPT v2 for KasSigner) → Finalize.
//
// Why siblings and not parameters on the KSPT functions: the KSPT
// path is mainnet-verified. Duplication is cheap; silent KSPT
// breakage loses funds.

/// Maximum number of standard inputs supported by the paired KasSigner
/// firmware and its bounded transaction representation.
pub const MAX_STANDARD_INPUTS: usize = 8;

/// Create unsigned single-sig PSKB: fetch UTXOs, select coins,
/// build PSKB JSON, return wire hex.
pub async fn create_send_pskb(
    wallet: &WalletData,
    dest_address: &str,
    amount_sompi: u64,
    fee: u64,
    ws_url: &str,
) -> Result<String, String> {
    let dest_script = crate::address::address_to_script_pubkey(dest_address)?;

    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;
    all_utxos.sort_by(|a, b| b.amount.cmp(&a.amount));

    let total_needed = amount_sompi + fee;
    let mut selected = Vec::new();
    let mut selected_total: u64 = 0;

    for utxo in all_utxos {
        selected_total += utxo.amount;
        selected.push(utxo);
        if selected_total >= total_needed {
            break;
        }
    }

    if selected_total < total_needed {
        return Err(format!(
            "Insufficient funds: have {} sompi ({:.8} KAS), need {} sompi",
            selected_total,
            selected_total as f64 / 1e8,
            total_needed,
        ));
    }

    let change_amount = selected_total - amount_sompi - fee;

    if amount_sompi > 0 && is_dust(amount_sompi) {
        return Err(format!(
            "Amount too small: {:.8} KAS. Minimum ~0.1 KAS.",
            amount_sompi as f64 / 1e8
        ));
    }

    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    let change_script = if final_change > 0 {
        let chg_idx = wallet.next_change_index;
        if chg_idx >= wallet.change_addresses.len() {
            return Err("No more change addresses. Re-import kpub.".into());
        }
        Some(crate::address::address_to_script_pubkey(
            &wallet.change_addresses[chg_idx],
        )?)
    } else {
        None
    };

    let mut outputs = vec![(amount_sompi, dest_script)];
    if let Some(chg_script) = change_script {
        outputs.push((final_change, chg_script));
    }

    let pskb_hex = serialize_pskb_single_sig(&selected, &outputs)?;

    web_sys::console::log_1(
        &format!(
            "[KasSee] PSKB TX: {} inputs, send {}, change {}, wire hex {} chars",
            selected.len(),
            amount_sompi,
            final_change,
            pskb_hex.len()
        )
        .into(),
    );

    Ok(pskb_hex)
}

/// Consolidate all UTXOs into one via PSKB format.
pub async fn create_consolidate_pskb(
    wallet: &WalletData,
    fee: u64,
    ws_url: &str,
) -> Result<String, String> {
    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;

    if all_utxos.is_empty() {
        return Err("No UTXOs to consolidate".into());
    }
    if all_utxos.len() == 1 {
        return Err("Only 1 UTXO — nothing to consolidate".into());
    }

    all_utxos.sort_by(|a, b| b.amount.cmp(&a.amount));
    let selected: Vec<_> = all_utxos.into_iter().take(MAX_STANDARD_INPUTS).collect();

    let total: u64 = selected.iter().map(|u| u.amount).sum();
    if total <= fee {
        return Err("Balance too low to cover fee".into());
    }

    let dest_addr = &wallet.receive_addresses[0];
    let dest_script = crate::address::address_to_script_pubkey(dest_addr)?;
    let send_amount = total - fee;

    let outputs = vec![(send_amount, dest_script)];
    let pskb_hex = serialize_pskb_single_sig(&selected, &outputs)?;

    web_sys::console::log_1(
        &format!(
            "[KasSee] Consolidate PSKB: {} inputs -> {} sompi, fee {}, wire hex {} chars",
            selected.len(),
            send_amount,
            fee,
            pskb_hex.len()
        )
        .into(),
    );

    Ok(pskb_hex)
}

/// Create unsigned PSKB with specific UTXO indices.
pub async fn create_send_pskb_selected(
    wallet: &WalletData,
    dest_address: &str,
    amount_sompi: u64,
    fee: u64,
    utxo_indices: &[usize],
    ws_url: &str,
) -> Result<String, String> {
    let dest_script = crate::address::address_to_script_pubkey(dest_address)?;

    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;
    // Sort to match the JS-side order (cachedUtxos.sort by amount desc,
    // then tx_id asc + index asc as tiebreakers for determinism).
    all_utxos.sort_by(|a, b| {
        b.amount
            .cmp(&a.amount)
            .then_with(|| a.tx_id.cmp(&b.tx_id))
            .then_with(|| a.index.cmp(&b.index))
    });

    let mut selected = Vec::new();
    for &idx in utxo_indices {
        if idx >= all_utxos.len() {
            return Err(format!(
                "UTXO index {} out of range (have {})",
                idx,
                all_utxos.len()
            ));
        }
        selected.push(all_utxos[idx].clone());
    }

    let selected_total: u64 = selected.iter().map(|u| u.amount).sum();
    let total_needed = amount_sompi + fee;

    if selected_total < total_needed {
        return Err(format!(
            "Selected UTXOs: {} sompi, need {} sompi",
            selected_total, total_needed,
        ));
    }

    let change_amount = selected_total - amount_sompi - fee;
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    let change_script = if final_change > 0 {
        let chg_idx = wallet.next_change_index;
        if chg_idx >= wallet.change_addresses.len() {
            return Err("No more change addresses".into());
        }
        Some(crate::address::address_to_script_pubkey(
            &wallet.change_addresses[chg_idx],
        )?)
    } else {
        None
    };

    let mut outputs = vec![(amount_sompi, dest_script)];
    if let Some(chg_script) = change_script {
        outputs.push((final_change, chg_script));
    }

    serialize_pskb_single_sig(&selected, &outputs)
}

/// Create unsigned PSKB with explicit UTXO data (no re-fetch needed).
/// Used when JS has cached UTXOs that may not match a fresh node query.
/// Fee and mass follow the pinned rusty-kaspa standard transaction generator:
/// minimum relay pricing applies to compute mass, the selected fee rate applies
/// to full mass, dust change is absorbed, and standard mass is enforced.
pub async fn create_send_pskb_with_utxos(
    wallet: &WalletData,
    transaction_mode: &str,
    recipients: Vec<ExplicitRecipient>,
    exact_fee_sompi: u64,
    fee_rate_sompi_per_gram: f64,
    send_max: bool,
    change_outputs: Vec<ExplicitChangeOutput>,
    selected: Vec<crate::rpc::UtxoEntry>,
) -> Result<String, String> {
    if recipients.is_empty() || recipients.len() > 4 {
        return Err("A transaction requires one to four recipients".into());
    }
    if transaction_mode == "decoy" && recipients.len() != 1 {
        return Err("Decoy Transaction supports exactly one recipient".into());
    }
    let recipient_scripts = recipients.iter()
        .map(|recipient| crate::address::address_to_script_pubkey(&recipient.address))
        .collect::<Result<Vec<_>, _>>()?;
    let recipient_total = recipients.iter().try_fold(0u64, |total, recipient| {
        total.checked_add(recipient.amount_sompi)
            .ok_or_else(|| "Recipient total overflow".to_string())
    })?;
    let primary_amount = recipients[0].amount_sompi;

    if selected.is_empty() {
        return Err("No UTXOs provided".into());
    }
    validate_input_derivations(wallet, &selected)?;

    validate_transaction_mode_change_count(transaction_mode, change_outputs.len())?;
    if transaction_mode == "decoy"
        && change_outputs
            .iter()
            .filter(|output| output.amount_sompi == primary_amount)
            .count()
            != 1
    {
        return Err("Decoy Transaction requires one change output matching the recipient amount".into());
    }

    let (explicit_change_total, explicit_change_scripts) =
        validate_explicit_change_outputs(wallet, &change_outputs)?;

    if send_max && !change_outputs.is_empty() {
        return Err("Send Max cannot contain change outputs".into());
    }

    let fallback_change_script = wallet
        .change_addresses
        .get(wallet.next_change_index)
        .map(|address| crate::address::address_to_script_pubkey(address))
        .transpose()?;
    let plan = if change_outputs.is_empty() {
        if recipients.len() != 1 {
            return Err("Multiple destinations require an explicit change plan".into());
        }
        standard_send_plan(
            &selected,
            primary_amount,
            recipient_scripts[0].len(),
            fallback_change_script
                .as_ref()
                .map(Vec::len)
                .unwrap_or(recipient_scripts[0].len()),
            fee_rate_sompi_per_gram,
            exact_fee_sompi,
            send_max,
        )?
    } else {
        if recipients.iter().any(|recipient| recipient.amount_sompi == 0 || is_dust(recipient.amount_sompi)) {
            return Err("Every destination amount must be above the dust limit".into());
        }
        let selected_total = selected.iter().try_fold(0u64, |total, utxo| {
            total
                .checked_add(utxo.amount)
                .ok_or_else(|| "Selected UTXO total overflow".to_string())
        })?;
        let total_outputs = recipient_total
            .checked_add(explicit_change_total)
            .ok_or_else(|| "Transaction output total overflow".to_string())?;
        let actual_fee = selected_total
            .checked_sub(total_outputs)
            .ok_or_else(|| "Change amounts exceed the selected input total".to_string())?;
        let mut script_lengths = Vec::with_capacity(recipient_scripts.len() + explicit_change_scripts.len());
        script_lengths.extend(recipient_scripts.iter().map(Vec::len));
        script_lengths.extend(explicit_change_scripts.iter().map(Vec::len));
        let compute_mass = standard_compute_mass(selected.len(), &script_lengths)?;
        let inputs: Vec<(u64, u64)> = selected.iter().map(|utxo| (utxo.amount, 1)).collect();
        let mut storage_outputs = Vec::with_capacity(recipients.len() + change_outputs.len());
        storage_outputs.extend(recipients.iter().map(|recipient| (recipient.amount_sompi, 1)));
        storage_outputs.extend(change_outputs.iter().map(|output| (output.amount_sompi, 1)));
        let mass = compute_mass.max(storage_mass_estimate(&inputs, &storage_outputs));
        if mass > MAX_STANDARD_MASS {
            return Err(format!(
                "Transaction mass {} exceeds the standard limit {}",
                mass, MAX_STANDARD_MASS
            ));
        }
        let minimum_fee = minimum_relay_fee(compute_mass);
        if exact_fee_sompi > 0 {
            if actual_fee != exact_fee_sompi {
                return Err("Change amounts do not preserve the exact custom fee".into());
            }
            if actual_fee < minimum_fee {
                return Err(format!(
                    "Custom fee is below the minimum relay fee of {} sompi",
                    minimum_fee
                ));
            }
        } else {
            let required_fee = fee_for_mass(compute_mass, mass, fee_rate_sompi_per_gram)?;
            if actual_fee < required_fee {
                return Err(format!(
                    "The selected fee requires at least {} sompi for these outputs",
                    required_fee
                ));
            }
        }
        StandardSendPlan {
            amount: recipient_total,
            fee: actual_fee,
            change: explicit_change_total,
            mass,
        }
    };
    let _verified_mass = plan.mass;
    let _verified_fee = plan.fee;

    let mut outputs: Vec<(u64, Vec<u8>)> = recipients
        .iter()
        .zip(recipient_scripts)
        .map(|(recipient, script)| (recipient.amount_sompi, script))
        .collect();
    if change_outputs.is_empty() {
        if plan.change > 0 {
            outputs.push((
                plan.change,
                fallback_change_script.ok_or_else(|| "No more change addresses".to_string())?,
            ));
        }
    } else {
        if explicit_change_total != plan.change {
            return Err(format!(
                "Change amounts total {} sompi, but the final transaction requires {} sompi",
                explicit_change_total, plan.change
            ));
        }
        for (output, script) in change_outputs.iter().zip(explicit_change_scripts) {
            outputs.push((output.amount_sompi, script));
        }
    }

    if transaction_mode != "standard" {
        securely_shuffle_outputs(&mut outputs)?;
    }
    serialize_pskb_single_sig_v4(&selected, &outputs, wallet)
}

fn validate_input_derivations(
    wallet: &WalletData,
    inputs: &[crate::rpc::UtxoEntry],
) -> Result<(), String> {
    for (position, input) in inputs.iter().enumerate() {
        let (chain, index) = match (&input.derivation_chain, input.derivation_index) {
            (Some(chain), Some(index)) => (chain.as_str(), index as usize),
            _ => {
                return Err(format!(
                    "Selected input {} has no wallet derivation path",
                    position + 1
                ));
            }
        };
        let addresses = match chain {
            "receive" => &wallet.receive_addresses,
            "change" => &wallet.change_addresses,
            _ => {
                return Err(format!(
                    "Selected input {} has an invalid derivation chain",
                    position + 1
                ));
            }
        };
        let address = addresses.get(index).ok_or_else(|| {
            format!(
                "Selected input {} derivation index {} is outside the synchronized wallet",
                position + 1,
                index
            )
        })?;
        let expected_script = crate::address::address_to_script_pubkey(address)?;
        if expected_script != input.script_public_key {
            return Err(format!(
                "Selected input {} derivation path does not match its script",
                position + 1
            ));
        }
    }
    Ok(())
}

/// Create compound unsigned PSKB: multiple recipients in one transaction.
pub async fn create_compound_pskb(
    wallet: &WalletData,
    recipients_json: &str,
    fee: u64,
    ws_url: &str,
) -> Result<String, String> {
    let recipients: Vec<serde_json::Value> = serde_json::from_str(recipients_json)
        .map_err(|e| format!("Invalid recipients JSON: {}", e))?;

    if recipients.is_empty() {
        return Err("No recipients".into());
    }
    if recipients.len() > 10 {
        return Err("Maximum 10 recipients per transaction".into());
    }

    let mut outputs: Vec<(u64, Vec<u8>)> = Vec::new();
    let mut total_send: u64 = 0;

    for (i, r) in recipients.iter().enumerate() {
        let addr = r["address"]
            .as_str()
            .ok_or_else(|| format!("Recipient {}: missing address", i + 1))?;
        let amount_sompi = r["amount_sompi"]
            .as_str()
            .ok_or_else(|| format!("Recipient {}: missing amount_sompi", i + 1))?
            .parse::<u64>()
            .map_err(|_| format!("Recipient {}: invalid amount_sompi", i + 1))?;

        if amount_sompi == 0 {
            return Err(format!("Recipient {}: amount must be > 0", i + 1));
        }
        if is_dust(amount_sompi) {
            return Err(format!(
                "Recipient {}: amount too small ({} sompi)",
                i + 1,
                amount_sompi
            ));
        }

        let script = crate::address::address_to_script_pubkey(addr)?;
        outputs.push((amount_sompi, script));
        total_send += amount_sompi;
    }

    let mut all_utxos = crate::rpc::fetch_all_utxos(ws_url, wallet).await?;
    all_utxos.sort_by(|a, b| b.amount.cmp(&a.amount));

    let total_needed = total_send + fee;
    let mut selected = Vec::new();
    let mut selected_total: u64 = 0;

    for utxo in all_utxos {
        selected_total += utxo.amount;
        selected.push(utxo);
        if selected_total >= total_needed {
            break;
        }
    }

    if selected_total < total_needed {
        return Err(format!(
            "Insufficient funds: have {} sompi ({:.8} KAS), need {} sompi",
            selected_total,
            selected_total as f64 / 1e8,
            total_needed,
        ));
    }

    let change_amount = selected_total - total_send - fee;
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    if final_change > 0 {
        let chg_idx = wallet.next_change_index;
        if chg_idx >= wallet.change_addresses.len() {
            return Err("No more change addresses".into());
        }
        let chg_script =
            crate::address::address_to_script_pubkey(&wallet.change_addresses[chg_idx])?;
        outputs.push((final_change, chg_script));
    }

    let pskb_hex = serialize_pskb_single_sig(&selected, &outputs)?;

    web_sys::console::log_1(
        &format!(
            "[KasSee] Compound PSKB: {} inputs, {} recipients, send {}, change {}, wire hex {} chars",
            selected.len(), recipients.len(), total_send, final_change, pskb_hex.len()
        ).into(),
    );

    Ok(pskb_hex)
}

/// Serialize an unsigned single-sig PSKB wire payload.
///
/// Builds the same JSON shape as `create_multisig_pskb` but for P2PK
/// inputs: `redeemScript: null`, `sigOpCount: 1`, empty `partialSigs`.
///
/// JSON field order matches `kaspa-wallet-pskt`'s BTreeMap emission
/// and the existing `create_multisig_pskb` — verified on the device's
/// strict-shape parser in `std_pskt.rs`.
fn serialize_pskb_single_sig(
    inputs: &[crate::rpc::UtxoEntry],
    outputs: &[(u64, Vec<u8>)],
) -> Result<String, String> {
    serialize_pskb_single_sig_inner(inputs, outputs, None)
}

/// Only the explicitly selected standard send opts into the coordinated v4 relay.
fn serialize_pskb_single_sig_v4(
    inputs: &[crate::rpc::UtxoEntry],
    outputs: &[(u64, Vec<u8>)],
    wallet: &WalletData,
) -> Result<String, String> {
    serialize_pskb_single_sig_inner(inputs, outputs, Some(wallet))
}

fn serialize_pskb_single_sig_inner(
    inputs: &[crate::rpc::UtxoEntry],
    outputs: &[(u64, Vec<u8>)],
    v4_wallet: Option<&WalletData>,
) -> Result<String, String> {
    if inputs.len() > MAX_STANDARD_INPUTS {
        return Err(format!(
            "Maximum {} UTXOs per transaction; selected {}",
            MAX_STANDARD_INPUTS,
            inputs.len()
        ));
    }

    let tx_version: u16 = 0;
    let num_in = inputs.len() as u16;
    let num_out = outputs.len() as u16;

    let mut inputs_json = Vec::<serde_json::Value>::with_capacity(inputs.len());
    for utxo in inputs {
        let spk_hex = format!("0000{}", hex::encode(&utxo.script_public_key));

        let utxo_entry = serde_json::json!({
            "amount": utxo.amount,
            "scriptPublicKey": spk_hex,
            "blockDaaScore": utxo.block_daa_score,
            "isCoinbase": false
        });

        let outpoint = serde_json::json!({
            "transactionId": utxo.tx_id,
            "index": utxo.index
        });

        let input = serde_json::json!({
            "utxoEntry": utxo_entry,
            "previousOutpoint": outpoint,
            "sequence": 0u64,
            "minTime": serde_json::Value::Null,
            "partialSigs": {},
            "sighashType": 1u8,
            "redeemScript": serde_json::Value::Null,
            "sigOpCount": 1u8,
            "bip32Derivations": {},
            "finalScriptSig": serde_json::Value::Null,
            "proprietaries": derivation_proprietaries(utxo)
        });
        inputs_json.push(input);
    }

    let mut outputs_json = Vec::<serde_json::Value>::with_capacity(outputs.len());
    for (amount, script) in outputs {
        let spk_hex = format!("0000{}", hex::encode(script));
        let mut proprietaries = serde_json::json!({});
        if let Some(wallet) = v4_wallet {
            if let Some(index) = wallet.change_addresses.iter().position(|address| {
                    crate::address::address_to_script_pubkey(address)
                        .as_ref().is_ok_and(|candidate| candidate == script)
                }) {
                if index > 511 {
                    return Err("Change derivation index exceeds M5 v4 range".into());
                }
                proprietaries = serde_json::json!({
                    "kasSignerDerivation": { "chain": "change", "index": index }
                });
            }
        }
        let output = serde_json::json!({
            "amount": amount,
            "scriptPublicKey": spk_hex,
            "redeemScript": serde_json::Value::Null,
            "bip32Derivations": {},
            "proprietaries": proprietaries
        });
        outputs_json.push(output);
    }

    let global = serde_json::json!({
        "version": 0u8,
        "txVersion": tx_version,
        "fallbackLockTime": serde_json::Value::Null,
        "inputsModifiable": false,
        "outputsModifiable": false,
        "inputCount": num_in,
        "outputCount": num_out,
        "xpubs": {},
        "id": serde_json::Value::Null,
        "proprietaries": if v4_wallet.is_some() {
            serde_json::json!({ "kasSignerKSPTV4": true })
        } else {
            serde_json::json!({})
        }
    });

    let pskt = serde_json::json!({
        "global": global,
        "inputs": inputs_json,
        "outputs": outputs_json
    });

    let pskb_body = serde_json::Value::Array(vec![pskt]);
    let json_bytes =
        serde_json::to_vec(&pskb_body).map_err(|e| format!("serialize PSKB JSON: {}", e))?;

    let mut wire: Vec<u8> = Vec::with_capacity(4 + json_bytes.len() * 2);
    wire.extend_from_slice(b"PSKB");
    wire.extend_from_slice(hex::encode(&json_bytes).as_bytes());
    let wire_hex = hex::encode(&wire);

    Ok(wire_hex)
}

/// Preserve the watch-only path resolution in the canonical PSKB. The compact
/// KSPT relay intentionally does not emit this yet; current M5 firmware rejects
/// unknown trailers. A later coordinated firmware update can transport it.
fn derivation_proprietaries(utxo: &crate::rpc::UtxoEntry) -> serde_json::Value {
    match (&utxo.derivation_chain, utxo.derivation_index) {
        (Some(chain), Some(index)) => serde_json::json!({
            "kasSignerDerivation": {
                "chain": chain,
                "index": index
            }
        }),
        _ => serde_json::json!({}),
    }
}

/// Output descriptor for PSKB with optional covenant binding.
pub struct PskbOutput {
    pub amount: u64,
    pub script: Vec<u8>,
    pub covenant: Option<(u16, [u8; 32])>, // (authorizing_input, covenant_id)
}

/// Serialize a single-sig PSKB with covenant binding support (KIP-20).
///
/// Same as serialize_pskb_single_sig but outputs carry covenant data.
/// TX version is set to 1 (required for covenant sighash coverage).
pub fn serialize_pskb_with_covenants(
    inputs: &[crate::rpc::UtxoEntry],
    outputs: &[PskbOutput],
) -> Result<String, String> {
    let tx_version: u16 = 1; // Covenant binding on outputs requires version >= 1
    let num_in = inputs.len() as u16;
    let num_out = outputs.len() as u16;

    let mut inputs_json = Vec::<serde_json::Value>::with_capacity(inputs.len());
    for utxo in inputs {
        let spk_hex = format!("0000{}", hex::encode(&utxo.script_public_key));
        let input = serde_json::json!({
            "utxoEntry": {
                "amount": utxo.amount,
                "scriptPublicKey": spk_hex,
                "blockDaaScore": utxo.block_daa_score,
                "isCoinbase": false
            },
            "previousOutpoint": {
                "transactionId": utxo.tx_id,
                "index": utxo.index
            },
            "sequence": 0u64,
            "minTime": serde_json::Value::Null,
            "partialSigs": {},
            "sighashType": 1u8,
            "redeemScript": serde_json::Value::Null,
            "sigOpCount": 1u8,
            "bip32Derivations": {},
            "finalScriptSig": serde_json::Value::Null,
            "proprietaries": {}
        });
        inputs_json.push(input);
    }

    let mut outputs_json = Vec::<serde_json::Value>::with_capacity(outputs.len());
    for out in outputs {
        let spk_hex = format!("0000{}", hex::encode(&out.script));
        let cov_binding = match &out.covenant {
            None => serde_json::Value::Null,
            Some((auth_input, cov_id)) => serde_json::json!({
                "authorizingInput": *auth_input,
                "covenantId": hex::encode(cov_id)
            }),
        };
        let output = serde_json::json!({
            "amount": out.amount,
            "scriptPublicKey": spk_hex,
            "covenantBinding": cov_binding,
            "redeemScript": serde_json::Value::Null,
            "bip32Derivations": {},
            "proprietaries": {}
        });
        outputs_json.push(output);
    }

    let pskt = serde_json::json!({
        "global": {
            "version": 0u8,
            "txVersion": tx_version,
            "fallbackLockTime": serde_json::Value::Null,
            "inputsModifiable": false,
            "outputsModifiable": false,
            "inputCount": num_in,
            "outputCount": num_out,
            "xpubs": {},
            "id": serde_json::Value::Null,
            "proprietaries": {}
        },
        "inputs": inputs_json,
        "outputs": outputs_json
    });

    let pskb_body = serde_json::Value::Array(vec![pskt]);
    let json_bytes =
        serde_json::to_vec(&pskb_body).map_err(|e| format!("serialize covenant PSKB: {}", e))?;

    let mut wire: Vec<u8> = Vec::with_capacity(4 + json_bytes.len() * 2);
    wire.extend_from_slice(b"PSKB");
    wire.extend_from_slice(hex::encode(&json_bytes).as_bytes());
    Ok(hex::encode(&wire))
}

/// Same as `serialize_pskb_with_covenants` but includes a TX payload in the PSKB global.
pub fn serialize_pskb_with_covenants_and_payload(
    inputs: &[crate::rpc::UtxoEntry],
    outputs: &[PskbOutput],
    payload: &[u8],
) -> Result<String, String> {
    // tx_version must be 1 when any output carries a covenant binding (the node
    // requires version >= 1 for covenant outputs and covers the binding in the
    // sighash); otherwise 0 for a plain payload TX.
    let tx_version: u16 = if outputs.iter().any(|o| o.covenant.is_some()) {
        1
    } else {
        0
    };
    let num_in = inputs.len() as u16;
    let num_out = outputs.len() as u16;

    let mut inputs_json = Vec::<serde_json::Value>::with_capacity(inputs.len());
    for utxo in inputs {
        let spk_hex = format!("0000{}", hex::encode(&utxo.script_public_key));
        inputs_json.push(serde_json::json!({
            "utxoEntry": { "amount": utxo.amount, "scriptPublicKey": spk_hex, "blockDaaScore": utxo.block_daa_score, "isCoinbase": false },
            "previousOutpoint": { "transactionId": utxo.tx_id, "index": utxo.index },
            "sequence": 0u64, "minTime": serde_json::Value::Null, "partialSigs": {}, "sighashType": 1u8,
            "redeemScript": serde_json::Value::Null, "sigOpCount": 1u8, "bip32Derivations": {},
            "finalScriptSig": serde_json::Value::Null, "proprietaries": {}
        }));
    }

    let mut outputs_json = Vec::<serde_json::Value>::with_capacity(outputs.len());
    for out in outputs {
        let spk_hex = format!("0000{}", hex::encode(&out.script));
        let cov_binding = match &out.covenant {
            None => serde_json::Value::Null,
            Some((auth_input, cov_id)) => {
                serde_json::json!({ "authorizingInput": *auth_input, "covenantId": hex::encode(cov_id) })
            }
        };
        outputs_json.push(serde_json::json!({
            "amount": out.amount, "scriptPublicKey": spk_hex, "covenantBinding": cov_binding,
            "redeemScript": serde_json::Value::Null, "bip32Derivations": {}, "proprietaries": {}
        }));
    }

    let pskt = serde_json::json!({
        "global": {
            "version": 0u8, "txVersion": tx_version, "txPayload": hex::encode(payload),
            "fallbackLockTime": serde_json::Value::Null, "inputsModifiable": false, "outputsModifiable": false,
            "inputCount": num_in, "outputCount": num_out, "xpubs": {}, "id": serde_json::Value::Null, "proprietaries": {}
        },
        "inputs": inputs_json,
        "outputs": outputs_json
    });

    let pskb_body = serde_json::Value::Array(vec![pskt]);
    let json_bytes = serde_json::to_vec(&pskb_body)
        .map_err(|e| format!("serialize covenant PSKB w/payload: {}", e))?;

    let mut wire: Vec<u8> = Vec::with_capacity(4 + json_bytes.len() * 2);
    wire.extend_from_slice(b"PSKB");
    wire.extend_from_slice(hex::encode(&json_bytes).as_bytes());
    Ok(hex::encode(&wire))
}

// ═══════════════════════════════════════════════════════════════════
// Multisig PSKB creation (Path 2 — sibling of create_multisig_kspt)
// ═══════════════════════════════════════════════════════════════════
//
// Same input/output semantics as create_multisig_kspt (descriptor,
// source, dest, amount, fee, change, UTXO selection) but emits an
// UNSIGNED PSKB (Kaspa-standard partially-signed bundle) instead of
// KSPT v1 binary.
//
// Wire envelope: `50534b42` (ASCII "PSKB") + hex-ASCII of a UTF-8
// JSON array wrapping one PSKT object. Matches the format that
// `finalize_to_kspt_hex`, `relay_pskb_as_kspt_v2_hex`, and
// `merge_signed_kspt_v2_into_pskb` all already consume.
//
// Why a sibling and not a mode parameter: the mainnet-verified KSPT
// construction path produced the ceremonies that fund the multisig
// address we're about to spend from. Same risk asymmetry as the
// relay sibling — duplication is fixable later; silent KSPT
// breakage loses funds.
//
// The "unsigned" PSKB has `partialSigs: {}` on every input. Device
// receives it, signs, returns a PSKB with partialSigs populated (or
// a KSPT v2 via the compact relay path, which gets merged back).

#[allow(clippy::too_many_arguments)]
pub async fn create_multisig_pskb(
    descriptor: &str,
    source_address: &str,
    dest_address: &str,
    amount_sompi: u64,
    fee: u64,
    change_address: &str,
    ws_url: &str,
    addr_index: u32,
) -> Result<String, String> {
    // ── HD address-index auto-discovery (identical to create_multisig_kspt) ──
    let final_index = if descriptor.trim().starts_with("multi_hd(") {
        let mut found: Option<u32> = None;
        for try_idx in 0..100u32 {
            let (m, pks) = parse_descriptor(descriptor, try_idx)?;
            let script = build_redeem_script(m, &pks);
            let script_hash = blake2b_hash(&script);
            let derived_addr = crate::address::encode_p2sh_address(&script_hash, "kaspa");
            if derived_addr == source_address {
                found = Some(try_idx);
                break;
            }
        }
        match found {
            Some(idx) => idx,
            None => {
                return Err(format!(
                    "Could not find address index (tried 0..99) that matches source address {}",
                    source_address
                ))
            }
        }
    } else {
        addr_index
    };

    let (m, pubkeys) = parse_descriptor(descriptor, final_index)?;
    let redeem_script = build_redeem_script(m, &pubkeys);
    let redeem_script_hex = hex::encode(&redeem_script);

    let dest_script = crate::address::address_to_script_pubkey(dest_address)?;

    // ── UTXO selection (identical to create_multisig_kspt) ──
    let mut utxos = crate::rpc::fetch_utxos_for_address(ws_url, source_address).await?;
    if utxos.is_empty() {
        return Err("No UTXOs found for multisig address".into());
    }
    utxos.sort_by(|a, b| b.amount.cmp(&a.amount));

    let total_needed = amount_sompi + fee;
    let mut selected = Vec::new();
    let mut selected_total: u64 = 0;
    for utxo in utxos {
        selected_total += utxo.amount;
        selected.push(utxo);
        if selected_total >= total_needed {
            break;
        }
    }
    if selected_total < total_needed {
        return Err(format!(
            "Insufficient funds in multisig: have {} sompi, need {}",
            selected_total, total_needed
        ));
    }

    if selected.len() > 3 {
        return Err(format!(
            "Multisig P2SH limited to 3 inputs (selected {}). Node rejects 4+ inputs. Consolidate UTXOs in batches of 3.",
            selected.len()
        ));
    }

    let change_amount = selected_total - amount_sompi - fee;
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    // ── Build outputs ──
    let mut outputs: Vec<(u64, Vec<u8>)> = vec![(amount_sompi, dest_script)];
    if final_change > 0 {
        let change_script = crate::address::address_to_script_pubkey(change_address)?;
        outputs.push((final_change, change_script));
    }

    // ── Build the PSKT JSON structure ──
    //
    // Field order matches the wire-format documentation at the top of
    // pskt.rs lines 32-82. Using serde_json::Value with explicit
    // insertion order (serde_json preserves insertion order by default
    // when the `preserve_order` feature is enabled — this crate's
    // Cargo.toml should already carry that since byte-compatibility
    // was verified on 20 Apr 2026).
    //
    // tx_version = 0 (matches the KSPT path and Kaspa consensus default).
    // sigOpCount = M per KIP §5 (corrected from N after PR #39 feedback).
    // sighashType = 1 (SIGHASH_ALL, Kaspa's only supported mode).

    let tx_version: u16 = 0;
    let num_in = selected.len() as u16;
    let num_out = outputs.len() as u16;

    // Inputs JSON
    let mut inputs_json = Vec::<serde_json::Value>::with_capacity(selected.len());
    for utxo in &selected {
        // scriptPublicKey: "<4 hex BE version><script hex>". For P2SH the
        // script_public_key bytes are just the script; version is 0 for
        // all standard outputs on mainnet today.
        let spk_hex = format!("0000{}", hex::encode(&utxo.script_public_key));

        let utxo_entry = serde_json::json!({
            "amount": utxo.amount,
            "scriptPublicKey": spk_hex,
            "blockDaaScore": utxo.block_daa_score,
            "isCoinbase": false
        });

        let outpoint = serde_json::json!({
            "transactionId": utxo.tx_id,
            "index": utxo.index
        });

        let input = serde_json::json!({
            "utxoEntry": utxo_entry,
            "previousOutpoint": outpoint,
            "sequence": 0u64,
            "minTime": serde_json::Value::Null,
            "partialSigs": {},
            "sighashType": 1u8,
            "redeemScript": redeem_script_hex,
            // sigOpCount = N (total pubkeys), not M (threshold).
            // Under the KIP, M ≤ sigOpCount ≤ N is the valid range; M
            // is the tight value under the KIP's lex-sort + ordered-
            // emission conventions and N is a safe upper bound.
            // Consensus today still evaluates P2SH-multisig sigops at
            // N — Michael Sutton noted on X 21 Apr 2026 that exact-M
            // only becomes possible with upcoming Silverscript. Until
            // then, emitting M here causes "sig op count exceeds
            // passed limit" rejections because the node counts N and
            // our PSKB declared M.
            //
            // The existing KSPT path (kspt::create_multisig_kspt
            // line 565) already emits N for the same reason. Keeping
            // the two emitters consistent prevents an asymmetric
            // mainnet failure mode.
            "sigOpCount": pubkeys.len() as u8,
            "bip32Derivations": {},
            "finalScriptSig": serde_json::Value::Null,
            "proprietaries": {}
        });
        inputs_json.push(input);
    }

    // Outputs JSON
    let mut outputs_json = Vec::<serde_json::Value>::with_capacity(outputs.len());
    for (amount, script) in &outputs {
        let spk_hex = format!("0000{}", hex::encode(script));
        let output = serde_json::json!({
            "amount": amount,
            "scriptPublicKey": spk_hex,
            "redeemScript": serde_json::Value::Null,
            "bip32Derivations": {},
            "proprietaries": {}
        });
        outputs_json.push(output);
    }

    // Global
    let global = serde_json::json!({
        "version": 0u8,
        "txVersion": tx_version,
        "fallbackLockTime": serde_json::Value::Null,
        "inputsModifiable": false,
        "outputsModifiable": false,
        "inputCount": num_in,
        "outputCount": num_out,
        "xpubs": {},
        "id": serde_json::Value::Null,
        "proprietaries": {}
    });

    // Full PSKT object
    let pskt = serde_json::json!({
        "global": global,
        "inputs": inputs_json,
        "outputs": outputs_json
    });

    // PSKB = single-element array wrapping the PSKT object
    let pskb_body = serde_json::Value::Array(vec![pskt]);
    let json_bytes =
        serde_json::to_vec(&pskb_body).map_err(|e| format!("serialize PSKB JSON: {}", e))?;

    // Wire envelope: raw magic bytes "PSKB" + hex-ASCII of JSON,
    // whole thing then hex-encoded. Matches relay_pskb_as_kspt_v2_hex
    // inverse path at pskt.rs ~line 585 where it does
    // `hex::decode(&wire[4..])` to get back at the JSON.
    let mut wire: Vec<u8> = Vec::with_capacity(4 + json_bytes.len() * 2);
    wire.extend_from_slice(b"PSKB");
    wire.extend_from_slice(hex::encode(&json_bytes).as_bytes());
    let wire_hex = hex::encode(&wire);

    web_sys::console::log_1(
        &format!(
            "[KasSee] Multisig PSKB: {} inputs, {}-of-{}, send {}, change {}, wire hex {} chars",
            selected.len(),
            m,
            pubkeys.len(),
            amount_sompi,
            final_change,
            wire_hex.len()
        )
        .into(),
    );

    Ok(wire_hex)
}

/// Create unsigned multisig PSKB with specific UTXO indices.
/// Same as `create_multisig_pskb` but uses explicit UTXO indices
/// instead of greedy auto-selection.
#[allow(clippy::too_many_arguments)]
pub async fn create_multisig_pskb_selected(
    descriptor: &str,
    source_address: &str,
    dest_address: &str,
    amount_sompi: u64,
    fee: u64,
    change_address: &str,
    ws_url: &str,
    addr_index: u32,
    utxo_indices: &[usize],
) -> Result<String, String> {
    let final_index = if descriptor.trim().starts_with("multi_hd(") {
        let mut found: Option<u32> = None;
        for try_idx in 0..100u32 {
            let (m, pks) = parse_descriptor(descriptor, try_idx)?;
            let script = build_redeem_script(m, &pks);
            let script_hash = blake2b_hash(&script);
            let derived_addr = crate::address::encode_p2sh_address(&script_hash, "kaspa");
            if derived_addr == source_address {
                found = Some(try_idx);
                break;
            }
        }
        match found {
            Some(idx) => idx,
            None => {
                return Err(format!(
                    "Could not find address index (tried 0..99) that matches source address {}",
                    source_address
                ))
            }
        }
    } else {
        addr_index
    };

    let (m, pubkeys) = parse_descriptor(descriptor, final_index)?;
    let redeem_script = build_redeem_script(m, &pubkeys);
    let redeem_script_hex = hex::encode(&redeem_script);

    let dest_script = crate::address::address_to_script_pubkey(dest_address)?;

    let mut utxos = crate::rpc::fetch_utxos_for_address(ws_url, source_address).await?;
    if utxos.is_empty() {
        return Err("No UTXOs found for multisig address".into());
    }
    utxos.sort_by(|a, b| {
        b.amount
            .cmp(&a.amount)
            .then_with(|| a.tx_id.cmp(&b.tx_id))
            .then_with(|| a.index.cmp(&b.index))
    });

    let mut selected = Vec::new();
    for &idx in utxo_indices {
        if idx >= utxos.len() {
            return Err(format!(
                "UTXO index {} out of range (have {})",
                idx,
                utxos.len()
            ));
        }
        selected.push(utxos[idx].clone());
    }

    let selected_total: u64 = selected.iter().map(|u| u.amount).sum();
    let total_needed = amount_sompi + fee;
    if selected_total < total_needed {
        return Err(format!(
            "Selected UTXOs: {} sompi, need {} sompi",
            selected_total, total_needed
        ));
    }

    if selected.len() > 3 {
        return Err(format!(
            "Multisig P2SH limited to 3 inputs (selected {}). Node rejects 4+ inputs. Consolidate UTXOs in batches of 3.",
            selected.len()
        ));
    }

    let change_amount = selected_total - amount_sompi - fee;
    let final_change = if change_amount > 0 && is_dust(change_amount) {
        0u64
    } else {
        change_amount
    };

    let mut outputs: Vec<(u64, Vec<u8>)> = vec![(amount_sompi, dest_script)];
    if final_change > 0 {
        let change_script = crate::address::address_to_script_pubkey(change_address)?;
        outputs.push((final_change, change_script));
    }

    let tx_version: u16 = 0;
    let num_in = selected.len() as u16;
    let num_out = outputs.len() as u16;

    let mut inputs_json = Vec::<serde_json::Value>::with_capacity(selected.len());
    for utxo in &selected {
        let spk_hex = format!("0000{}", hex::encode(&utxo.script_public_key));
        let input = serde_json::json!({
            "utxoEntry": {
                "amount": utxo.amount,
                "scriptPublicKey": spk_hex,
                "blockDaaScore": utxo.block_daa_score,
                "isCoinbase": false
            },
            "previousOutpoint": {
                "transactionId": utxo.tx_id,
                "index": utxo.index
            },
            "sequence": 0u64,
            "minTime": serde_json::Value::Null,
            "partialSigs": {},
            "sighashType": 1u8,
            "redeemScript": redeem_script_hex,
            "sigOpCount": pubkeys.len() as u8,
            "bip32Derivations": {},
            "finalScriptSig": serde_json::Value::Null,
            "proprietaries": {}
        });
        inputs_json.push(input);
    }

    let mut outputs_json = Vec::<serde_json::Value>::with_capacity(outputs.len());
    for (amount, script) in &outputs {
        let spk_hex = format!("0000{}", hex::encode(script));
        outputs_json.push(serde_json::json!({
            "amount": amount,
            "scriptPublicKey": spk_hex,
            "redeemScript": serde_json::Value::Null,
            "bip32Derivations": {},
            "proprietaries": {}
        }));
    }

    let pskt = serde_json::json!({
        "global": {
            "version": 0u8,
            "txVersion": tx_version,
            "fallbackLockTime": serde_json::Value::Null,
            "inputsModifiable": false,
            "outputsModifiable": false,
            "inputCount": num_in,
            "outputCount": num_out,
            "xpubs": {},
            "id": serde_json::Value::Null,
            "proprietaries": {}
        },
        "inputs": inputs_json,
        "outputs": outputs_json
    });

    let pskb_body = serde_json::Value::Array(vec![pskt]);
    let json_bytes =
        serde_json::to_vec(&pskb_body).map_err(|e| format!("serialize PSKB JSON: {}", e))?;

    let mut wire: Vec<u8> = Vec::with_capacity(4 + json_bytes.len() * 2);
    wire.extend_from_slice(b"PSKB");
    wire.extend_from_slice(hex::encode(&json_bytes).as_bytes());
    let wire_hex = hex::encode(&wire);

    web_sys::console::log_1(
        &format!(
            "[KasSee] Multisig PSKB (selected): {} inputs, {}-of-{}, send {}, change {}, wire hex {} chars",
            selected.len(), m, pubkeys.len(), amount_sompi, final_change, wire_hex.len()
        ).into(),
    );

    Ok(wire_hex)
}

// ═══════════════════════════════════════════════════════════════════════
// Covenant script builders (KIP-10 introspection opcodes)
// ═══════════════════════════════════════════════════════════════════════

// Kept: retained for future use; not currently wired.
#[allow(dead_code)]
mod covenant_ops {
    pub const OP_0: u8 = 0x00;
    pub const OP_IF: u8 = 0x63;
    pub const OP_ELSE: u8 = 0x67;
    pub const OP_ENDIF: u8 = 0x68;
    pub const OP_VERIFY: u8 = 0x69;
    pub const OP_DROP: u8 = 0x75;
    pub const OP_EQUAL: u8 = 0x87;
    pub const OP_EQUALVERIFY: u8 = 0x88;
    pub const OP_SUB: u8 = 0x94;
    pub const OP_MUL: u8 = 0x95;
    pub const OP_DIV: u8 = 0x96;
    pub const OP_LESSTHANOREQUAL: u8 = 0xa1;
    pub const OP_GREATERTHANOREQUAL: u8 = 0xa2;
    pub const OP_CHECKSIG: u8 = 0xac;
    pub const OP_CHECKSIGVERIFY: u8 = 0xad;
    pub const OP_CHECKLOCKTIMEVERIFY: u8 = 0xb0;
    pub const OP_CHECKSEQUENCEVERIFY: u8 = 0xb1;
    pub const OP_TX_INPUT_COUNT: u8 = 0xb3;
    pub const OP_TX_OUTPUT_COUNT: u8 = 0xb4;
    pub const OP_TX_LOCKTIME: u8 = 0xb5;
    pub const OP_TX_INPUT_INDEX: u8 = 0xb9;
    pub const OP_TX_INPUT_AMOUNT: u8 = 0xbe;
    pub const OP_TX_INPUT_SPK: u8 = 0xbf;
    pub const OP_TX_OUTPUT_AMOUNT: u8 = 0xc2;
    pub const OP_TX_OUTPUT_SPK: u8 = 0xc3;

    // Stack-reorder + substr opcodes used by the rollup-state covenant.
    // PICK/ROLL copy/move a depth-N item to the top; the *_SUBSTR ops slice a
    // byte range out of the tx payload / an input's full (version-prefixed) SPK.
    pub const OP_PICK: u8 = 0x79; // pop loc -> copy dstack[depth-loc] to top
    pub const OP_ROLL: u8 = 0x7a; // pop loc -> move dstack[depth-loc] to top
    pub const OP_TX_PAYLOAD_SUBSTR: u8 = 0xb8; // pop [start,end] -> push payload[start..end]
    pub const OP_TX_INPUT_SPK_SUBSTR: u8 = 0xc6; // pop [idx,start,end] -> push utxo[idx].spk[start..end]
    pub const OP_BLAKE2B: u8 = 0xaa;
    pub const OP_SHA256: u8 = 0xa8;
    pub const OP_CHECKSIGFROMSTACK: u8 = 0xd7;
    pub const OP_DUP: u8 = 0x76;
    pub const OP_SWAP: u8 = 0x7c;
    pub const OP_NOT: u8 = 0x91;
    pub const OP_1: u8 = 0x51;

    // String/bitwise opcodes (unlocked with covenants_enabled)
    pub const OP_CAT: u8 = 0x7e; // pop x2, pop x1, push x1||x2
    pub const OP_SUBSTR: u8 = 0x7f; // pop len, pop offset, pop str → push substr
    pub const OP_SIZE: u8 = 0x82; // push size of top item (without removing)
    pub const OP_AND: u8 = 0x84; // bitwise AND
    pub const OP_OR_BITWISE: u8 = 0x85; // bitwise OR
    pub const OP_XOR: u8 = 0x86; // bitwise XOR
    pub const OP_MOD: u8 = 0x97; // modulo
    pub const OP_ADD: u8 = 0x93; // addition
    pub const OP_NUMEQUAL: u8 = 0x9c; // numeric equality (a b -> a==b)
    pub const OP_NUMEQUALVERIFY: u8 = 0x9d; // numeric equality + VERIFY (a b -> fail unless a==b)

    // KIP-20 covenant identity opcodes (Toccata)
    pub const OP_AUTH_OUTPUT_COUNT: u8 = 0xcb; // pop input_idx → push #outputs it authorizes
    pub const OP_AUTH_OUTPUT_IDX: u8 = 0xcc; // pop (input_idx, k) → push k-th authorized output index
    pub const OP_INPUT_COVENANT_ID: u8 = 0xcf; // pop input_idx → push that input's covenant_id
    pub const OP_COV_INPUT_COUNT: u8 = 0xd0; // pop covenant_id → push count of inputs with that id
    pub const OP_COV_OUTPUT_COUNT: u8 = 0xd2; // pop covenant_id → push count of outputs with that id
    pub const OP_COV_OUTPUT_IDX: u8 = 0xd3; // pop (covenant_id, k) → push k-th output index with that id
    pub const OP_OUTPUT_COVENANT_ID: u8 = 0xd5; // pop output_idx → push that output's covenant_id
    pub const OP_OUTPUT_AUTHORIZING_INPUT: u8 = 0xd6; // pop output_idx → push which input authorizes it

    // ZK precompile (Toccata)
    pub const OP_ZK_PRECOMPILE: u8 = 0xa6; // Groth16/R0Succinct verifier
}

fn push_int(script: &mut Vec<u8>, value: u64) {
    if value == 0 {
        script.push(covenant_ops::OP_0);
    } else if value <= 16 {
        script.push(0x50 + value as u8);
    } else {
        let mut v = value;
        let mut bytes = Vec::new();
        while v > 0 {
            bytes.push((v & 0xff) as u8);
            v >>= 8;
        }
        if bytes.last().is_some_and(|b| b & 0x80 != 0) {
            bytes.push(0x00);
        }
        script.push(bytes.len() as u8);
        script.extend_from_slice(&bytes);
    }
}

fn push_pubkey(script: &mut Vec<u8>, pubkey: &[u8; 32]) {
    script.push(0x20);
    script.extend_from_slice(pubkey);
}

/// Extract the CLTV (OP_CHECKLOCKTIMEVERIFY) locktime value from a
/// redeem script, if present. Scans for 0xB0 and reads the preceding push.
/// Returns 0 if no CLTV found.
pub fn extract_cltv_locktime(redeem: &[u8]) -> u64 {
    let mut i = 0;
    let mut last_push_val: u64 = 0;
    while i < redeem.len() {
        let op = redeem[i];
        if op == 0xB0 {
            return last_push_val;
        }
        if op == 0x00 {
            last_push_val = 0;
            i += 1;
        } else if (0x51..=0x60).contains(&op) {
            last_push_val = (op - 0x50) as u64;
            i += 1;
        } else if (0x01..=0x4b).contains(&op) {
            let len = op as usize;
            if i + 1 + len <= redeem.len() {
                last_push_val = read_script_int(&redeem[i + 1..i + 1 + len]);
            }
            i += 1 + len;
        } else if op == 0x4c {
            if i + 1 < redeem.len() {
                let len = redeem[i + 1] as usize;
                if i + 2 + len <= redeem.len() {
                    last_push_val = read_script_int(&redeem[i + 2..i + 2 + len]);
                }
                i += 2 + len;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    0
}

/// Extract the CSV (OP_CHECKSEQUENCEVERIFY) minimum sequence value from a
/// redeem script, if present. Scans for 0xB1 and reads the preceding push.
/// Returns 0 if no CSV found.
pub fn extract_csv_sequence(redeem: &[u8]) -> u64 {
    // Find OP_CHECKSEQUENCEVERIFY (0xB1) and read the preceding push
    let mut i = 0;
    let mut last_push_val: u64 = 0;
    while i < redeem.len() {
        let op = redeem[i];
        if op == 0xB1 {
            // Found CSV — last_push_val has the sequence
            return last_push_val;
        }
        // Track push values
        if op == 0x00 {
            // OP_0
            last_push_val = 0;
            i += 1;
        } else if (0x51..=0x60).contains(&op) {
            // OP_1 through OP_16 (small integer opcodes)
            last_push_val = (op - 0x50) as u64;
            i += 1;
        } else if (0x01..=0x4b).contains(&op) {
            // Direct push: op bytes follow
            let len = op as usize;
            if i + 1 + len <= redeem.len() {
                let data = &redeem[i + 1..i + 1 + len];
                last_push_val = read_script_int(data);
            }
            i += 1 + len;
        } else if op == 0x4c {
            // OP_PUSHDATA1
            if i + 1 < redeem.len() {
                let len = redeem[i + 1] as usize;
                if i + 2 + len <= redeem.len() {
                    last_push_val = read_script_int(&redeem[i + 2..i + 2 + len]);
                }
                i += 2 + len;
            } else {
                i += 1;
            }
        } else {
            // Non-push op — don't reset, CSV might follow immediately
            i += 1;
        }
    }
    0
}

/// Read a little-endian script integer (unsigned, up to 8 bytes).
fn read_script_int(data: &[u8]) -> u64 {
    let mut val: u64 = 0;
    for (idx, &b) in data.iter().enumerate().take(8) {
        val |= (b as u64) << (idx * 8);
    }
    val
}

/// Push variable-length data onto the script (for SPK bytes etc).
fn push_data(script: &mut Vec<u8>, data: &[u8]) {
    if data.len() <= 75 {
        script.push(data.len() as u8);
    } else if data.len() <= 255 {
        script.push(0x4c); // OP_PUSHDATA1
        script.push(data.len() as u8);
    } else if data.len() <= 65535 {
        script.push(0x4d); // OP_PUSHDATA2
        script.push((data.len() & 0xff) as u8);
        script.push((data.len() >> 8) as u8);
    } else {
        script.push(0x4e); // OP_PUSHDATA4 (seals > 65535 bytes, e.g. RISC0 ~222KB)
        script.push((data.len() & 0xff) as u8);
        script.push(((data.len() >> 8) & 0xff) as u8);
        script.push(((data.len() >> 16) & 0xff) as u8);
        script.push(((data.len() >> 24) & 0xff) as u8);
    }
    script.extend_from_slice(data);
}

#[path = "kspt_covenant.rs"]
mod covenant_builders;
pub use covenant_builders::*;

#[path = "kspt_protected_vault.rs"]
mod protected_vault;
pub use protected_vault::*;

pub fn covenant_script_to_address(redeem_script: &[u8], prefix: &str) -> Result<String, String> {
    let script_hash = blake2b_hash(redeem_script);
    Ok(crate::address::encode_p2sh_address(&script_hash, prefix))
}

// ═══════════════════════════════════════════════════════════════════
// State Machine Covenant (Supply Chain / Traceability)
// ═══════════════════════════════════════════════════════════════════

#[path = "kspt_state_machine.rs"]
mod state_machine;
pub use state_machine::*;

// ═══════════════════════════════════════════════════════════════════
// Commit-Reveal Covenant (MEV Resistance / Fair Protocols)
// ═══════════════════════════════════════════════════════════════════

#[path = "kspt_commit_reveal.rs"]
mod commit_reveal;
pub use commit_reveal::*;

// ═══════════════════════════════════════════════════════════════════
// ZK Proof Covenant (Groth16 via OP_ZK_PRECOMPILE 0xa6)
// ═══════════════════════════════════════════════════════════════════

/// Compute the required sigOpCount for a ZK covenant spend.
///
/// Groth16 verification costs Gram(1000 * 140) = 14_000_000 script units.
/// Budget formula: budget = sigOpCount × 100_000 + 9_999
/// Required: budget >= groth16_cost + checksigverify_cost
///
/// CHECKSIGVERIFY costs 1 sigop via standard sigop counting.
/// OpZkPrecompile costs via consume_script_units (not sigop).
///
/// So sigOpCount must cover both:
///   sigOpCount × 100_000 + 9_999 >= 14_000_000
///   sigOpCount >= ceil((14_000_000 - 9_999) / 100_000) = 140
///
/// But we also consume 1 sigop for CHECKSIGVERIFY, which is part of
/// the sigop budget. Actually, sigOpCount is the declared count in the
/// UTXO entry — it's a field the transaction creator sets. The node
/// validates that the actual sigop consumption doesn't exceed
/// sigOpCount × SCRIPT_UNITS_PER_SIGOP_COUNT_UNIT.
///
/// Keeping it simple: 145 covers Groth16 (14M) + CHECKSIGVERIFY (~100K)
/// + BLAKE2B VK hash verification (~100K for 296 bytes) + margin.
/// Required sigOpCount for a Groth16-gated covenant spend on toc5/1.3.0.
///
/// Runtime cost is metered against budget = sigOpCount * 100_000 + 9_999:
///   - flat Groth16 tag cost:        Gram(140_000) = 14_000_000 script units
///   - per-VK-element (toc5):        (n_public_inputs + 1) * 250_000
///   - one CHECKSIG-family op:       100_000
///   - OP_BLAKE2B over the VK:       2 * vk_len  (~592 for a 296-byte VK)
///   - pushed bytes (1:1):           VK, proof, inputs, sig, redeem, vk_hash, tag
/// n_public_inputs must equal the circuit public-input count (VK gamma_abc len
/// is n+1). Includes a fixed safety margin, rounds up, capped at 255.
/// Script-unit budget for a Groth16-gated covenant spend with `n_public_inputs`
/// public inputs. Single source of truth shared by sigOpCount sizing and the
/// min-fee derivation below, so the two can never drift.
///
/// Costs mirror rusty-kaspa v2.0.0:
///   TAG        = Gram(140_000) base for the Groth16 OpZkPrecompile tag (tags.rs)
///   VK_ELEMENT = GROTH16_GAMMA_ABC_G1_ELEMENT_SCRIPT_UNITS (groth16/mod.rs), (n+1) elements
///   CHECKSIG   = one CHECKSIG-family op
///   BLAKE2B_VK = OP_BLAKE2B over the VK
///   PUSH_BYTES = pushed bytes (VK, proof, inputs, sig, redeem, vk_hash, tag), 1:1
///   SAFETY     = fixed margin
#[allow(clippy::doc_lazy_continuation)]
pub const fn zk_groth16_script_units(n_public_inputs: u64) -> u64 {
    const TAG: u64 = 14_000_000;
    const VK_ELEMENT: u64 = 250_000;
    const CHECKSIG: u64 = 100_000;
    const BLAKE2B_VK: u64 = 640;
    const PUSH_BYTES: u64 = 2_000;
    const SAFETY: u64 = 50_000;
    TAG + (n_public_inputs + 1) * VK_ELEMENT + CHECKSIG + BLAKE2B_VK + PUSH_BYTES + SAFETY
}

pub const fn zk_groth16_sig_op_count(n_public_inputs: u64) -> u8 {
    const FREE: u64 = 9_999;
    let needed = zk_groth16_script_units(n_public_inputs);
    let sigops = (needed - FREE).div_ceil(100_000);
    if sigops > 255 {
        255
    } else {
        sigops as u8
    }
}

/// Minimum relay fee (sompi) for a Groth16-gated covenant spend with
/// `n_public_inputs` public inputs, under the Toccata fee model in
/// rusty-kaspa v2.0.0.
///
/// fee_floor = compute_mass_grams * minimum_feerate, where
///   compute_mass_grams = script_units / SCRIPT_UNITS_PER_GRAM(=100) + size/spk margin
///   minimum_feerate    = DEFAULT_MINIMUM_RELAY_TRANSACTION_FEE(100_000 sompi/kg) / 1000
///                      = 100 sompi/gram
///
/// SIZE_MARGIN_GRAMS covers the size-based (size * mass_per_tx_byte) and
/// script_public_key compute-mass terms that are added on top of the script
/// cost by `calc_non_contextual_masses`, plus integer rounding. The ZK script
/// term dominates by ~100x, so a fixed grams margin is a safe overestimate.
// Kept: Groth16 minimum-fee helper, ZK infrastructure.
#[allow(dead_code)]
pub const fn zk_groth16_min_fee_sompi(n_public_inputs: u64) -> u64 {
    const SCRIPT_UNITS_PER_GRAM: u64 = 100; // v2.0.0 consensus/core mass/units.rs
    const MIN_FEERATE_SOMPI_PER_GRAM: u64 = 100; // DEFAULT_MINIMUM_RELAY_TRANSACTION_FEE / 1000
    const SIZE_MARGIN_GRAMS: u64 = 20_000;
    let script_grams = zk_groth16_script_units(n_public_inputs) / SCRIPT_UNITS_PER_GRAM;
    (script_grams + SIZE_MARGIN_GRAMS) * MIN_FEERATE_SOMPI_PER_GRAM
}

/// 1 public input (the product / sum / commitment). 147 on toc5.
pub const ZK_GROTH16_SIG_OP_COUNT: u8 = zk_groth16_sig_op_count(1);

// ═══════════════════════════════════════════════════════════════════
// Crowdfunding Covenant (ZK-gated sweep)
// ═══════════════════════════════════════════════════════════════════

#[path = "kspt_crowdfund.rs"]
mod crowdfund;
pub use crowdfund::*;

// ═══════════════════════════════════════════════════════════════════
// RISC0 Succinct Covenant (OP_ZK_PRECOMPILE 0xa6, tag 0x21)
// ═══════════════════════════════════════════════════════════════════

/// RISC0 tag byte.
pub const ZK_TAG_RISC0: u8 = 0x21;

/// RISC0 Succinct costs Gram(1000 * 250) = 25_000_000 script units.
/// sigOpCount >= ceil((25_000_000 - 9_999) / 100_000) = 250.
/// Add margin for CHECKSIGVERIFY + overhead = 255.
/// Note: u8 max is 255.
pub const ZK_RISC0_SIG_OP_COUNT: u8 = 255;

// ═══════════════════════════════════════════════════════════════════
// Merkle Whitelist Vault (OP_CAT + OP_BLAKE2B)
// ═══════════════════════════════════════════════════════════════════

#[path = "kspt_merkle.rs"]
mod merkle;
pub use merkle::*;

/// Build a P2PK script_public_key from a 32-byte "pubkey" (real or synthetic).
/// Format: OP_DATA_32 <32 bytes> OP_CHECKSIG = 34 bytes.
// Kept: general P2PK script-pubkey builder, reusable primitive.
#[allow(dead_code)]
pub fn p2pk_spk(pubkey: &[u8; 32]) -> Vec<u8> {
    let mut spk = Vec::with_capacity(34);
    spk.push(0x20); // OP_DATA_32
    spk.extend_from_slice(pubkey);
    spk.push(0xAC); // OP_CHECKSIG
    spk
}
// ================================================================
// Tagged Vault: covenant-ID-aware vault (KIP-20 PoC)
// ================================================================

#[path = "kspt_vault.rs"]
mod vault;
pub use vault::*;
#[path = "kspt_oracle.rs"]
mod oracle_mb;
pub use oracle_mb::*;

#[cfg(test)]
mod standard_send_tests {
    use super::*;

    fn utxo(amount: u64, index: u32) -> UtxoEntry {
        UtxoEntry {
            tx_id: format!("{:064x}", index + 1),
            index,
            amount,
            script_public_key: vec![0x20; 34],
            block_daa_score: 1,
            covenant_id: None,
            derivation_chain: None,
            derivation_index: None,
        }
    }

    fn derived_utxo(
        wallet: &WalletData,
        chain: &str,
        derivation_index: usize,
    ) -> UtxoEntry {
        let address = match chain {
            "receive" => &wallet.receive_addresses[derivation_index],
            "change" => &wallet.change_addresses[derivation_index],
            _ => unreachable!(),
        };
        UtxoEntry {
            tx_id: format!("{:064x}", derivation_index + 1),
            index: 0,
            amount: 500_000_000,
            script_public_key: crate::address::address_to_script_pubkey(address).unwrap(),
            block_daa_score: 1,
            covenant_id: None,
            derivation_chain: Some(chain.into()),
            derivation_index: Some(derivation_index as u32),
        }
    }

    fn wallet_with_change_count(count: usize) -> WalletData {
        WalletData {
            kpub: "test".into(),
            receive_addresses: vec![],
            change_addresses: (0..count)
                .map(|index| crate::address::encode_p2pk_address(&[index as u8 + 1; 32], "kaspa"))
                .collect(),
            next_receive_index: 0,
            next_change_index: 0,
        }
    }

    #[test]
    fn input_derivation_must_match_the_actual_script() {
        let mut wallet = wallet_with_change_count(3);
        wallet.receive_addresses = (0..3)
            .map(|index| {
                crate::address::encode_p2pk_address(&[index as u8 + 20; 32], "kaspa")
            })
            .collect();

        let receive = derived_utxo(&wallet, "receive", 2);
        let change = derived_utxo(&wallet, "change", 1);
        assert!(validate_input_derivations(&wallet, &[receive, change.clone()]).is_ok());

        let mut wrong_index = change.clone();
        wrong_index.derivation_index = Some(2);
        assert!(validate_input_derivations(&wallet, &[wrong_index])
            .unwrap_err()
            .contains("does not match its script"));

        let mut missing = change;
        missing.derivation_chain = None;
        assert!(validate_input_derivations(&wallet, &[missing])
            .unwrap_err()
            .contains("no wallet derivation path"));
    }

    #[test]
    fn explicit_standard_send_marks_only_change_outputs_for_v4() {
        let wallet = wallet_with_change_count(3);
        let selected = vec![derived_utxo(&wallet, "change", 2)];
        let destination = crate::address::address_to_script_pubkey(
            &crate::address::encode_p2pk_address(&[91; 32], "kaspa")
        ).unwrap();
        let change = crate::address::address_to_script_pubkey(
            &wallet.change_addresses[1]
        ).unwrap();
        let wire = serialize_pskb_single_sig_v4(
            &selected,
            &[(100_000_000, destination), (399_000_000, change)],
            &wallet,
        ).unwrap();
        let bytes = hex::decode(&wire).unwrap();
        let root: serde_json::Value =
            serde_json::from_slice(&hex::decode(&bytes[4..]).unwrap()).unwrap();
        let transaction = &root[0];
        assert_eq!(transaction["global"]["proprietaries"]["kasSignerKSPTV4"], true);
        assert_eq!(transaction["inputs"][0]["proprietaries"]
            ["kasSignerDerivation"]["index"], 2);
        assert!(transaction["outputs"][0]["proprietaries"]
            .as_object().unwrap().is_empty());
        assert_eq!(transaction["outputs"][1]["proprietaries"]
            ["kasSignerDerivation"]["index"], 1);
        let relay = crate::pskt::relay_pskb_as_kspt_v2_hex(&wire).unwrap();
        assert_eq!(&hex::decode(relay).unwrap()[..6], b"KSPT\x04\x00");
    }

    #[test]
    fn explicit_change_contract_accepts_one_through_four_owned_outputs() {
        let wallet = wallet_with_change_count(4);
        for count in 1..=4 {
            let outputs: Vec<_> = wallet.change_addresses[..count]
                .iter()
                .enumerate()
                .map(|(index, address)| ExplicitChangeOutput {
                    address: address.clone(),
                    amount_sompi: 1_000_000 + index as u64,
                })
                .collect();
            let (total, scripts) = validate_explicit_change_outputs(&wallet, &outputs).unwrap();
            assert_eq!(scripts.len(), count);
            assert_eq!(total, count as u64 * 1_000_000 + (0..count as u64).sum::<u64>());
        }
    }

    #[test]
    fn explicit_change_contract_rejects_duplicate_foreign_and_overflow() {
        let wallet = wallet_with_change_count(2);
        let duplicate = vec![
            ExplicitChangeOutput { address: wallet.change_addresses[0].clone(), amount_sompi: 1_000_000 },
            ExplicitChangeOutput { address: wallet.change_addresses[0].to_uppercase(), amount_sompi: 1_000_000 },
        ];
        assert!(validate_explicit_change_outputs(&wallet, &duplicate)
            .unwrap_err().contains("Duplicate"));

        let foreign = vec![ExplicitChangeOutput {
            address: crate::address::encode_p2pk_address(&[99; 32], "kaspa"),
            amount_sompi: 1_000_000,
        }];
        assert!(validate_explicit_change_outputs(&wallet, &foreign)
            .unwrap_err().contains("wallet change address"));

        let overflow = vec![
            ExplicitChangeOutput { address: wallet.change_addresses[0].clone(), amount_sompi: u64::MAX },
            ExplicitChangeOutput { address: wallet.change_addresses[1].clone(), amount_sompi: 1_000_000 },
        ];
        assert!(validate_explicit_change_outputs(&wallet, &overflow)
            .unwrap_err().contains("overflow"));
    }

    #[test]
    fn transaction_modes_enforce_their_change_output_counts() {
        assert!(validate_transaction_mode_change_count("standard", 0).is_ok());
        assert!(validate_transaction_mode_change_count("standard", 1).is_ok());
        assert!(validate_transaction_mode_change_count("standard", 2).is_err());
        assert!(validate_transaction_mode_change_count("privacyFocused", 2).is_ok());
        assert!(validate_transaction_mode_change_count("privacyFocused", 4).is_ok());
        assert!(validate_transaction_mode_change_count("privacyFocused", 1).is_err());
        assert!(validate_transaction_mode_change_count("decoy", 4).is_ok());
        assert!(validate_transaction_mode_change_count("decoy", 3).is_err());
    }

    #[test]
    fn decoy_plan_creates_one_matching_and_three_additional_change_outputs() {
        let wallet = wallet_with_change_count(4);
        let selected = vec![utxo(1_000_000_000, 0)];
        let outputs = wallet
            .change_addresses
            .iter()
            .map(|address| ExplicitChangeOutput {
                address: address.clone(),
                amount_sompi: 0,
            })
            .collect();
        let recipient_amount = 100_000_000;

        let plan = plan_explicit_change_fee(
            &wallet,
            "decoy",
            vec![ExplicitRecipient {
                address: crate::address::encode_p2pk_address(&[99; 32], "kaspa"),
                amount_sompi: recipient_amount,
            }],
            0,
            150.0,
            outputs,
            &selected,
        )
        .unwrap();

        assert_eq!(plan.amounts_sompi.len(), 4);
        assert_eq!(
            plan.amounts_sompi
                .iter()
                .filter(|amount| **amount == recipient_amount)
                .count(),
            1
        );
        assert!(plan.amounts_sompi.iter().all(|amount| !is_dust(*amount)));
        assert_eq!(
            recipient_amount + plan.amounts_sompi.iter().sum::<u64>() + plan.fee_sompi,
            1_000_000_000
        );
    }

    #[test]
    fn decoy_balanced_split_never_creates_a_second_matching_amount() {
        let recipient_amount = 100_000_000;
        let remainder = recipient_amount * 3;
        let split = split_decoy_remainder(
            remainder,
            recipient_amount,
            [100, 100, 100],
        )
        .unwrap();
        assert_eq!(split.iter().sum::<u64>(), remainder);
        assert!(split.iter().all(|amount| *amount != recipient_amount));
        assert!(split.iter().all(|amount| *amount >= MINIMUM_DECOY_CHANGE_SOMPI));
    }

    #[test]
    fn decoy_plan_preserves_manual_change_amounts_and_locked_match() {
        let wallet = wallet_with_change_count(4);
        let selected = vec![utxo(1_000_000_000, 0)];
        let outputs = wallet.change_addresses.iter().enumerate().map(|(index, address)| {
            ExplicitChangeOutput {
                address: address.clone(),
                amount_sompi: if index == 0 { 0 } else { 150_000_000 },
            }
        }).collect();
        let recipient_amount = 100_000_000;
        let plan = plan_explicit_change_fee(
            &wallet,
            "decoy",
            vec![ExplicitRecipient {
                address: crate::address::encode_p2pk_address(&[99; 32], "kaspa"),
                amount_sompi: recipient_amount,
            }],
            0,
            150.0,
            outputs,
            &selected,
        ).unwrap();
        assert_eq!(plan.amounts_sompi[0], recipient_amount);
        assert_eq!(plan.amounts_sompi[1], 150_000_000);
        assert_eq!(plan.amounts_sompi[2], 150_000_000);
        assert_eq!(plan.amounts_sompi.iter().filter(|amount| **amount == recipient_amount).count(), 1);
        assert_eq!(recipient_amount + plan.amounts_sompi.iter().sum::<u64>() + plan.fee_sompi, 1_000_000_000);
    }

    #[test]
    fn decoy_plan_rejects_insufficient_funds_and_extra_matching_amounts() {
        let wallet = wallet_with_change_count(4);
        let recipient_amount = 100_000_000;
        let recipient = ExplicitRecipient {
            address: crate::address::encode_p2pk_address(&[99; 32], "kaspa"),
            amount_sompi: recipient_amount,
        };
        let automatic_outputs = wallet.change_addresses.iter().map(|address| ExplicitChangeOutput {
            address: address.clone(),
            amount_sompi: 0,
        }).collect();
        assert!(plan_explicit_change_fee(
            &wallet, "decoy", vec![recipient.clone()], 0, 150.0,
            automatic_outputs, &[utxo(200_000_000, 0)],
        ).is_err());

        let manual_outputs = wallet.change_addresses.iter().enumerate().map(|(index, address)| {
            ExplicitChangeOutput {
                address: address.clone(),
                amount_sompi: if index == 1 { recipient_amount } else { 150_000_000 },
            }
        }).collect();
        assert!(plan_explicit_change_fee(
            &wallet, "decoy", vec![recipient], 0, 150.0,
            manual_outputs, &[utxo(1_000_000_000, 0)],
        ).unwrap_err().contains("Only one change output"));
    }

    #[test]
    fn decoy_builder_preserves_the_planned_outputs() {
        use std::future::Future;
        use std::task::{Context, Poll, Waker};

        let wallet = wallet_with_change_count(4);
        let selected = vec![derived_utxo(&wallet, "change", 0)];
        let recipient = ExplicitRecipient {
            address: crate::address::encode_p2pk_address(&[99; 32], "kaspa"),
            amount_sompi: 50_000_000,
        };
        let blank_outputs: Vec<_> = wallet.change_addresses.iter().map(|address| {
            ExplicitChangeOutput {
                address: address.clone(),
                amount_sompi: 0,
            }
        }).collect();
        let plan = plan_explicit_change_fee(
            &wallet, "decoy", vec![recipient.clone()], 0, 150.0,
            blank_outputs, &selected,
        ).unwrap();
        let planned_outputs: Vec<_> = wallet.change_addresses.iter()
            .zip(plan.amounts_sompi.iter())
            .map(|(address, amount)| ExplicitChangeOutput {
                address: address.clone(),
                amount_sompi: *amount,
            })
            .collect();
        let future = create_send_pskb_with_utxos(
            &wallet, "decoy", vec![recipient], 0, 150.0, false,
            planned_outputs, selected,
        );
        let mut future = std::pin::pin!(future);
        let mut context = Context::from_waker(Waker::noop());
        let wire = match Future::poll(future.as_mut(), &mut context) {
            Poll::Ready(result) => result.unwrap(),
            Poll::Pending => panic!("Decoy builder unexpectedly suspended"),
        };
        let bytes = hex::decode(&wire).unwrap();
        let root: serde_json::Value =
            serde_json::from_slice(&hex::decode(&bytes[4..]).unwrap()).unwrap();
        let outputs = root[0]["outputs"].as_array().unwrap();
        assert_eq!(outputs.len(), 5);
        let mut actual_amounts: Vec<_> = outputs.iter()
            .map(|output| output["amount"].as_u64().unwrap())
            .collect();
        let mut expected_amounts = plan.amounts_sompi;
        expected_amounts.push(50_000_000);
        actual_amounts.sort_unstable();
        expected_amounts.sort_unstable();
        assert_eq!(actual_amounts, expected_amounts);
    }

    #[test]
    fn explicit_change_fee_plan_converges_and_preserves_the_output_total() {
        let wallet = wallet_with_change_count(3);
        let selected = vec![utxo(500_000_000, 0)];
        let outputs: Vec<_> = wallet.change_addresses.iter().map(|address| {
            ExplicitChangeOutput {
                address: address.clone(),
                amount_sompi: 100_000_000,
            }
        }).collect();

        let plan = plan_explicit_change_fee(
            &wallet,
            "privacyFocused",
            vec![ExplicitRecipient {
                address: crate::address::encode_p2pk_address(&[99; 32], "kaspa"),
                amount_sompi: 100_000_000,
            }],
            0,
            150.0,
            outputs,
            &selected,
        ).unwrap();

        assert_eq!(plan.amounts_sompi.len(), 3);
        assert_eq!(plan.amounts_sompi[0], 100_000_000);
        assert_eq!(plan.amounts_sompi[1], 100_000_000);
        assert_eq!(plan.amounts_sompi.iter().sum::<u64>(), plan.available_change_sompi);
        assert_eq!(100_000_000 + plan.available_change_sompi + plan.fee_sompi, 500_000_000);
    }

    #[test]
    fn explicit_change_fee_plan_preserves_an_exact_custom_fee() {
        let wallet = wallet_with_change_count(2);
        let selected = vec![utxo(300_000_000, 0)];
        let outputs = wallet.change_addresses.iter().map(|address| ExplicitChangeOutput {
            address: address.clone(),
            amount_sompi: 50_000_000,
        }).collect();

        let plan = plan_explicit_change_fee(
            &wallet,
            "privacyFocused",
            vec![ExplicitRecipient {
                address: crate::address::encode_p2pk_address(&[99; 32], "kaspa"),
                amount_sompi: 100_000_000,
            }],
            500_000,
            0.0,
            outputs,
            &selected,
        ).unwrap();

        assert_eq!(plan.fee_sompi, 500_000);
        assert_eq!(plan.available_change_sompi, 199_500_000);
        assert_eq!(plan.amounts_sompi.iter().sum::<u64>(), 199_500_000);
    }

    #[test]
    fn standard_compute_mass_matches_pinned_rusty_kaspa_constants() {
        assert_eq!(standard_compute_mass(1, &[34]).unwrap(), 1_624);
        assert_eq!(standard_compute_mass(1, &[34, 34]).unwrap(), 2_036);
        assert_eq!(standard_compute_mass(2, &[34, 34]).unwrap(), 3_154);
    }

    #[test]
    fn minimum_relay_prices_compute_mass_at_one_hundred_sompi_per_gram() {
        assert_eq!(minimum_relay_fee(1_624), 162_400);
        assert_eq!(minimum_relay_fee(2_036), 203_600);
    }

    #[test]
    fn send_max_deducts_the_planned_fee_and_never_creates_change() {
        let selected = vec![utxo(100_000_000, 0)];
        let plan = standard_send_plan(&selected, 99_000_000, 34, 34, 100.0, 0, true).unwrap();

        assert_eq!(plan.amount + plan.fee, 100_000_000);
        assert_eq!(plan.change, 0);
        assert_eq!(plan.mass, 1_624);
        assert_eq!(plan.fee, 162_400);
    }

    #[test]
    fn each_fee_rate_changes_send_max_by_the_corresponding_fee() {
        let selected = vec![utxo(100_000_000, 0)];
        let low = standard_send_plan(&selected, 1, 34, 34, 100.0, 0, true).unwrap();
        let normal = standard_send_plan(&selected, 1, 34, 34, 150.0, 0, true).unwrap();
        let priority = standard_send_plan(&selected, 1, 34, 34, 250.0, 0, true).unwrap();

        assert!(low.fee < normal.fee);
        assert!(normal.fee < priority.fee);
        assert_eq!(low.amount + low.fee, 100_000_000);
        assert_eq!(normal.amount + normal.fee, 100_000_000);
        assert_eq!(priority.amount + priority.fee, 100_000_000);
    }

    #[test]
    fn exact_fee_is_preserved_when_change_is_not_dust() {
        let selected = vec![utxo(200_000_000, 0)];
        let plan = standard_send_plan(&selected, 100_000_000, 34, 34, 0.0, 500_000, false).unwrap();

        assert_eq!(plan.fee, 500_000);
        assert_eq!(plan.change, 99_500_000);
    }

    #[test]
    fn exact_fee_rejects_implicit_dust_absorption() {
        let selected = vec![utxo(100_500_100, 0)];
        let error =
            standard_send_plan(&selected, 100_000_000, 34, 34, 0.0, 500_000, false).unwrap_err();

        assert!(error.contains("exact custom fee"));
    }

    #[test]
    fn standard_mass_limit_is_enforced() {
        let selected: Vec<_> = (0..100).map(|index| utxo(100_000_000, index)).collect();
        let error = standard_send_plan(&selected, 1_000_000, 34, 34, 100.0, 0, false).unwrap_err();

        assert!(error.contains("standard limit"));
    }

    #[test]
    fn standard_compact_relay_boundaries_fit_the_coordinated_qr_limit() {
        let outputs = vec![(100_000_000, vec![0x20; 34])];
        for count in [6usize, 7, 8] {
            let selected: Vec<_> = (0..count)
                .map(|index| utxo(100_000_000, index as u32))
                .collect();
            let wire_hex = serialize_pskb_single_sig(&selected, &outputs).unwrap();
            let relay_hex = crate::pskt::relay_pskb_as_kspt_v2_hex(&wire_hex).unwrap();
            let relay_bytes = hex::decode(&relay_hex).unwrap();
            let frame_count = relay_bytes.len().div_ceil(crate::qr::MAX_FRAME_DATA);
            assert!(
                frame_count <= crate::qr::MAX_FRAMES,
                "{count}-input compact relay requires {frame_count} frames"
            );
        }

        let nine: Vec<_> = (0..9).map(|index| utxo(100_000_000, index)).collect();
        let error = serialize_pskb_single_sig(&nine, &outputs).unwrap_err();
        assert!(error.contains("Maximum 8 UTXOs"));
    }
}
