# KasSigner-iOS

KAS donations: kaspa:qqpzpn5e7enn2ylfdxvlwtm3829gn6j9z9dnnmcsw5arkgnurktty6ulgzkfk 💚

KasSigner-iOS is a native, watch-only Kaspa wallet and portfolio app for iPhone. It discovers and monitors accounts from an imported public wallet key (`kpub`), constructs transactions on the phone, and exchanges animated QR codes with an air-gapped KasSigner device for independent review and signing.

Private keys, seed phrases, and signing passphrases are never requested or stored by the iOS app.

**Current version:** 4.1 (build 19)

## Beta status

KasSigner is under active development and should be considered beta software. Wallet discovery, transaction construction, air-gapped signing, return verification, broadcast, and portfolio tracking are implemented, but bugs and edge cases may remain.

Test with small amounts and verify the destination, amount, change, and fee on the air-gapped signing device before approving every transaction. Never include seed words, private keys, signing payloads, or other sensitive wallet information in bug reports, screenshots, or logs.

## Trust model

KasSigner separates wallet coordination from signing:

- The iPhone imports public account material and operates as a watch-only wallet.
- The iPhone discovers addresses, synchronizes wallet activity, selects UTXOs, and constructs unsigned transactions.
- The air-gapped KasSigner device holds private keys, displays transaction details, and signs after physical approval.
- The iPhone verifies the returned transaction and Schnorr signatures before broadcast.

The hardware signer is the final review authority. Confirm transaction details on its screen rather than relying only on the phone.

## Wallet and synchronization features

- Import compatible KasSigner `kpub` QR exports without exposing private keys
- Manage, switch, rename, copy, and locally remove multiple watch-only accounts
- Automatically discover historical activity across receive and change chains
- Maintain a safety gap beyond the highest discovered activity
- Keep new imports provisional until initial discovery succeeds
- Retry or cancel interrupted discovery without replacing the last usable wallet
- Cache wallet state for immediate display while current data refreshes
- Synchronize balances, UTXOs, transaction history, and used-address state
- Subscribe to Kaspa node notifications and refresh affected wallet data
- Track sent, received, internal-transfer, pending, and confirmed transactions
- Display confirmation progress using accepting-block blue scores
- Inspect and label transactions and UTXOs

## Receive and address management

- Display receive and change addresses as text and QR codes
- Identify addresses as fresh, used, or temporarily unavailable
- Open to the earliest known fresh receive address
- Optionally reopen at the last manually viewed address
- Browse receive and change addresses in native list views
- Jump from an address list directly to its QR code
- Derive additional public addresses when the available pool needs extending
- Copy wallet values through a local-only pasteboard entry that expires after two minutes

## Sending and air-gapped signing

- Select individual UTXOs or all available inputs, with an eight-input workflow limit
- Label UTXOs for coin-control workflows
- Construct exact-amount or send-max transactions
- Choose low, normal, priority, or custom fees
- Automatically focus the numeric custom-fee field
- Select any derived change address, including a previously used address
- Review destination, amount, fee, inputs, and change before signing
- Cancel and discard an in-memory transaction session
- Display animated signing QR frames with play/pause control and a five-second interval
- Scan signed frames in any order and show real collection progress
- Control the camera torch from every iPhone QR scanner; it turns off when scanning closes
- Require Face ID, Touch ID, or device-passcode authorization before broadcast
- Display the resulting transaction ID and open it in the selected explorer

## QR and returned-transaction security

The current QR protocol uses a versioned multi-frame envelope containing a transfer identifier, message type, frame index, frame count, exact total length, and payload digest. Frames from separate transfers cannot be silently combined. Malformed, conflicting, truncated, and tampered payloads are rejected.

When a signed transaction returns, the iOS runtime:

1. Compares its immutable transaction fields with the originally approved transaction.
2. Treats only expected signature fields as mutable.
3. Verifies each returned Schnorr signature against the original sighash and expected input key.
4. Inserts verified signatures into the original approved PSKB.
5. Broadcasts only that verified result—not the independently scanned object.

