import Foundation

struct DailyPriceCandle: Codable, Equatable, Sendable {
    let timestamp: Date
    let openUSD: Double
    let highUSD: Double
    let lowUSD: Double
    let closeUSD: Double
}

struct HistoricalPriceDiskCache: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var bundledVersion: String
    var dailyCandles: [DailyPriceCandle]
    var hourlyPoints: [HistoricalPricePoint]
    var lastRefreshAttemptDayUTC: String?
}

enum HistoricalPriceCacheStore {
    static let schemaVersion = 1
    static let bundledVersion = "2026-08-13"
    static let bundledResourceName = "KaspaDailyUSD"

    enum CacheError: Error {
        case missingBundledHistory
        case invalidBundledHistory
        case unavailableCacheDirectory
    }

    static func parseBundledCSV(_ data: Data) throws -> [DailyPriceCandle] {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CacheError.invalidBundledHistory
        }

        let lines = contents.split(whereSeparator: \.isNewline)
        guard lines.first == "timestamp,open,high,low,close" else {
            throw CacheError.invalidBundledHistory
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var candles: [DailyPriceCandle] = []
        candles.reserveCapacity(max(0, lines.count - 1))

        for line in lines.dropFirst() {
            let values = line.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count == 5,
                  let timestamp = formatter.date(from: String(values[0])),
                  let open = Double(values[1]),
                  let high = Double(values[2]),
                  let low = Double(values[3]),
                  let close = Double(values[4]),
                  [open, high, low, close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  high >= max(open, close, low),
                  low <= min(open, close, high) else {
                throw CacheError.invalidBundledHistory
            }

            candles.append(DailyPriceCandle(
                timestamp: timestamp,
                openUSD: open,
                highUSD: high,
                lowUSD: low,
                closeUSD: close
            ))
        }

        guard !candles.isEmpty else {
            throw CacheError.invalidBundledHistory
        }

        let ordered = candles.sorted { $0.timestamp < $1.timestamp }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else {
            throw CacheError.invalidBundledHistory
        }
        return ordered
    }

    static func bundledCandles(bundle: Bundle = .main) throws -> [DailyPriceCandle] {
        guard let url = bundle.url(
            forResource: bundledResourceName,
            withExtension: "csv"
        ) else {
            throw CacheError.missingBundledHistory
        }
        return try parseBundledCSV(Data(contentsOf: url))
    }

    static func load(from url: URL) -> HistoricalPriceDiskCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(HistoricalPriceDiskCache.self, from: data),
              cache.schemaVersion == schemaVersion,
              !cache.dailyCandles.isEmpty else {
            return nil
        }
        return cache
    }

    static func save(_ cache: HistoricalPriceDiskCache, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(cache)
        try data.write(to: url, options: .atomic)
    }

    static func defaultCacheURL(fileManager: FileManager = .default) -> URL? {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return applicationSupport
            .appendingPathComponent("KasSigner", isDirectory: true)
            .appendingPathComponent("HistoricalPrices-v1.json")
    }
}
