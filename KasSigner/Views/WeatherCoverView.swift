import SwiftUI

private enum WeatherCoverKey {
    static let enabled = "kassigner.security.decoyLaunchScreenEnabled"
    static let cityName = "kassigner.weather.cityName"
    static let latitude = "kassigner.weather.latitude"
    static let longitude = "kassigner.weather.longitude"
    static let temperatureUnit = "kassigner.weather.temperatureUnit"
    static let unlockTarget = "kassigner.weather.unlockTarget"
    static let unlockTapCount = "kassigner.weather.unlockTapCount"
    static let cachedSnapshot = "kassigner.weather.cachedSnapshot"
}

private enum WeatherUnlockTarget: String, CaseIterable, Identifiable {
    case conditionIcon
    case temperature
    case location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conditionIcon: "Weather Icon"
        case .temperature: "Temperature"
        case .location: "City Name"
        }
    }
}

private struct WeatherSnapshot: Codable {
    struct Day: Codable, Identifiable {
        let date: Date
        let high: Double
        let low: Double
        let weatherCode: Int

        var id: Date { date }
    }

    let temperature: Double
    let apparentTemperature: Double
    let weatherCode: Int
    let windSpeed: Double
    let daily: [Day]
    let updatedAt: Date
    let latitude: Double
    let longitude: Double
    let temperatureUnit: String
}

private struct WeatherLocation: Identifiable, Hashable {
    let id: Int
    let name: String
    let region: String?
    let country: String
    let latitude: Double
    let longitude: Double

    var displayName: String {
        [name, region, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

@MainActor
private final class WeatherCoverModel: ObservableObject {
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    @Published private(set) var searchResults: [WeatherLocation] = []
    @Published private(set) var isSearching = false

    private let defaults = UserDefaults.standard
    private var latestSearchID = UUID()

    init() {
        if let data = defaults.data(forKey: WeatherCoverKey.cachedSnapshot),
           let cached = try? JSONDecoder.weather.decode(WeatherSnapshot.self, from: data) {
            let savedLatitude = defaults.object(forKey: WeatherCoverKey.latitude) as? Double ?? 40.7128
            let savedLongitude = defaults.object(forKey: WeatherCoverKey.longitude) as? Double ?? -74.0060
            let savedUnit = defaults.string(forKey: WeatherCoverKey.temperatureUnit) ?? "fahrenheit"
            if abs(cached.latitude - savedLatitude) < 0.000_001,
               abs(cached.longitude - savedLongitude) < 0.000_001,
               cached.temperatureUnit == savedUnit {
                snapshot = cached
            } else {
                defaults.removeObject(forKey: WeatherCoverKey.cachedSnapshot)
            }
        }
    }

    func refresh(latitude: Double, longitude: Double, fahrenheit: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        message = nil
        defer { isRefreshing = false }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "6")
        ]

        guard let url = components?.url else {
            message = "Weather is temporarily unavailable."
            return
        }

        do {
            let (data, response) = try await fetch(url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(ForecastResponse.self, from: data)
            let count = [
                payload.daily.time.count,
                payload.daily.weatherCode.count,
                payload.daily.maximum.count,
                payload.daily.minimum.count
            ].min() ?? 0
            let days = (0..<count).compactMap { index -> WeatherSnapshot.Day? in
                guard let date = DateFormatter.weatherDay.date(from: payload.daily.time[index]) else { return nil }
                return .init(
                    date: date,
                    high: payload.daily.maximum[index],
                    low: payload.daily.minimum[index],
                    weatherCode: payload.daily.weatherCode[index]
                )
            }
            let newSnapshot = WeatherSnapshot(
                temperature: payload.current.temperature,
                apparentTemperature: payload.current.apparentTemperature,
                weatherCode: payload.current.weatherCode,
                windSpeed: payload.current.windSpeed,
                daily: days,
                updatedAt: Date(),
                latitude: latitude,
                longitude: longitude,
                temperatureUnit: fahrenheit ? "fahrenheit" : "celsius"
            )
            guard newSnapshot.temperature.isFinite,
                  newSnapshot.apparentTemperature.isFinite,
                  newSnapshot.windSpeed.isFinite,
                  newSnapshot.daily.allSatisfy({ $0.high.isFinite && $0.low.isFinite }) else {
                throw URLError(.cannotParseResponse)
            }
            snapshot = newSnapshot
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            defaults.set(try encoder.encode(newSnapshot), forKey: WeatherCoverKey.cachedSnapshot)
        } catch {
            message = snapshot == nil
                ? "Weather is temporarily unavailable."
                : "Unable to refresh. Showing the last update."
        }
    }

    func searchCities(_ query: String) async {
        let searchID = UUID()
        latestSearchID = searchID
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        defer {
            if latestSearchID == searchID {
                isSearching = false
            }
        }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: cleaned),
            URLQueryItem(name: "count", value: "12"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return }

        do {
            let (data, response) = try await fetch(url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(GeocodingResponse.self, from: data)
            guard latestSearchID == searchID else { return }
            searchResults = (payload.results ?? []).compactMap {
                guard (-90...90).contains($0.latitude),
                      (-180...180).contains($0.longitude) else { return nil }
                return WeatherLocation(
                    id: $0.id,
                    name: $0.name,
                    region: $0.admin1,
                    country: $0.country,
                    latitude: $0.latitude,
                    longitude: $0.longitude
                )
            }
        } catch {
            if latestSearchID == searchID {
                searchResults = []
            }
        }
    }

    func clearCache() {
        snapshot = nil
        message = nil
        defaults.removeObject(forKey: WeatherCoverKey.cachedSnapshot)
    }

    private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= 1_000_000 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return (data, response)
    }
}

struct WeatherCoverView: View {
    @StateObject private var model = WeatherCoverModel()
    @AppStorage(WeatherCoverKey.cityName) private var cityName = "New York"
    @AppStorage(WeatherCoverKey.latitude) private var latitude = 40.7128
    @AppStorage(WeatherCoverKey.longitude) private var longitude = -74.0060
    @AppStorage(WeatherCoverKey.temperatureUnit) private var temperatureUnit = "fahrenheit"
    @AppStorage(WeatherCoverKey.unlockTarget) private var unlockTarget = WeatherUnlockTarget.conditionIcon.rawValue
    @AppStorage(WeatherCoverKey.unlockTapCount) private var unlockTapCount = 3
    @State private var showingSettings = false
    @State private var tapSequenceCount = 0
    @State private var tapSequenceID = UUID()
    @State private var tapEvaluationTask: Task<Void, Never>?
    @State private var isUnlockRequestInFlight = false