Signing drafts are memory-only. Cancelling or leaving the flow discards the session instead of restoring an unfinished transaction after relaunch.

## Transactions and CSV

- View sent, received, internal-transfer, pending, and confirmed activity
- Preserve local broadcast details while network confirmation arrives
- Add and edit transaction labels
- Export wallet transactions to CSV with the newest transaction first
- Include historical USD prices when that data is available
- Open addresses and transactions in Kaspa.stream or Kaspa Explorer

## Portfolio

The Portfolio tab is separate from hardware-wallet signing and supports:

- Multiple named, color-coded portfolio accounts
- Buys, sells, transfers in, and transfers out
- Holdings, weighted cost basis, activity, and performance calculations
- Portfolio-value and KAS price charts using bundled and refreshed historical prices
- Manual transaction creation, inspection, editing, and deletion
- CSV import with validation, duplicate detection, and a review summary
- Newest-first portfolio CSV export

## Security and privacy controls

- Optional Face ID or Touch ID app lock with immediate, one-minute, or five-minute delay
- Device-passcode fallback through the iOS authentication framework
- Mandatory authentication before transaction broadcast
- Optional hidden app-switcher preview
- Optional authenticated decoy launch into a functional weather screen
- Complete iOS file protection for wallet profiles, derived addresses, labels, and transaction caches
- Protected wallet files excluded from backups
- Verified migration before legacy wallet data is removed
- Local-only, two-minute wallet pasteboard entries that do not propagate through Universal Clipboard
- In-progress signing sessions retained only in memory

File protection relies on iOS protections while the device is locked. A `kpub`, its derived addresses, balances, and transaction history are public-chain data but remain privacy-sensitive because they can reveal an account's complete activity.

## Appearance and preferences

- System, Light, and Dark themes
- Configurable KAS decimal places
- USD or BTC secondary balance display
- Automatic price selection or CoinGecko/CoinPaprika preference
- Kaspa.stream or Kaspa Explorer links
- Configurable address-status display
- Mainnet automatic-node mode or a custom Kaspa wRPC endpoint

## Network behavior

Automatic mode rotates through bundled public Kaspa wRPC endpoints. A custom endpoint can be configured under **Settings → Network & Node** and must expose Kaspa wRPC with UTXO indexing enabled.

Both `ws://` and `wss://` endpoints are accepted. Use `wss://` whenever possible; plaintext `ws://` does not protect traffic from local-network or transit observers.

The selected node receives public addresses required for wallet synchronization. Automatic-mode discovery and history services can also receive queried addresses. In Custom Node mode, public-indexer historical discovery is skipped rather than silently sending the custom wallet's address set to that service; current UTXOs are still synchronized through the selected node. Features unavailable from the custom service may be limited.

CoinGecko and CoinPaprika receive general KAS price requests without the wallet's `kpub` or addresses. The optional weather cover uses Open-Meteo and sends the selected coordinates needed for its forecast request.

## Requirements

- A Mac with Xcode capable of targeting iOS 17.6 or newer
- An iPhone or iOS Simulator running iOS 17.6 or newer
- A physical iPhone for camera QR workflows
- A compatible air-gapped M5Stack Cores3 hardware device for signing
- An Apple ID in Xcode when installing a development build on a physical iPhone

No package manager, Rust toolchain, npm installation, or separate WebAssembly build is required to run the checked-in app. Its compiled runtime is included in the repository. Developers changing that runtime should follow [`Runtime/README.md`](Runtime/README.md).

## Get the source

```bash
git clone https://github.com/kas-builder/KasSigner-iOS.git
cd KasSigner-iOS
open KasSigner.xcodeproj
```

Select the **KasSigner** scheme and an iPhone Simulator or connected iPhone, then press **Command-R**.

The Simulator cannot exercise the physical camera workflow. Account QR import and signed-transaction scanning should be tested on a physical iPhone unless an explicit local test harness is used.

