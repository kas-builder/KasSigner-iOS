# KasSigner

$kas donation address: kaspa:qqpzpn5e7enn2ylfdxvlwtm3829gn6j9z9dnnmcsw5arkgnurktty6ulgzkfk 

KasSigner is a native, watch-only Kaspa wallet for iPhone. It builds transactions on the phone and exchanges animated QR codes with an air-gapped KasSigner device for review and signing.

Private keys and seed phrases are not requested or stored by the iOS app.

**Beta Status**

KasSigner is under active development and should be considered beta software. Core watch-only wallet functionality, transaction creation, QR signing, and broadcast are implemented, but the project is still being refined and some bugs, edge cases, and incomplete features are expected. Stability, performance, and the user experience will continue to improve as development progresses.

Feedback, bug reports, testing results, and contributions are welcome. If you encounter a reproducible issue, please open a GitHub Issue with clear reproduction steps, your device and iOS version, and any relevant screenshots or logs (excluding sensitive wallet information). Until the project reaches a stable release, test with small amounts and always verify transaction details on the air-gapped signing device before approving a transaction.
## Current features

- Import a watch-only account from a Kaspa public wallet QR (`kpub`)
- Synchronize balances and UTXOs from Kaspa wRPC nodes
- Automatic public-node selection or a custom `ws://` / `wss://` node
- Receive-address display and QR generation
- UTXO inspection, labeling, and coin selection
- Send-max and specific-amount transactions
- Low, normal, priority, and custom fee selection
- Local transaction checks before signing
- Animated QR transfer to an air-gapped signer
- Multi-frame signed transaction scanning
- Transaction broadcast and transaction ID display
- Kaspa.stream and Kaspa Explorer links

## Requirements

- A Mac running Xcode with iOS 17.6 or newer SDK support
- An iPhone or iOS Simulator running iOS 17.6 or newer
- An Apple ID added to Xcode only when installing on a physical iPhone

No package manager, Rust toolchain, npm installation, or separate WebAssembly build is required. The runtime used by the app is included in the repository.

## Get the source

Clone the repository:

```bash
git clone https://github.com/kas-builder/KasSigner-iOS.git
cd KasSigner-iOS
```

Or download the source ZIP from GitHub and extract it.

## Open in Xcode

```bash
open KasSigner.xcodeproj
```

Select the **KasSigner** scheme and choose an iPhone Simulator or a connected iPhone.

### Run in the Simulator

Press **Command-R** in Xcode.

The Simulator cannot scan camera QR codes. Importing an account and scanning a signed transaction require a physical iPhone unless those flows are exercised through an alternate local testing method.

### Run on a physical iPhone

1. Select the KasSigner project in Xcode.
2. Open **Signing & Capabilities** for the KasSigner target.
3. Choose your own development team.
4. Change the bundle identifier if Xcode reports that `org.kassigner.KasSigner` is unavailable for your account.
5. Connect and select the iPhone, then press **Command-R**.

The repository does not contain a development-team ID, provisioning profile, or signing certificate.

## Command-line build

Build for the iOS Simulator without code signing:

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

List available schemes and build settings:

```bash
xcodebuild -list -project KasSigner.xcodeproj
xcodebuild -showBuildSettings -project KasSigner.xcodeproj -scheme KasSigner
```

Clean local build output:

```bash
xcodebuild \
  -project KasSigner.xcodeproj \
  -scheme KasSigner \
  clean
```

## Using KasSigner

1. Open **Add Account** and scan the public-wallet QR exported by the compatible KasSigner device.
2. Let the watch-only wallet synchronize.
3. Select **Receive** to display an address, or **Send** to choose UTXOs and create a transaction.
4. Review the destination, amount, selected inputs, and fee in the app.
5. Scan the animated signing QR with the air-gapped device.
6. Review and sign on the device.
7. Scan every returned QR frame with the iPhone.
8. Review the completed transaction and broadcast it.

## Node configuration

Automatic mode rotates through bundled public Kaspa wRPC endpoints. A custom node can be configured in **Settings → Node Settings**.

A custom endpoint must:

- use `ws://` or `wss://`;
- expose Kaspa wRPC;
- have UTXO indexing enabled;
- be reachable from the iPhone.

## Local data

KasSigner stores watch-only account information and app preferences in the app's local `UserDefaults` container. This can include imported public wallet data, derived public addresses, wallet snapshots, UTXO labels, explorer choice, and custom-node settings.

That runtime data is created only after the installed app is used. It is not included in this repository.

To reset a local installation, delete the app from the Simulator or iPhone and install it again.

## Repository layout

```text
KasSigner/
├── App/                 App entry point
├── Models/              Wallet, preferences, and synchronization models
├── Services/            WebAssembly bridge and wallet synchronization
├── Views/               SwiftUI screens and QR workflows
├── Resources/Web/       Bundled JavaScript and WebAssembly runtime
└── Assets.xcassets/     App icons and asset catalog
```

## Security notes

- The iOS app is watch-only and should never be given a seed phrase or private key.
- Verify the destination, amount, and fee on the air-gapped signing device.
- Confirm that the signing device and imported public wallet belong to the same account.
- Treat custom node operators as network-data providers; use a node you trust when privacy matters.
- Do not publish logs or screenshots containing wallet public keys, addresses, transaction payloads, or transaction IDs unless you intend to disclose them.

## Upstream references

- [`kaspanet/rusty-kaspa`](https://github.com/kaspanet/rusty-kaspa) is the protocol and transaction-behavior source of truth.
- [`azbuky/kaspium_wallet`](https://github.com/azbuky/kaspium_wallet) is the reference architecture for wallet synchronization: direct node subscriptions, lifecycle-aware connections, debounced UTXO updates, affected-address refreshes, and locally cached wallet state. The refresh analysis used commit `1f82c7d2fcfcce7c08998c84e4e25c3cb623e7b2`.

## License

KasSigner is licensed under the GNU General Public License version 3. See [LICENSE](LICENSE).
$kas donation address: kaspa:qqpzpn5e7enn2ylfdxvlwtm3829gn6j9z9dnnmcsw5arkgnurktty6ulgzkfk 💚
