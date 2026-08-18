# Protected Vault V1 consensus contract

Status: experimental. Standard-send funding was exercised on mainnet before
tagged-genesis verification was complete. That path creates an untagged P2SH
UTXO and must not be used.

## Untagged funding incompatibility

The vault script requires `OP_AUTH_OUTPUT_COUNT == 1`. Under the pinned Kaspa
consensus implementation, a covenant binding created by an untagged input is a
genesis relation. Consensus validates the genesis covenant ID but deliberately
does not expose genesis relations through the script engine's authorization
context. Consequently, both the approved and pending branches see zero
authorized outputs and reject the spend. The consensus suite includes exact
untagged-input regressions for both branches. A valid future funding flow must
create the vault UTXO as a covenant-tagged genesis; an already untagged output
cannot be upgraded by spending it through this V1 redeem script.

This document specifies the minimum two-stage covenant that the iOS draft UI
is intended to represent. A direct relative lock on the long-lived vault UTXO
is not safe: its relative age eventually elapses while the vault sits funded.
V1 therefore starts the delay only after an unapproved destination is chosen.

## Fixed scope

- Kaspa mainnet semantics after covenant activation.
- One owner Schnorr key.
- One exact approved version-0 P2PK destination.
- One input and one full-balance output per covenant transition.
- A fixed maximum fee embedded in each redeem script.
- No cancellation, recovery key, emergency path, batching, change output, or
  P2SH destination support.

## State transitions

### Vault to approved destination

The owner signature is required. The transaction must contain exactly one
input and one output, output 0 must be the approved P2PK script public key, and
output 0 must be the sole covenant-authorized output. Its fee must not exceed
the embedded ceiling. This path has no delay.

### Vault to pending destination

The owner signature is required. The witness supplies one versioned P2PK
destination script. The vault redeem script reconstructs a second-stage
pending redeem script containing that exact destination, hashes it, and
requires the sole authorized output to use the resulting P2SH script public
key. This commits the destination before the delay starts.

### Pending destination to final destination

The owner signature is required again. `OP_CHECKSEQUENCEVERIFY` requires the
input sequence to meet the embedded DAA delay. Kaspa's contextual transaction
validation applies that sequence relative to the pending UTXO's own creation
DAA score. The sole authorized output must equal the destination embedded in
the pending redeem script, and the fee ceiling is enforced again.

## Security invariants

The scripts must reject:

- a direct spend from the vault to an unapproved destination;
- changing the destination between the pending and final stages;
- spending the pending output with a sequence below the delay;
- extra inputs or outputs;
- missing or incorrect covenant authorization bindings;
- a fee above the embedded ceiling;
- a destination that is not a canonical version-0 P2PK script.

The separate `consensus-tests` crate pins the exact Rusty Kaspa revision used
for verification and executes the generated scripts in Kaspa's production
`TxScriptEngine`. The ordinary WASM lockfile is intentionally unaffected.

## Explicit V1 limitation

This design has no cancellation path. If an attacker controls the owner key,
they can create a valid pending withdrawal to their destination. Consensus
prevents spending it before the delay, but V1 provides no transaction that can
cancel or redirect it during that window. Do not enable mainnet funding until
the complete transaction construction, hardware signing, broadcast, tracking,
and independent review gates are finished.
