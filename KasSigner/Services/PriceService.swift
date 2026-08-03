import Foundation

@MainActor
final class PriceService: ObservableObject {
    static let shared = PriceService()

    enum State: Equatable {
        case idle
        case refreshing
        case available
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var prices: [SecondaryCurrency: Double] = [:]
    @Published private(set) var activeProvider: PriceProviderChoice?
    @Published private(set) var lastUpdated: Date?

    private struct CachedPrices: Codable {
        let values: [String: Double]
        let provider: String
        let updatedAt: Date
    }

    private struct CoinGeckoResponse: Decodable {
        let kaspa: [String: Double]
    }

    private struct CoinPaprikaResponse: Decodable {
        struct Quote: Decodable {
            let price: Double
        }

        let quotes: [String: Quote]
    }

    private enum PriceError: LocalizedError {
        case invalidResponse
        case incompleteQuote
        case allProvidersFailed

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The price source returned an invalid response."
            case .incompleteQuote: "The price source did not return every supported currency."
            case .allProvidersFailed: "Price data is temporarily unavailable."
            }
        }
    }

    private let cacheKey = "kassigner.priceCache.v1"
    private let minimumRefreshInterval: TimeInterval = 60
    private let requestTimeout: TimeInterval = 8
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshAttempt: Date?

    private init() {
        loadCache()
    }

    func price(for currency: SecondaryCurrency) -> Double? {
        prices[currency]
    }

    func convertedBalance(kas: Double, currency: SecondaryCurrency) -> Double? {
        guard let price = price(for: currency) else { return nil }
        return kas * price
    }

    func refresh(
        preferences: AppPreferences,
        force: Bool = false
    ) async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        if !force,
           let lastRefreshAttempt,
           Date().timeIntervalSince(lastRefreshAttempt) < minimumRefreshInterval {
            return
        }

        let preferredProvider = preferences.priceProvider
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(preferredProvider: preferredProvider)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(preferredProvider: PriceProviderChoice) async {
        lastRefreshAttempt = Date()
        state = .refreshing

        for provider in providerOrder(preferredProvider) {
            do {
                let fetched = try await fetchPrices(from: provider)
                prices = fetched
                activeProvider = provider
                lastUpdated = Date()
                state = .available
                saveCache()
                return
            } catch {
                continue
            }
        }

        if prices.isEmpty {
            state = .failed(PriceError.allProvidersFailed.localizedDescription)
        } else {
            // Preserve usable cached prices while still surfacing that refresh failed.
            state = .failed("Showing the last saved price.")
        }
    }

    private func providerOrder(_ preferred: PriceProviderChoice) -> [PriceProviderChoice] {
        let providers: [PriceProviderChoice] = [.coinGecko, .coinPaprika]
        guard preferred != .automatic else { return providers }
        return [preferred] + providers.filter { $0 != preferred }
    }

    private func fetchPrices(
        from provider: PriceProviderChoice
    ) async throws -> [SecondaryCurrency: Double] {
        switch provider {
        case .automatic:
            throw PriceError.invalidResponse
        case .coinGecko:
            return try await fetchCoinGecko()
        case .coinPaprika:
            return try await fetchCoinPaprika()
        }
    }

    private func fetchCoinGecko() async throws -> [SecondaryCurrency: Double] {
        guard let url = URL(
            string: "https://api.coingecko.com/api/v3/simple/price?ids=kaspa&vs_currencies=usd,btc"
        ) else {
            throw PriceError.invalidResponse
        }

        let data = try await requestData(from: url)
        let response = try JSONDecoder().decode(CoinGeckoResponse.self, from: data)
        return try validatedPrices(
            usd: response.kaspa["usd"],
            btc: response.kaspa["btc"]
        )
    }

    private func fetchCoinPaprika() async throws -> [SecondaryCurrency: Double] {
        guard let url = URL(
            string: "https://api.coinpaprika.com/v1/tickers/kas-kaspa?quotes=USD,BTC"
        ) else {
            throw PriceError.invalidResponse
        }

        let data = try await requestData(from: url)
        let response = try JSONDecoder().decode(CoinPaprikaResponse.self, from: data)
        return try validatedPrices(
            usd: response.quotes["USD"]?.price,
            btc: response.quotes["BTC"]?.price
        )
    }

    private func requestData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PriceError.invalidResponse
        }
        return data
    }

    private func validatedPrices(
        usd: Double?,
        btc: Double?
    ) throws -> [SecondaryCurrency: Double] {
        guard let usd, usd.isFinite, usd > 0,
              let btc, btc.isFinite, btc > 0 else {
            throw PriceError.incompleteQuote
        }

        return [
            .usd: usd,
            .btc: btc
        ]
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedPrices.self, from: data) else {
            return
        }

        let restoredPairs: [(SecondaryCurrency, Double)] = cached.values.compactMap { entry in
            let (key, value) = entry
            guard let currency = SecondaryCurrency(rawValue: key),
                  value.isFinite,
                  value > 0 else {
                return nil
            }
            return (currency, value)
        }
        let restored = Dictionary(uniqueKeysWithValues: restoredPairs)

        guard !restored.isEmpty else { return }
        prices = restored
        activeProvider = PriceProviderChoice(rawValue: cached.provider)
        lastUpdated = cached.updatedAt
        state = .available
    }

    private func saveCache() {
        guard let activeProvider, let lastUpdated else { return }
        let cached = CachedPrices(
            values: Dictionary(uniqueKeysWithValues: prices.map { ($0.key.rawValue, $0.value) }),
            provider: activeProvider.rawValue,
            updatedAt: lastUpdated
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
