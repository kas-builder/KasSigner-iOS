# KasSigner iOS

KasSigner iOS is a native iPhone wallet and portfolio app for Kaspa. It supports Mainnet watch-only accounts that use an air-gapped **M5 Stack Core S3** for signing, plus Testnet 10 accounts and Protected Vaults for testing.

The app bundles its own transaction runtime and connects directly to Kaspa network services or a supported node. It does not require a companion website to operate.

**Project version:** 6.0 (build 1)

KAS donations: `kaspa:qqpzpn5e7enn2ylfdxvlwtm3829gn6j9z9dnnmcsw5arkgnurktty6ulgzkfk`

## Status

KasSigner iOS is under active development. Treat it as beta software. Test with small amounts and carefully review every transaction before approving it. For Mainnet transactions, verify the destination, amount, change, and fee on the M5 Stack Core S3.

The app supports two distinct account workflows:

- **Mainnet:** import a public account key (`kpub`) and use a compatible, air-gapped M5 Stack Core S3 to sign.
- **Testnet 10:** create or restore a 12-word account in the app. The app stores its recovery words in the iOS Keychain and signs Testnet 10 transactions on the iPhone.

Never include recovery words, private keys, or signing payloads in bug reports, screenshots, or logs.

## Networks and account types

Choose the network in **Settings → Network & Node** before adding an account.

### Mainnet watch-only accounts

Mainnet accounts are imported from a `kpub` QR code or pasted public key. The iPhone derives and monitors the account’s addresses, synchronizes wallet activity, selects UTXOs, and prepares transactions. The Mainnet watch-only workflow does not import the account’s seed phrase or private keys.

Mainnet transaction signing is performed by a compatible air-gapped M5 Stack Core S3. The iPhone sends an unsigned transaction request through animated QR codes, receives the signed response, verifies it, and broadcasts it after device-owner authentication.

### Testnet 10 accounts

Testnet 10 accounts can be generated in the app or restored with their 12 recovery words. The app stores those words in the iOS Keychain, scoped to the device and available only while it is unlocked. Back up the recovery words separately if you need to restore the account on another installation.

Testnet 10 transactions are signed on the iPhone. Testnet 10 accounts and funds are separate from Mainnet accounts and funds.

Testnet 10 uses automatic nodes. The Mainnet custom-node setting is not reused on Testnet 10.

## Mainnet signing

For Mainnet, the iPhone acts as a watch-only transaction coordinator:

1. Import the public account key from the M5 Stack Core S3.
2. Synchronize the account and select UTXOs.
3. Review the transaction and display its animated QR request.
4. Scan the request with the M5 Stack Core S3.
5. Review the transaction on its screen and approve signing.
6. Scan the signed response with the iPhone.
7. Allow the app to verify the returned transaction and signatures.
8. Authenticate on the iPhone and broadcast the verified transaction.

The M5 Stack Core S3 is the final review authority for approving a Mainnet transaction. Verify its display before approving.

## Wallet and synchronization

- Import Mainnet watch-only accounts from a `kpub` QR code or pasted `kpub`
- Create or restore Testnet 10 accounts using 12 recovery words
- Manage, switch, rename, and locally delete accounts
- Discover and derive receive and change addresses
- Synchronize balances, UTXOs, transaction history, and address status
- Refresh wallet data from node notifications
- Show cached wallet state while refreshing current data
- Track sent, received, internal-transfer, pending, and confirmed transactions
- Display confirmation progress using accepting-block blue scores
- Label transactions and UTXOs
- Show estimated USD values for UTXOs
- Optionally show a Currency Converter card on the Wallet tab; it is off by default
- Export wallet transaction history to CSV

Address discovery is limited to 512 addresses per chain. The app reports when an account reaches this limit.

## Sending

The send flow supports:

- Selecting individual UTXOs or all available inputs, with an eight-input workflow limit
- Standard, Privacy, and Decoy transaction types
- Exact-amount and send-max transactions
- Up to four destinations where supported by the selected transaction type
- Low, normal, priority, or custom fees
- One or more change outputs, depending on transaction type
- Manual or automatic change allocation for supported multi-output sends
- Output-order randomization for Privacy and Decoy transactions
- Transaction review showing destinations, change, fees, and estimated values
- In-memory transaction drafts that are discarded when the flow is cancelled or closed
- Animated QR signing requests and out-of-order QR response scanning for Mainnet hardware signing
- Device-owner authentication before broadcasting

Mainnet sends use the M5 Stack Core S3 signing flow. Testnet 10 sends are signed on the iPhone and are intended for testing.

## Protected Vaults and programmable UTXOs

Protected Vaults are currently available **only on Testnet 10**. On Mainnet, the **Create Programmable UTXO** button displays an availability alert; it does not create or fund a Mainnet vault. The **New Time-Locked UTXO** option is a placeholder and is not implemented.

A Testnet 10 Protected Vault can define approved withdrawal addresses, a recovery address, a security delay, and a recovery path. The app supports funding, status refresh, and withdrawal flows. An unapproved withdrawal can enter a delayed stage and require a later transaction to complete; the delay is enforced by the covenant’s on-chain conditions.

Vault records are local app data. Use **Export Vault Recovery File** to save the vault records needed to restore them after reinstalling the app or restoring an account. The recovery file is separate from the account’s recovery words and does not replace the 12-word account backup. If vault records are missing, import the account first, then import its vault recovery file.

Protected Vaults and their transactions are experimental Testnet 10 functionality. They are not available on Mainnet.