    let requestUnlock: () async -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.blue.opacity(0.72), Color.cyan.opacity(0.32), Color(uiColor: .systemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        locationHeader
                        currentConditions
                        forecastCard
                        updateStatus
                        Link("Weather data by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
                .refreshable { await refresh() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Weather settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                WeatherSettingsView(model: model) {
                    showingSettings = false
                }
            }
            .task { await refresh() }
            .onChange(of: temperatureUnit) { _, _ in
                model.clearCache()
                Task { await refresh() }
            }
        }
        .tint(.primary)
        .onDisappear { resetTapSequence() }
    }

    private var locationHeader: some View {
        VStack(spacing: 5) {
            Text(cityName)
                .font(.title2.weight(.semibold))
                .contentShape(Rectangle())
                .onTapGesture {
                    recordTap(on: .location)
                }
            Text(Date.now.formatted(date: .complete, time: .omitted))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    private var currentConditions: some View {
        VStack(spacing: 12) {
            Image(systemName: weatherSymbol(model.snapshot?.weatherCode))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 92, weight: .light))
                .contentShape(Rectangle())
                .onTapGesture {
                    recordTap(on: .conditionIcon)
                }

            Text(temperature(model.snapshot?.temperature))
                .font(.system(size: 72, weight: .thin, design: .rounded))
                .contentShape(Rectangle())
                .onTapGesture {
                    recordTap(on: .temperature)
                }

            Text(conditionName(model.snapshot?.weatherCode))
                .font(.title3.weight(.medium))

            if let snapshot = model.snapshot {
                Text("Feels like \(temperature(snapshot.apparentTemperature))  •  Wind \(Int(snapshot.windSpeed.rounded())) \(isFahrenheit ? "mph" : "km/h")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("6-DAY FORECAST")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let days = model.snapshot?.daily, !days.isEmpty {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    if index > 0 { Divider() }
                    HStack {
                        Text(index == 0 ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .frame(width: 54, alignment: .leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: weatherSymbol(day.weatherCode))
                            .symbolRenderingMode(.multicolor)
                            .frame(maxWidth: .infinity)
                        Text("\(Int(day.low.rounded()))°")
                            .foregroundStyle(.secondary)
                        Text("\(Int(day.high.rounded()))°")
                            .frame(width: 38, alignment: .trailing)
                    }
                    .font(.body.weight(.medium))
                }
            } else if model.isRefreshing {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("Forecast unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var updateStatus: some View {
        if model.isRefreshing {
            Label("Updating weather…", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let message = model.message {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        } else if let updatedAt = model.snapshot?.updatedAt {
            Text("Updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var target: WeatherUnlockTarget {
        WeatherUnlockTarget(rawValue: unlockTarget) ?? .conditionIcon
    }

    private var isFahrenheit: Bool { temperatureUnit == "fahrenheit" }

    private func refresh() async {
        await model.refresh(latitude: latitude, longitude: longitude, fahrenheit: isFahrenheit)
    }

    private var requiredTapCount: Int {
        min(max(unlockTapCount, 2), 7)
    }

    private func recordTap(on tappedTarget: WeatherUnlockTarget) {
        guard target == tappedTarget, !isUnlockRequestInFlight else { return }

        tapSequenceCount += 1
        let sequenceID = UUID()
        tapSequenceID = sequenceID
        tapEvaluationTask?.cancel()
        tapEvaluationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }

            guard tapSequenceID == sequenceID else { return }
            let completedCount = tapSequenceCount
            resetTapSequence()
            guard completedCount == requiredTapCount else { return }

            isUnlockRequestInFlight = true
            await requestUnlock()
            isUnlockRequestInFlight = false
        }
    }

    private func resetTapSequence() {
        tapEvaluationTask?.cancel()
        tapEvaluationTask = nil
        tapSequenceCount = 0
        tapSequenceID = UUID()
    }

    private func temperature(_ value: Double?) -> String {
        guard let value else { return "--°" }
        return "\(Int(value.rounded()))°"
    }
}

private struct WeatherSettingsView: View {
    @EnvironmentObject private var appLockService: AppLockService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WeatherCoverModel
    @AppStorage(WeatherCoverKey.enabled) private var decoyEnabled = false
    @AppStorage(WeatherCoverKey.cityName) private var cityName = "New York"
    @AppStorage(WeatherCoverKey.latitude) private var latitude = 40.7128
    @AppStorage(WeatherCoverKey.longitude) private var longitude = -74.0060
    @AppStorage(WeatherCoverKey.temperatureUnit) private var temperatureUnit = "fahrenheit"
    @State private var query = ""
    @State private var showingCitySearch = false
    @State private var showingResetConfirmation = false

    let close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    Button {
                        showingCitySearch = true
                    } label: {
                        LabeledContent("City", value: cityName)
                    }
                    .foregroundStyle(.primary)

                    Picker("Temperature", selection: $temperatureUnit) {
                        Text("Fahrenheit").tag("fahrenheit")
                        Text("Celsius").tag("celsius")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("Refresh Weather") {
                        Task {
                            await model.refresh(
                                latitude: latitude,
                                longitude: longitude,
                                fahrenheit: temperatureUnit == "fahrenheit"
                            )
                        }
                    }
                }

                Section {
                    Button("Reset Weather App", role: .destructive) {
                        showingResetConfirmation = true
                    }
                } footer: {
                    Text("Clears saved weather information. The app itself can be removed from the Home Screen.")
                }
            }
            .navigationTitle("Weather Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }
                }
            }
            .sheet(isPresented: $showingCitySearch) {
                CitySearchView(model: model) { location in
                    model.clearCache()
                    cityName = location.name
                    latitude = location.latitude
                    longitude = location.longitude
                    showingCitySearch = false
                    Task {
                        await model.refresh(
                            latitude: location.latitude,
                            longitude: location.longitude,
                            fahrenheit: temperatureUnit == "fahrenheit"
                        )
                    }
                }
            }
            .confirmationDialog(
                "Reset weather information?",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Weather App", role: .destructive) {
                    Task {
                        guard await appLockService.authorizePrivacyCoverChange() else { return }
                        model.clearCache()
                        UserDefaults.standard.removeObject(forKey: WeatherCoverKey.cityName)
                        UserDefaults.standard.removeObject(forKey: WeatherCoverKey.latitude)
                        UserDefaults.standard.removeObject(forKey: WeatherCoverKey.longitude)
                        decoyEnabled = false
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears saved cities and weather data after authentication.")
            }
        }
    }
}

private struct CitySearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WeatherCoverModel
    @State private var query = ""

    let select: (WeatherLocation) -> Void

    var body: some View {
        NavigationStack {
            List(model.searchResults) { location in
                Button {
                    select(location)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(location.name).font(.headline)
                        Text(location.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if model.isSearching {
                    ProgressView()
                } else if query.count >= 2 && model.searchResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Choose City")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "City or postal code")
            .onChange(of: query) { _, newValue in
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, query == newValue else { return }
                    await model.searchCities(newValue)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct DecoyLaunchSettingsView: View {
    @EnvironmentObject private var appLockService: AppLockService
    @AppStorage(WeatherCoverKey.enabled) private var enabled = false
    @AppStorage(WeatherCoverKey.unlockTarget) private var unlockTarget = WeatherUnlockTarget.conditionIcon.rawValue
    @AppStorage(WeatherCoverKey.unlockTapCount) private var unlockTapCount = 3
    @State private var toggleValue = false

    var body: some View {
        Form {
            Section {
                Toggle("Weather Cover", isOn: $toggleValue)
                    .disabled(appLockService.isAuthenticating || !appLockService.isEnabled)
                    .onChange(of: toggleValue) { oldValue, newValue in
                        guard oldValue != newValue, newValue != enabled else { return }
                        Task {
                            if await appLockService.authorizePrivacyCoverChange() {
                                appLockService.suspendPrivacyCoverForCurrentSession()
                                enabled = newValue
                            } else {
                                toggleValue = enabled
                            }
                        }
                    }
            } footer: {
                if appLockService.isEnabled {
                    Text("When enabled, KasSigner opens to a functional weather screen.")
                } else {
                    Text("Turn on Face ID in Security before enabling Weather Cover.")
                }
            }

            if enabled {
                Section {
                    Picker("Tap", selection: $unlockTarget) {
                        ForEach(WeatherUnlockTarget.allCases) { target in
                            Text(target.title).tag(target.rawValue)
                        }
                    }
                    Picker("Number of Taps", selection: $unlockTapCount) {
                        ForEach(2...7, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                } header: {
                    Text("Unlock Gesture")
                } footer: {
                    Text("Tap the selected weather item the chosen number of times, then authenticate to open protected content.")
                }
            }
        }
        .navigationTitle("Decoy Launch")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !appLockService.isEnabled {
                enabled = false
            }
            toggleValue = enabled
        }
        .onChange(of: appLockService.isEnabled) { _, appLockEnabled in
            if !appLockEnabled {
                enabled = false
                toggleValue = false
            }
        }
    }
}

private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let apparentTemperature: Double
        let weatherCode: Int
        let windSpeed: Double

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case weatherCode = "weather_code"
            case windSpeed = "wind_speed_10m"
        }
    }

    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let maximum: [Double]
        let minimum: [Double]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case maximum = "temperature_2m_max"
            case minimum = "temperature_2m_min"
        }
    }

    let current: Current
    let daily: Daily
}

private struct GeocodingResponse: Decodable {
    struct Result: Decodable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String
        let admin1: String?
    }

    let results: [Result]?
}

private extension JSONDecoder {
    static var weather: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension DateFormatter {
    static let weatherDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private func weatherSymbol(_ code: Int?) -> String {
    guard let code else { return "cloud.fill" }
    return switch code {
    case 0: "sun.max.fill"
    case 1, 2: "cloud.sun.fill"
    case 3: "cloud.fill"
    case 45, 48: "cloud.fog.fill"
    case 51...57: "cloud.drizzle.fill"
    case 61...67, 80...82: "cloud.rain.fill"
    case 71...77, 85, 86: "cloud.snow.fill"
    case 95...99: "cloud.bolt.rain.fill"
    default: "cloud.fill"
    }
}

private func conditionName(_ code: Int?) -> String {
    guard let code else { return "Weather Unavailable" }
    return switch code {
    case 0: "Clear"
    case 1: "Mostly Clear"
    case 2: "Partly Cloudy"
    case 3: "Cloudy"
    case 45, 48: "Foggy"
    case 51...57: "Drizzle"
    case 61...67, 80...82: "Rain"
    case 71...77, 85, 86: "Snow"
    case 95...99: "Thunderstorms"
    default: "Weather Unavailable"
    }
}
