import Foundation

struct AppUpdate: Codable, Equatable, Sendable {
    let version: String
    let releaseURL: URL
}

struct ReleaseDescriptor: Equatable, Sendable {
    let tag: String
    let releaseURL: URL
}

protocol ReleaseChecking: Sendable {
    func latestRelease() async throws -> ReleaseDescriptor
}

struct GitHubReleaseClient: ReleaseChecking {
    private let session: URLSession
    private let endpoint: URL

    init(
        repository: String = "quentinzhang/cairn",
        session: URLSession = .shared
    ) {
        self.session = session
        endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    func latestRelease() async throws -> ReleaseDescriptor {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = payload["tag_name"] as? String,
              let releaseURLString = payload["html_url"] as? String,
              let releaseURL = URL(string: releaseURLString) else {
            throw ReleaseCheckError.invalidResponse
        }
        return ReleaseDescriptor(tag: tag, releaseURL: releaseURL)
    }
}

enum ReleaseCheckError: Error {
    case invalidResponse
}

enum UpdateCheckStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case failed
}

/// Polls GitHub Releases and also serves the user-initiated check in Cairn's
/// menu. A discovered update is persisted so relaunching during the 24-hour
/// cooldown cannot make the row disappear.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var available: AppUpdate?
    @Published private(set) var status: UpdateCheckStatus = .idle

    private enum Config {
        static let checkInterval: TimeInterval = 24 * 60 * 60
    }

    private enum PreferenceKey {
        static let lastCheckDate = "cairn.update.lastCheckDate"
        static let skippedVersion = "cairn.update.skippedVersion"
        static let availableVersion = "cairn.update.availableVersion"
        static let availableReleaseURL = "cairn.update.availableReleaseURL"
    }

    private let client: any ReleaseChecking
    private let preferences: UserDefaults
    private let currentVersion: @MainActor () -> String?
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var manualResultRequested = false

    init(
        client: any ReleaseChecking = GitHubReleaseClient(),
        preferences: UserDefaults = .standard,
        currentVersion: @escaping @MainActor () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        }
    ) {
        self.client = client
        self.preferences = preferences
        self.currentVersion = currentVersion
        available = Self.restoredUpdate(
            preferences: preferences,
            currentVersion: currentVersion()
        )
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Config.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        checkIfDue()
    }

    @discardableResult
    func checkNow() -> Task<Void, Never>? {
        startCheck(manual: true)
    }

    func skip(_ update: AppUpdate) {
        preferences.set(update.version, forKey: PreferenceKey.skippedVersion)
        if available == update {
            clearAvailableUpdate()
        }
        status = .idle
    }

    private func checkIfDue() {
        let lastCheck = preferences.object(forKey: PreferenceKey.lastCheckDate) as? Date
        guard lastCheck == nil
                || Date().timeIntervalSince(lastCheck!) >= Config.checkInterval else {
            return
        }
        startCheck(manual: false)
    }

    @discardableResult
    private func startCheck(manual: Bool) -> Task<Void, Never>? {
        if manual {
            status = .checking
            manualResultRequested = true
        }
        guard checkTask == nil else { return checkTask }

        let task = Task { [weak self] in
            await self?.performCheck(manualAtStart: manual)
            self?.manualResultRequested = false
            self?.checkTask = nil
        }
        checkTask = task
        return task
    }

    private func performCheck(manualAtStart: Bool) async {
        let release: ReleaseDescriptor
        do {
            release = try await client.latestRelease()
        } catch {
            status = manualAtStart || manualResultRequested ? .failed : .idle
            return
        }

        let presentsResult = manualAtStart || manualResultRequested
        preferences.set(Date(), forKey: PreferenceKey.lastCheckDate)
        let latestVersion = release.tag.hasPrefix("v")
            ? String(release.tag.dropFirst())
            : release.tag

        guard let currentVersion = currentVersion(),
              latestVersion.isNewerVersion(than: currentVersion) else {
            clearAvailableUpdate()
            status = presentsResult ? .upToDate : .idle
            return
        }

        let skippedVersion = preferences.string(forKey: PreferenceKey.skippedVersion)
        if !presentsResult, skippedVersion == latestVersion {
            clearAvailableUpdate()
            status = .idle
            return
        }

        if presentsResult, skippedVersion == latestVersion {
            preferences.removeObject(forKey: PreferenceKey.skippedVersion)
        }

        let update = AppUpdate(version: latestVersion, releaseURL: release.releaseURL)
        available = update
        preferences.set(update.version, forKey: PreferenceKey.availableVersion)
        preferences.set(update.releaseURL.absoluteString, forKey: PreferenceKey.availableReleaseURL)
        status = .idle
    }

    private func clearAvailableUpdate() {
        available = nil
        preferences.removeObject(forKey: PreferenceKey.availableVersion)
        preferences.removeObject(forKey: PreferenceKey.availableReleaseURL)
    }

    private static func restoredUpdate(
        preferences: UserDefaults,
        currentVersion: String?
    ) -> AppUpdate? {
        guard let version = preferences.string(forKey: PreferenceKey.availableVersion),
              let releaseURLString = preferences.string(
                forKey: PreferenceKey.availableReleaseURL
              ),
              let releaseURL = URL(string: releaseURLString),
              let currentVersion,
              version.isNewerVersion(than: currentVersion),
              preferences.string(forKey: PreferenceKey.skippedVersion) != version else {
            preferences.removeObject(forKey: PreferenceKey.availableVersion)
            preferences.removeObject(forKey: PreferenceKey.availableReleaseURL)
            return nil
        }
        return AppUpdate(version: version, releaseURL: releaseURL)
    }
}

extension String {
    /// Dotted version comparison ("0.10.0" outranks "0.9.0" — plain string
    /// comparison would get that backwards).
    func isNewerVersion(than other: String) -> Bool {
        let lhs = split(separator: ".").compactMap { Int($0) }
        let rhs = other.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