## QR and transaction verification

For Mainnet hardware signing, the app uses a versioned multi-frame QR envelope with transfer identity, message type, frame numbering, total length, and a payload digest. This helps prevent frames from separate transfers being combined and rejects malformed or inconsistent payloads.

When a signed transaction returns, the app checks it against the transaction originally approved. It verifies the expected signatures and broadcasts the verified transaction data. The app does not restore unfinished signing drafts after relaunch.

## Portfolio

The Portfolio tab is separate from wallet signing and supports:

- Multiple named, color-coded portfolio accounts
- Buys, sells, transfers in, and transfers out
- Holdings, weighted cost basis, activity, and performance calculations
- Portfolio value and KAS price charts
- Manual transaction entry, inspection, editing, and deletion
- CSV import with validation, duplicate detection, and a review summary
- CSV export

## Security and local data

- Optional app lock using Face ID, Touch ID, or the device passcode
- Configurable app-lock delay and optional hidden app-switcher preview
- Optional authenticated Decoy Launch into a weather screen
- Authentication before transaction broadcast and protected operations
- Protected wallet files use complete iOS file protection and are excluded from backups
- Testnet 10 recovery words are stored in the iOS Keychain as device-only data
- In-progress signing drafts are kept in memory
- Copy operations use a temporary local pasteboard entry

Mainnet `kpub` data, addresses, balances, and transaction history are public-chain information, but can reveal an account’s activity and should be treated as privacy-sensitive. A Testnet 10 vault recovery file contains vault records and configuration; keep it with the same care as other wallet backup data.

Deleting an account removes its local profile and associated Testnet 10 recovery words from the app’s secure storage. Deleting the app removes its local files; do not rely on uninstalling to erase Keychain data. Neither action changes funds or replaces the need for account recovery words and any required vault recovery records.

## Network and external services

Mainnet can use automatic public Kaspa nodes or a custom Kaspa wRPC endpoint configured under **Settings → Network & Node**. The selected node receives the public addresses needed to synchronize the wallet. Custom nodes must provide wRPC with UTXO indexing enabled.

The app also uses Kaspa public API services for some address and historical-activity checks. Testnet 10 uses Testnet 10 network services and automatic nodes.

Price providers may receive general KAS price requests. They do not need the wallet’s `kpub` to provide market prices. The optional weather screen uses Open-Meteo and sends the location information needed for its weather request.

`ws://` traffic is unencrypted. Use `wss://` when connecting to a custom node over an untrusted network.

## Preferences

Settings include:

- System, Light, and Dark appearance
- KAS display precision
- USD or BTC secondary balance display
- Automatic, CoinGecko, or CoinPaprika price selection
- Kaspa.stream or Kaspa Explorer links
- UTXO card status defaults and address-status display
- Mainnet automatic-node or custom-node configuration
- App lock, app-switcher preview, and Decoy Launch settings

## Requirements

- A Mac with Xcode that supports the project’s iOS 17.6 deployment target
- An iPhone or iOS Simulator running iOS 17.6 or later
- A physical iPhone for camera-based QR scanning
- A compatible, air-gapped M5 Stack Core S3 for Mainnet signing
- An Apple development team configured in Xcode to install on a physical iPhone

The repository includes the JavaScript and WebAssembly runtime needed by the app. Running the Xcode project does not require installing Rust, npm, or a separate website. Rust tooling is needed only when changing and rebuilding the bundled runtime.

## Build and run

Clone the repository and open the Xcode project:

```bash
git clone https://github.com/kas-builder/KasSigner-iOS.git
cd KasSigner-iOS
open KasSigner.xcodeproj
```

In Xcode, select the **KasSigner** scheme and an iPhone Simulator or connected iPhone, then choose **Run**.

To install on a physical iPhone, select the KasSigner app target, open **Signing & Capabilities**, choose your Apple development team, and select the connected device. The repository does not include a provisioning profile or signing certificate.

The Simulator can run the app, but its camera does not exercise the physical QR-scanning workflow. Test camera-based account import and hardware signing on a physical iPhone.

## Run tests

Run the Xcode tests on an available iOS Simulator:

```bash
xcodebuild test \
  -project KasSigner.xcodeproj \
  -scheme KasSigner \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The Rust runtime tests can be run with:

```bash
cargo test --manifest-path Runtime/kassee/Cargo.toml
```

The Rust runtime source and rebuild instructions are in [`Runtime/README.md`](Runtime/README.md).

## Repository layout

```text
KasSigner-iOS/
├── KasSigner/
│   ├── App/                 App entry point
│   ├── Models/              Wallet, preferences, portfolio, and sync models
│   ├── Services/            Wallet engine, sync, authentication, and pricing
│   ├── Views/               SwiftUI screens and QR workflows
│   ├── Resources/Web/       Bundled JavaScript and WebAssembly runtime
│   └── Assets.xcassets/     App icons and assets
├── KasSignerTests/          Swift regression tests
├── Runtime/kassee/          Rust runtime source
├── Runtime/README.md        Runtime rebuild instructions
└── THIRD_PARTY_NOTICES.md   Third-party notices
```

## Compatibility and licensing

- iOS app: [KasSigner-iOS](https://github.com/kas-builder/KasSigner-iOS)
- Compatible signing firmware: [M5 Stack Core S3 firmware fork](https://github.com/kas-builder/KasSigner-M5Stack-fork-brt)

The project is licensed under GPL-3.0. See [`LICENSE`](LICENSE) and preserve the license and upstream notices associated with bundled runtime code.
