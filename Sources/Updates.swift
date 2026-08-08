import Foundation

/// как часто приложение само спрашивает GitHub о новой версии
enum UpdateInterval: String, CaseIterable, Identifiable {
    case never
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    /// nil означает, что сама по себе проверка не запускается
    var period: TimeInterval? {
        switch self {
        case .never: return nil
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        case .monthly: return 30 * 24 * 3600
        }
    }

    var title: String {
        switch self {
        case .never: return String(localized: "Never")
        case .daily: return String(localized: "Every day")
        case .weekly: return String(localized: "Every week")
        case .monthly: return String(localized: "Every month")
        }
    }
}

struct AppRelease: Equatable, Sendable {
    let version: String
    let url: URL
}

enum UpdateError: LocalizedError {
    case httpStatus(Int)
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code) where code == 404:
            return String(localized: "GitHub has no public releases for this app yet")
        case let .httpStatus(code):
            return String(format: String(localized: "GitHub answered with status %lld"), code)
        case .malformedPayload:
            return String(localized: "GitHub answered with something that is not a release")
        }
    }
}

private let latestReleaseURL = URL(
    string: "https://api.github.com/repos/boundlessend/subvenio-screen/releases/latest"
)!

func currentAppVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}

/// числа версии по порядку. ведущая "v" тега и хвосты вроде "-beta" отбрасываются
func versionNumbers(_ version: String) -> [Int] {
    version
        .drop(while: { !$0.isNumber })
        .split(separator: ".")
        .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
}

/// сравнение по компонентам, а не строкой: иначе "1.10.0" оказалось бы старше "1.9.0"
func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    let left = versionNumbers(candidate)
    let right = versionNumbers(current)
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? left[index] : 0
        let b = index < right.count ? right[index] : 0
        if a != b { return a > b }
    }
    return false
}

private struct ReleasePayload: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// последний релиз репозитория. приватный репозиторий без токена отдаёт 404,
/// поэтому до публикации исходников проверка честно сообщает, что релизов не видно
func fetchLatestRelease() async throws -> AppRelease {
    var request = URLRequest(url: latestReleaseURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw UpdateError.malformedPayload
    }
    guard http.statusCode == 200 else {
        throw UpdateError.httpStatus(http.statusCode)
    }
    guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data),
          let url = URL(string: payload.htmlURL) else {
        throw UpdateError.malformedPayload
    }
    // тег в интерфейсе показывать незачем: "v1.2.0" читается как опечатка рядом с "1.1.0"
    let version = payload.tagName.drop(while: { !$0.isNumber })
    return AppRelease(version: String(version), url: url)
}

/// проверка обновлений через страницу релизов GitHub: ни загрузки, ни установки,
/// приложение только сообщает о версии и открывает страницу в браузере
@MainActor
final class UpdateController: ObservableObject {
    private static let intervalKey = "updates.interval"
    private static let lastCheckKey = "updates.lastCheck"

    @Published private(set) var available: AppRelease?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var isChecking = false
    /// текст последней неудачи, показывается только там, где проверку просили руками
    @Published private(set) var lastError: String?

    @Published var interval: UpdateInterval {
        didSet {
            guard interval != oldValue else { return }
            UserDefaults.standard.set(interval.rawValue, forKey: Self.intervalKey)
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.intervalKey)
        interval = stored.flatMap(UpdateInterval.init(rawValue:)) ?? .weekly
        let storedCheck = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        lastCheck = storedCheck > 0 ? Date(timeIntervalSince1970: storedCheck) : nil
    }

    /// плановая проверка: молчит в интерфейсе и пишет неудачи только в лог,
    /// потому что о сетевой ошибке фонового опроса пользователя будить незачем
    func checkIfDue() async {
        guard let period = interval.period else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < period { return }
        do {
            try await check()
        } catch {
            Log.updates.error("scheduled check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// ручная проверка: ошибку видно, потому что её попросили
    func checkNow() async {
        do {
            try await check()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func check() async throws {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        let release = try await fetchLatestRelease()
        let current = currentAppVersion()
        available = isVersion(release.version, newerThan: current) ? release : nil
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck?.timeIntervalSince1970, forKey: Self.lastCheckKey)
        Log.updates.info(
            "checked: latest \(release.version, privacy: .public), running \(current, privacy: .public)"
        )
    }
}