### Physical iPhone signing

1. Select the KasSigner target in Xcode.
2. Open **Signing & Capabilities**.
3. Choose your Apple development team.
4. Change the bundle identifier if the default is unavailable to your account.
5. Select the connected iPhone and press **Command-R**.

The repository does not contain a development-team ID, provisioning profile, or signing certificate.

## Command-line build and tests

```bash
xcodebuild \
  -project KasSigner.xcodeproj \
  -scheme KasSigner \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the Rust runtime tests:

```bash
cargo test --manifest-path Runtime/kassee/Cargo.toml
```

List schemes or inspect build settings:

```bash
xcodebuild -list -project KasSigner.xcodeproj
xcodebuild -showBuildSettings -project KasSigner.xcodeproj -scheme KasSigner
```

## Using KasSigner

1. Export the intended account's public Kaspa key from the hardware signer.
2. Open **Add Account** on iPhone and scan the `kpub` QR.
3. Allow initial wallet discovery to finish.
4. Open **Receive**, or use **Send** to select UTXOs and construct a transaction.
5. Review the transaction and display its animated signing QR.
6. Scan the request with the air-gapped device.
7. Verify the hardware display and approve signing.
8. Scan the returned frames with the iPhone.
9. Allow KasSigner to verify the transaction and signatures.
10. Authenticate, then broadcast.

## Local data and reset behavior

KasSigner stores watch-only wallet state, public addresses, labels, preferences, cached history, and market data locally. Privacy-sensitive wallet state and caches use complete file protection and are excluded from backups. General non-wallet preferences may remain in `UserDefaults`.

Deleting a watch-only account removes its local data from that installation; it does not affect funds or the hardware signer. The same `kpub` can later be reimported and rediscovered. Delete and reinstall the app to reset the entire local installation.

## Known limitations

- KasSigner is beta software and currently targets Kaspa mainnet.
- It is watch-only and cannot recover funds without the corresponding hardware-held seed or private key.
- Camera signing requires a physical iPhone.
- Accounts with extensive history can take longer to discover safely.
- Discovery is limited to 512 addresses per chain and reports when activity reaches that limit.
- Custom-node functionality depends on data exposed by the selected wRPC service.
- `ws://` is intended for controlled local or development use and provides no transport confidentiality.
- Multisig hardening remains incomplete; multisig is not a supported production workflow.

## Repository layout

```text
KasSigner-iOS/
├── KasSigner/
│   ├── App/                 App entry point
│   ├── Models/              Wallet, preferences, portfolio, and sync models
│   ├── Services/            Runtime bridge, pricing, and wallet sync
│   ├── Views/               SwiftUI screens and QR workflows
│   ├── Resources/Web/       Bundled JavaScript and WebAssembly runtime
│   └── Assets.xcassets/     App icons and assets
├── KasSignerTests/          Swift regression tests
└── Runtime/kassee/          Rust transaction and QR runtime source
```

## Security guidance

- Never enter a seed phrase or private key into the iOS app.
- Verify destination, amount, change, and fee on the hardware device.
- Confirm the imported `kpub` belongs to the intended hardware account.
- Treat wallet keys, addresses, history, and CSV exports as privacy-sensitive.
- Prefer a trusted node and encrypted `wss://` transport.
- Keep an independently verified backup of the hardware-wallet seed.

## Upstream references

- [`kaspanet/rusty-kaspa`](https://github.com/kaspanet/rusty-kaspa) is the protocol and transaction-behavior source of truth.
- [`azbuky/kaspium_wallet`](https://github.com/azbuky/kaspium_wallet) is a reference for direct subscriptions, lifecycle-aware connections, debounced UTXO updates, affected-address refreshes, and cached wallet state.

## License

KasSigner is licensed under the GNU General Public License version 3. See [LICENSE](LICENSE).

KAS donations: kaspa:qqpzpn5e7enn2ylfdxvlwtm3829gn6j9z9dnnmcsw5arkgnurktty6ulgzkfk 💚
