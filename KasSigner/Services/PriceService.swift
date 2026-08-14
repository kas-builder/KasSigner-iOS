import Foundation

struct HistoricalPricePoint: Identifiable, Equatable, Codable, Sendable {
    let timestamp: Date
    let priceUSD: Double

    var id: Date { timestamp }
}

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
    @Published private(set) var isPreparingInitialHistory = false
    @Published private(set) var historicalPreparationProgress = 0.0
    @Published private(set) var historyRevision = 0

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

    private struct CoinGeckoMarketChartResponse: Decodable {
        let prices: [[Double]]
    }

    private struct CoinPaprikaHistoricalPoint: Decodable {
        let timestamp: String
        let price: Double
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
    private var isHistoricalPrepared = false
    private var historicalDiskCache: HistoricalPriceDiskCache?
    private let historicalCacheURL = HistoricalPriceCacheStore.defaultCacheURL()

    private init() {
        loadCache()
        loadHistoricalDiskCache()
    }

    func price(for currency: SecondaryCurrency) -> Double? {
        prices[currency]
    }

    func convertedBalance(kas: Double, currency: SecondaryCurrency) -> Double? {
        guard let price = price(for: currency) else { return nil }
        return kas * price
    }

    func historicalUSDPrices(days: String) async throws -> [HistoricalPricePoint] {
        await prepareHistoricalPrices()
        guard let historicalDiskCache else {
            throw PriceError.invalidResponse
        }

        let requestedDays = max(1, Int(days) ?? 1)
        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -requestedDays,
            to: Date()
        ) ?? .distantPast

        let dailyPoints = historicalDiskCache.dailyCandles
            .lazy
            .filter { $0.timestamp >= cutoff }
            .map { HistoricalPricePoint(timestamp: $0.timestamp, priceUSD: $0.closeUSD) }
        let recentHourlyPoints = historicalDiskCache.hourlyPoints.filter { $0.timestamp >= cutoff }

        var points: [HistoricalPricePoint]
        if requestedDays <= 1, recentHourlyPoints.count >= 2 {
            points = recentHourlyPoints
        } else {
            points = Array(dailyPoints)
            if let latestDailyDate = points.last?.timestamp {
                points.append(contentsOf: recentHourlyPoints.filter { $0.timestamp > latestDailyDate })
            } else {
                points.append(contentsOf: recentHourlyPoints)
            }
        }

        if let currentUSD = prices[.usd], currentUSD.isFinite, currentUSD > 0 {
            points.append(HistoricalPricePoint(timestamp: Date(), priceUSD: currentUSD))
        }
        points = normalizedHistoricalPoints(points)

        guard !points.isEmpty else {
            throw PriceError.invalidResponse
        }
        return points
    }

    func prepareHistoricalPrices() async {
        guard !isHistoricalPrepared else { return }

        isPreparingInitialHistory = true
        historicalPreparationProgress = 0.12
        let startedAt = Date()

        do {
            let bundledCandles = try HistoricalPriceCacheStore.bundledCandles()
            historicalPreparationProgress = 0.65

            var dailyByTimestamp = Dictionary(
                uniqueKeysWithValues: bundledCandles.map { ($0.timestamp, $0) }
            )
            if let existing = historicalDiskCache {
                for candle in existing.dailyCandles
                where candle.timestamp > (bundledCandles.last?.timestamp ?? .distantFuture) {
                    dailyByTimestamp[candle.timestamp] = candle
                }
            }

            let cache = HistoricalPriceDiskCache(
                schemaVersion: HistoricalPriceCacheStore.schemaVersion,
                bundledVersion: HistoricalPriceCacheStore.bundledVersion,
                dailyCandles: dailyByTimestamp.values.sorted { $0.timestamp < $1.timestamp },
                hourlyPoints: historicalDiskCache?.hourlyPoints ?? [],
                lastRefreshAttemptDayUTC: historicalDiskCache?.lastRefreshAttemptDayUTC
            )
            historicalDiskCache = cache
            try saveHistoricalDiskCache()
            historicalPreparationProgress = 1
            isHistoricalPrepared = true
            historyRevision += 1

            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < 0.45 {
                try? await Task.sleep(for: .seconds(0.45 - elapsed))
            }
        } catch {
            isHistoricalPrepared = historicalDiskCache != nil
        }

        isPreparingInitialHistory = false
    }

    func refreshHistoricalPricesIfNeeded() async {
        await prepareHistoricalPrices()
        guard var cache = historicalDiskCache else { return }

        let todayUTC = utcDayString(Date())
        guard cache.lastRefreshAttemptDayUTC != todayUTC else { return }
        cache.lastRefreshAttemptDayUTC = todayUTC
        historicalDiskCache = cache
        try? saveHistoricalDiskCache()

        let requestedDays = historicalRefreshDays(for: cache)
        let fetched: [HistoricalPricePoint]
        do {
            fetched = try await fetchCoinGeckoHistory(days: requestedDays)
        } catch {
            let fallbackDays = min(Int(requestedDays) ?? 2, 365)
            guard let fallback = try? await fetchCoinPaprikaHistory(
                    days: String(fallbackDays)
                  ) else { return }
            fetched = fallback
        }

        let cutoff = Date().addingTimeInterval(-72 * 60 * 60)
        cache.hourlyPoints = normalizedHistoricalPoints(
            cache.hourlyPoints.filter { $0.timestamp >= cutoff } + fetched
        )
        mergeCompletedDailyCandles(from: fetched, into: &cache)
        historicalDiskCache = cache
        try? saveHistoricalDiskCache()
        historyRevision += 1
    }

    private func fetchCoinGeckoHistory(days: String) async throws -> [HistoricalPricePoint] {
        var components = URLComponents(
            string: "https://api.coingecko.com/api/v3/coins/kaspa/market_chart"
        )
        components?.queryItems = [
            URLQueryItem(name: "vs_currency", value: "usd"),
            URLQueryItem(name: "days", value: days),
            URLQueryItem(name: "precision", value: "full")
        ]

        guard let url = components?.url else {
            throw PriceError.invalidResponse
        }

        let data = try await requestData(from: url)
        let response = try JSONDecoder().decode(CoinGeckoMarketChartResponse.self, from: data)
        let points = response.prices.compactMap { entry -> HistoricalPricePoint? in
            guard entry.count >= 2,
                  entry[0].isFinite,
                  entry[1].isFinite,
                  entry[1] > 0 else {
                return nil
            }
            return HistoricalPricePoint(
                timestamp: Date(timeIntervalSince1970: entry[0] / 1_000),
                priceUSD: entry[1]
            )
        }

        guard !points.isEmpty else {
            throw PriceError.invalidResponse
        }
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    private func fetchCoinPaprikaHistory(days: String) async throws -> [HistoricalPricePoint] {
        guard let requestedDays = Int(days), requestedDays <= 365 else {
            throw PriceError.invalidResponse
        }

        let isIntraday = requestedDays <= 1
        let availableDays = isIntraday ? 23.0 / 24.0 : Double(requestedDays)
        let start = Date().addingTimeInterval(-availableDays * 86_400)
        var components = URLComponents(
            string: "https://api.coinpaprika.com/v1/tickers/kas-kaspa/historical"
        )
        components?.queryItems = [
            URLQueryItem(name: "start", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "interval", value: isIntraday ? "1h" : "1d"),
            URLQueryItem(name: "limit", value: "5000"),
            URLQueryItem(name: "quote", value: "usd")
        ]

        guard let url = components?.url else {
            throw PriceError.invalidResponse
        }

        let data = try await requestData(from: url)
        let response = try JSONDecoder().decode([CoinPaprikaHistoricalPoint].self, from: data)
        let formatter = ISO8601DateFormatter()
        var points = response.compactMap { entry -> HistoricalPricePoint? in
            guard entry.price.isFinite,
                  entry.price > 0,
                  let timestamp = formatter.date(from: entry.timestamp) else {
                return nil
            }
            return HistoricalPricePoint(timestamp: timestamp, priceUSD: entry.price)
        }

        if let currentUSD = prices[.usd], currentUSD.isFinite, currentUSD > 0 {
            points.append(HistoricalPricePoint(timestamp: Date(), priceUSD: currentUSD))
        }

        guard !points.isEmpty else {
            throw PriceError.invalidResponse
        }
        return points.sorted { $0.timestamp < $1.timestamp }
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

    private func loadHistoricalDiskCache() {
        guard let historicalCacheURL,
              let cache = HistoricalPriceCacheStore.load(from: historicalCacheURL) else {
            return
        }
        historicalDiskCache = cache
        isHistoricalPrepared = cache.bundledVersion == HistoricalPriceCacheStore.bundledVersion
    }

    private func saveHistoricalDiskCache() throws {
        guard let historicalCacheURL, let historicalDiskCache else {
            throw HistoricalPriceCacheStore.CacheError.unavailableCacheDirectory
        }
        try HistoricalPriceCacheStore.save(historicalDiskCache, to: historicalCacheURL)
    }

    private func normalizedHistoricalPoints(
        _ points: [HistoricalPricePoint]
    ) -> [HistoricalPricePoint] {
        var pointsByTimestamp: [Date: HistoricalPricePoint] = [:]
        for point in points where point.priceUSD.isFinite && point.priceUSD > 0 {
            pointsByTimestamp[point.timestamp] = point
        }
        return pointsByTimestamp.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func mergeCompletedDailyCandles(
        from points: [HistoricalPricePoint],
        into cache: inout HistoricalPriceDiskCache
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentDay = calendar.startOfDay(for: Date())
        let grouped = Dictionary(grouping: points) {
            calendar.startOfDay(for: $0.timestamp)
        }
        var candlesByDay = Dictionary(uniqueKeysWithValues: cache.dailyCandles.map {
            (calendar.startOfDay(for: $0.timestamp), $0)
        })

        for (day, dayPoints) in grouped
        where day < currentDay && candlesByDay[day] == nil {
            let ordered = dayPoints.sorted { $0.timestamp < $1.timestamp }
            guard let first = ordered.first, let last = ordered.last else { continue }
            let prices = ordered.map(\.priceUSD)
            guard let high = prices.max(), let low = prices.min() else { continue }
            candlesByDay[day] = DailyPriceCandle(
                timestamp: calendar.date(byAdding: .day, value: 1, to: day)?
                    .addingTimeInterval(-0.001) ?? last.timestamp,
                openUSD: first.priceUSD,
                highUSD: high,
                lowUSD: low,
                closeUSD: last.priceUSD
            )
        }

        cache.dailyCandles = candlesByDay.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func utcDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func historicalRefreshDays(for cache: HistoricalPriceDiskCache) -> String {
        guard let latest = cache.dailyCandles.last?.timestamp else { return "2" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let elapsed = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latest),
            to: calendar.startOfDay(for: Date())
        ).day ?? 1
        return String(max(2, elapsed + 1))
    }
}
