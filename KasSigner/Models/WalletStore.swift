import Foundation

@MainActor
final class WalletStore: ObservableObject {
    @Published private(set) var profiles: [WalletProfile] = []
    @Published var selectedProfileID: UUID? { didSet { save() } }

    private let storageKey = "kassigner.walletProfiles.v1"
    private let selectionKey = "kassigner.selectedWalletProfile.v1"
    private let receiveIndexKeyPrefix = "kassigner.lastViewedReceiveIndex.v1."

    init() {
        load()
    }

    var selectedProfile: WalletProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first
    }

    func add(_ profile: WalletProfile) {
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
    }

    func update(_ profile: WalletProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    @discardableResult
    func reserveChangeAddress(profileID: UUID, index: Int) -> Bool {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              index == profiles[profileIndex].nextChangeIndex
        else {
            return false
        }

        profiles[profileIndex].nextChangeIndex = index + 1
        save()
        return true
    }

    func lastViewedReceiveIndex(for profileID: UUID, addressCount: Int) -> Int {
        guard addressCount > 0 else { return 0 }
        let stored = UserDefaults.standard.integer(
            forKey: receiveIndexKeyPrefix + profileID.uuidString
        )
        return min(max(0, stored), addressCount - 1)
    }

    func setLastViewedReceiveIndex(_ index: Int, for profileID: UUID, addressCount: Int) {
        guard addressCount > 0 else { return }
        let clamped = min(max(0, index), addressCount - 1)
        UserDefaults.standard.set(
            clamped,
            forKey: receiveIndexKeyPrefix + profileID.uuidString
        )
    }

    func remove(at offsets: IndexSet) {
        let removedProfileIDs = offsets.compactMap { index in
            profiles.indices.contains(index) ? profiles[index].id : nil
        }

        for profileID in removedProfileIDs {
            UserDefaults.standard.removeObject(
                forKey: receiveIndexKeyPrefix + profileID.uuidString
            )
        }

        profiles.remove(atOffsets: offsets)
        if let selectedProfileID, !profiles.contains(where: { $0.id == selectedProfileID }) {
            self.selectedProfileID = profiles.first?.id
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WalletProfile].self, from: data)
        else { return }
        profiles = decoded
        if let raw = UserDefaults.standard.string(forKey: selectionKey),
           let id = UUID(uuidString: raw),
           decoded.contains(where: { $0.id == id }) {
            selectedProfileID = id
        } else {
            selectedProfileID = decoded.first?.id
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: selectionKey)
    }
}
