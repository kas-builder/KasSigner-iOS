import Foundation

struct PortfolioCSVImportTransaction: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let type: PortfolioTransactionType
    let kasAmount: Double
    let kasPriceUSD: Double
    let feeUSD: Double
    let timestamp: Date
    let notes: String

    func fingerprint(portfolioID: UUID) -> String {
        PortfolioCSVImporter.fingerprint(
            portfolioID: portfolioID,
            type: type.rawValue,
            kasAmount: kasAmount,
            kasPriceUSD: kasPriceUSD,
            feeUSD: feeUSD,
            timestamp: timestamp,
            notes: notes
        )
    }
}

struct PortfolioCSVImportIssue: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let message: String
}

struct PortfolioCSVImportPreview: Identifiable {
    let id = UUID()
    let fileName: String
    let portfolioID: UUID
    let transactions: [PortfolioCSVImportTransaction]
    let duplicateCount: Int
    let issues: [PortfolioCSVImportIssue]
}

enum PortfolioCSVImporter {
    enum ImportError: LocalizedError {
        case numbersDocument
        case unreadableText
        case malformedCSV
        case missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .numbersDocument:
                "This is an Apple Numbers document, not a CSV. In Numbers, choose Export → CSV, then try again."
            case .unreadableText:
                "The selected file is not valid UTF-8 text."
            case .malformedCSV:
                "The selected file contains malformed CSV data."
            case .missingColumns(let columns):
                "Missing required columns: \(columns.joined(separator: ", "))."
            }
        }
    }

    private static let requiredColumns = [
        "Date (UTC-4:00)",
        "Token",
        "Type",
        "Price (USD)",
        "Amount",
        "Total value (USD)",
        "Fee",
        "Fee Currency",
        "Notes"
    ]

    static func preview(
        data: Data,
        fileName: String,
        portfolioID: UUID,
        existingTransactions: [PortfolioTransaction],
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> PortfolioCSVImportPreview {
        if isNumbersDocument(data) {
            throw ImportError.numbersDocument
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadableText
        }
        if text.hasPrefix("\u{feff}") {
            text.removeFirst()
        }
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let records = try parseRecords(text)
        guard let header = records.first else { throw ImportError.malformedCSV }
        var headerIndexes: [String: Int] = [:]
        for (index, value) in header.enumerated() {
            let normalized = normalizedHeader(value)
            guard headerIndexes[normalized] == nil else {
                throw ImportError.malformedCSV
            }
            headerIndexes[normalized] = index
        }
        let missingColumns = requiredColumns.filter {
            headerIndexes[normalizedHeader($0)] == nil
        }
        guard missingColumns.isEmpty else {
            throw ImportError.missingColumns(missingColumns)
        }

        let earliestDate = calendar.date(
            from: DateComponents(year: 2022, month: 6, day: 1)
        ) ?? .distantPast
        let bundledTransferPrices = (try? HistoricalPriceCacheStore.bundledCandles().map {
            HistoricalPricePoint(timestamp: $0.timestamp, priceUSD: $0.closeUSD)
        }) ?? []
        let existingForPortfolio = existingTransactions.filter { $0.portfolioID == portfolioID }
        var knownFingerprints = Set(existingForPortfolio.map(fingerprint))
        var parsedTransactions: [PortfolioCSVImportTransaction] = []
        var issues: [PortfolioCSVImportIssue] = []
        var duplicateCount = 0

        for (recordIndex, record) in records.dropFirst().enumerated() {
            let lineNumber = recordIndex + 2
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }

            do {
                let transaction = try parseTransaction(
                    record,
                    lineNumber: lineNumber,
                    headerIndexes: headerIndexes,
                    earliestDate: earliestDate,
                    now: now,
                    historicalPrices: bundledTransferPrices
                )
                let fingerprint = transaction.fingerprint(portfolioID: portfolioID)
                if knownFingerprints.contains(fingerprint) {
                    duplicateCount += 1
                } else {
                    knownFingerprints.insert(fingerprint)
                    parsedTransactions.append(transaction)
                }
            } catch let error as RowError {
                issues.append(PortfolioCSVImportIssue(
                    lineNumber: lineNumber,
                    message: error.message
                ))
            }
        }

        let validated = validateHoldings(
            parsedTransactions,
            existingTransactions: existingForPortfolio
        )
        issues.append(contentsOf: validated.issues)

        return PortfolioCSVImportPreview(
            fileName: fileName,
            portfolioID: portfolioID,
            transactions: validated.transactions,
            duplicateCount: duplicateCount,
            issues: issues.sorted { $0.lineNumber < $1.lineNumber }
        )
    }

    static func fingerprint(_ transaction: PortfolioTransaction) -> String {
        fingerprint(
            portfolioID: transaction.portfolioID,
            type: transaction.type,
            kasAmount: transaction.kasAmount,
            kasPriceUSD: transaction.kasPriceUSD,
            feeUSD: transaction.feeUSD,
            timestamp: transaction.timestamp,
            notes: transaction.notes
        )
    }

    static func fingerprint(
        portfolioID: UUID,
        type: String,
        kasAmount: Double,
        kasPriceUSD: Double,
        feeUSD: Double,
        timestamp: Date,
        notes: String
    ) -> String {
        [
            portfolioID.uuidString.lowercased(),
            type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), kasAmount),
            String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), kasPriceUSD),
            String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), feeUSD),
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), timestamp.timeIntervalSince1970),
            normalizedNotes(notes)
        ].joined(separator: "|")
    }

    private struct RowError: Error {
        let message: String
    }

    private struct ValidationEvent {
        let timestamp: Date
        let order: String
        let type: PortfolioTransactionType?
        let rawType: String
        let amount: Double
        let candidate: PortfolioCSVImportTransaction?
    }

    private static func parseTransaction(
        _ record: [String],
        lineNumber: Int,
        headerIndexes: [String: Int],
        earliestDate: Date,
        now: Date,
        historicalPrices: [HistoricalPricePoint]
    ) throws -> PortfolioCSVImportTransaction {
        func value(_ column: String) -> String {
            guard let index = headerIndexes[normalizedHeader(column)], record.indices.contains(index) else {
                return ""
            }
            return record[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard value("Token").uppercased() == "KAS" else {
            throw RowError(message: "Token must be KAS.")
        }
        guard let type = transactionType(value("Type")) else {
            throw RowError(message: "Unsupported transaction type.")
        }
        guard let amount = decimal(value("Amount")), amount > 0 else {
            throw RowError(message: "Amount must be greater than zero.")
        }
        guard let totalValue = decimal(value("Total value (USD)")), totalValue >= 0 else {
            throw RowError(message: "Total value is invalid.")
        }
        let feeText = value("Fee")
        guard let fee = feeText.isEmpty ? 0 : decimal(feeText), fee >= 0 else {
            throw RowError(message: "Fee must be zero or greater.")
        }
        guard let timestamp = transactionDate(value("Date (UTC-4:00)")) else {
            throw RowError(message: "Date must use yyyy-MM-dd HH:mm:ss.")
        }
        guard timestamp >= earliestDate else {
            throw RowError(message: "Date is before June 1, 2022.")
        }
        guard timestamp <= now else {
            throw RowError(message: "Date is in the future.")
        }
        let parsedPrice = decimal(value("Price (USD)")) ?? 0
        let totalDerivedPrice = totalValue > 0 ? totalValue / amount : 0
        let price: Double
        switch type {
        case .buy, .sell:
            guard totalValue > 0 || parsedPrice > 0 else {
                throw RowError(message: "Price must be greater than zero.")
            }
            price = parsedPrice > 0 ? parsedPrice : totalDerivedPrice
        case .transferIn, .transferOut:
            if parsedPrice > 0 {
                price = parsedPrice
            } else if totalValue > 0 {
                price = totalValue / amount
            } else {
                price = PortfolioChartBuilder.interpolatedPrice(
                    at: timestamp,
                    in: historicalPrices
                ) ?? 0
            }
        }
        let feeCurrency = value("Fee Currency").uppercased()
        if fee > 0.000_000_01 {
            guard feeCurrency == "USD" else {
                throw RowError(message: "Fee currency must be USD for a nonzero fee.")
            }
        }

        return PortfolioCSVImportTransaction(
            lineNumber: lineNumber,
            type: type,
            kasAmount: amount,
            kasPriceUSD: price,
            feeUSD: fee,
            timestamp: timestamp,
            notes: value("Notes")
        )
    }

    private static func validateHoldings(
        _ candidates: [PortfolioCSVImportTransaction],
        existingTransactions: [PortfolioTransaction]
    ) -> (transactions: [PortfolioCSVImportTransaction], issues: [PortfolioCSVImportIssue]) {
        var events = existingTransactions.map { transaction in
            ValidationEvent(
                timestamp: transaction.timestamp,
                order: "0-\(transaction.createdAt.timeIntervalSince1970)-\(transaction.id.uuidString)",
                type: PortfolioTransactionType(rawValue: transaction.type),
                rawType: transaction.type,
                amount: transaction.kasAmount,
                candidate: nil
            )
        }
        events.append(contentsOf: candidates.map { transaction in
            ValidationEvent(
                timestamp: transaction.timestamp,
                order: String(format: "1-%09d", transaction.lineNumber),
                type: transaction.type,
                rawType: transaction.type.rawValue,
                amount: transaction.kasAmount,
                candidate: transaction
            )
        })
        events.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.order < $1.order
        }

        var holdings = 0.0
        var acceptedIDs = Set<UUID>()
        var issues: [PortfolioCSVImportIssue] = []
        for event in events {
            switch event.type {
            case .buy, .transferIn:
                holdings += event.amount
                if let candidate = event.candidate { acceptedIDs.insert(candidate.id) }
            case .sell, .transferOut:
                if let candidate = event.candidate, event.amount > holdings + 0.000_000_01 {
                    issues.append(PortfolioCSVImportIssue(
                        lineNumber: candidate.lineNumber,
                        message: "Amount exceeds holdings at this date."
                    ))
                    continue
                }
                holdings = max(0, holdings - min(event.amount, holdings))
                if let candidate = event.candidate { acceptedIDs.insert(candidate.id) }
            case nil:
                if event.rawType == PortfolioTransactionType.buy.rawValue ||
                    event.rawType == PortfolioTransactionType.transferIn.rawValue {
                    holdings += event.amount
                } else if event.rawType == PortfolioTransactionType.sell.rawValue ||
                            event.rawType == PortfolioTransactionType.transferOut.rawValue {
                    holdings = max(0, holdings - min(event.amount, holdings))
                }
            }
        }

        return (
            candidates.filter { acceptedIDs.contains($0.id) },
            issues
        )
    }

    private static func transactionType(_ value: String) -> PortfolioTransactionType? {
        switch value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ") {
        case "buy": .buy
        case "sell": .sell
        case "transfer in", "transferin": .transferIn
        case "transfer out", "transferout": .transferOut
        default: nil
        }
    }

    private static func decimal(_ value: String) -> Double? {
        let normalized = value
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Decimal(
            string: normalized,
            locale: Locale(identifier: "en_US_POSIX")
        ) else { return nil }
        let result = NSDecimalNumber(decimal: number).doubleValue
        return result.isFinite ? result : nil
    }

    private static func transactionDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: -4 * 60 * 60)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    private static func normalizedHeader(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedNotes(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func isNumbersDocument(_ data: Data) -> Bool {
        let zipSignature = Data([0x50, 0x4b, 0x03, 0x04])
        let numbersDocumentEntry = Data("Index/Document.iwa".utf8)
        return data.starts(with: zipSignature) && data.range(of: numbersDocumentEntry) != nil
    }

    private static func parseRecords(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var isQuoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)

            if character == "\"" {
                if isQuoted, nextIndex < text.endIndex, text[nextIndex] == "\"" {
                    field.append("\"")
                    index = text.index(after: nextIndex)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                record.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !isQuoted {
                record.append(field)
                field = ""
                if !record.allSatisfy({ $0.isEmpty }) {
                    records.append(record)
                }
                record = []
                if character == "\r", nextIndex < text.endIndex, text[nextIndex] == "\n" {
                    index = text.index(after: nextIndex)
                    continue
                }
            } else {
                field.append(character)
            }
            index = nextIndex
        }

        guard !isQuoted else { throw ImportError.malformedCSV }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}
