import SwiftUI

struct SecuritySettingsView: View {
    @EnvironmentObject private var appLockService: AppLockService
    @State private var appLockToggle = false
    @AppStorage("kassigner.security.decoyLaunchScreenEnabled")
    private var decoyLaunchScreenEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Face ID", isOn: $appLockToggle)
                    .disabled(appLockService.isAuthenticating)
                    .onChange(of: appLockToggle) { oldValue, newValue in
                        guard oldValue != newValue,
                              newValue != appLockService.isEnabled else { return }
                        Task {
                            let succeeded = newValue
                                ? await appLockService.enableAppLock()
                                : await appLockService.disableAppLock()
                            if !succeeded {
                                appLockToggle = appLockService.isEnabled
                            }
                        }
                    }

                if appLockService.isEnabled {
                    Picker("Require Authentication", selection: $appLockService.lockDelay) {
                        ForEach(AppLockService.LockDelay.allCases) { delay in
                            Text(delay.title).tag(delay)
                        }
                    }
                }
            } header: {
                Text("Biometrics")
            } footer: {
                Text("Use \(appLockService.biometricName) or your device passcode to unlock KasSigner.")
            }

            Section("Privacy") {
                Toggle("Hide App Switcher Preview", isOn: $appLockService.hideAppSwitcherPreview)
                Toggle("Decoy Launch Screen", isOn: $decoyLaunchScreenEnabled)
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            appLockToggle = appLockService.isEnabled
        }
        .alert("Authentication Unavailable", isPresented: authenticationAlertPresented) {
            Button("OK", role: .cancel) {
                appLockService.authenticationError = nil
            }
        } message: {
            Text(appLockService.authenticationError ?? "Authentication could not be completed.")
        }
    }

    private var authenticationAlertPresented: Binding<Bool> {
        Binding(
            get: { appLockService.authenticationError != nil },
            set: { if !$0 { appLockService.authenticationError = nil } }
        )
    }
}
