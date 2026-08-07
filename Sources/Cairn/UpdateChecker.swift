import Foundation

struct AppUpdate: Codable, Equatable, Sendable {
    let version: String
    let releaseURL: URL
    /// The signed, notarized DMG to download directly, when the release
    /// carries one. Absent for older releases or a release without a DMG.
    let downloadURL: URL?

    init(version: String, releaseURL: URL, downloadURL: URL? = nil) {
        self.version = version
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
    }

    /// Where a click should send someone who wants the update: straight to the
    /// DMG when there is one, exactly as the website's download button does, and
    /// otherwise the release page as a dependable fallback.
    var installURL: URL { downloadURL ?? releaseURL }
}

struct ReleaseDescriptor: Equatable, Sendable {
    let tag: String
    let releaseURL: URL
    let downloadURL: URL?

    init(tag: String, releaseURL: URL, downloadURL: URL? = nil) {
        self.tag = tag
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
    }
}

protocol ReleaseChecking: Sendable {
    func latestRelease() async throws -> ReleaseDescriptor
}

/// How a found update reaches the person. Behind this small boundary so the
/// checker can promise exactly one announcement per version without its tests
/// having to draw anything.
@MainActor
protocol UpdateAnnouncing {
    func announce(_ update: AppUpdate) async
}

enum CairnUpdateAnnouncement {
    /// The `AppUpdate` carried on `.cairnUpdateDidArrive`.
    static let updateKey = "update"
}

/// Cairn announces its own update the way it announces everything else: by
/// drawing its own panel beside the stones.
///
/// Deliberately **not** a system notification. The queue asks macOS for no
/// privacy permission at all — that is the claim in SECURITY.md and the first
/// line of every README — and the app's own version number is not the reason
/// to start asking. A panel Cairn draws itself also cannot take the keyboard,
/// which a banner with a button can.
@MainActor
struct PanelUpdateAnnouncer: UpdateAnnouncing {
    func announce(_ update: AppUpdate) async {
        NotificationCenter.default.post(
            name: .cairnUpdateDidArrive,
            object: nil,
            userInfo: [CairnUpdateAnnouncement.updateKey: update]
        )
    }
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
        return ReleaseDescriptor(
            tag: tag,
            releaseURL: releaseURL,
            downloadURL: Self.dmgDownloadURL(in: payload["assets"])
        )
    }

    /// The release's signed DMG, addressed the same way the website's download
    /// button finds it: the first asset whose name ends in `.dmg`, taken by its
    /// `browser_download_url`. Nil when a release ships no DMG.
    private static func dmgDownloadURL(in assets: Any?) -> URL? {
        guard let assets = assets as? [[String: Any]] else { return nil }
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name.lowercased().hasSuffix(".dmg"),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else {
                continue
            }
            return url
        }
        return nil
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
    static let shared = UpdateChecker()

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
        static let availableDownloadURL = "cairn.update.availableDownloadURL"
        static let announcedVersion = "cairn.update.announcedVersion"
    }

    private let client: any ReleaseChecking
    private let preferences: UserDefaults
    private let currentVersion: @MainActor () -> String?
    private let announcer: any UpdateAnnouncing
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var manualResultRequested = false

    init(
        client: any ReleaseChecking = GitHubReleaseClient(),
        preferences: UserDefaults = .standard,
        currentVersion: @escaping @MainActor () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        },
        announcer: any UpdateAnnouncing = PanelUpdateAnnouncer()
    ) {
        self.client = client
        self.preferences = preferences
        self.currentVersion = currentVersion
        self.announcer = announcer
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
        _ = checkIfDue()
    }

    @discardableResult
    func checkNow() -> Task<Void, Never>? {
        startCheck(manual: true)
    }

    /// The announcement reached a screen. Called by whoever drew it, which is
    /// the only place that knows it actually happened.
    ///
    /// This is what makes an announcement once-per-version rather than
    /// once-per-attempt: until it is confirmed, the next automatic check is
    /// free to try again — including after a relaunch, since an attempt that
    /// died with the process left nothing behind.
    func confirmAnnounced(_ version: String) {
        preferences.set(version, forKey: PreferenceKey.announcedVersion)
    }

    func skip(_ update: AppUpdate) {
        preferences.set(update.version, forKey: PreferenceKey.skippedVersion)
        if available == update {
            clearAvailableUpdate()
        }
        status = .idle
    }

    @discardableResult
    func checkIfDue() -> Task<Void, Never>? {
        let lastCheck = preferences.object(forKey: PreferenceKey.lastCheckDate) as? Date
        guard lastCheck == nil
                || Date().timeIntervalSince(lastCheck!) >= Config.checkInterval else {
            return nil
        }
        return startCheck(manual: false)
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

        let update = AppUpdate(
            version: latestVersion,
            releaseURL: release.releaseURL,
            downloadURL: release.downloadURL
        )
        available = update
        preferences.set(update.version, forKey: PreferenceKey.availableVersion)
        preferences.set(update.releaseURL.absoluteString, forKey: PreferenceKey.availableReleaseURL)
        if let downloadURL = update.downloadURL {
            preferences.set(downloadURL.absoluteString, forKey: PreferenceKey.availableDownloadURL)
        } else {
            preferences.removeObject(forKey: PreferenceKey.availableDownloadURL)
        }
        if !presentsResult,
           preferences.string(forKey: PreferenceKey.announcedVersion) != latestVersion {
            // Only on the automatic path: a manual check already put the
            // answer on screen, and drawing a panel over it would be Cairn
            // interrupting a conversation it is already in.
            //
            // Nothing is recorded here. The announcement can still fail to
            // land — the app may not have finished launching, or onboarding
            // may still be holding the surfaces — and a version marked as
            // announced before it appeared is a version that never appears.
            // `confirmAnnounced` closes the loop from wherever it lands.
            await announcer.announce(update)
        }
        status = .idle
    }

    private func clearAvailableUpdate() {
        available = nil
        preferences.removeObject(forKey: PreferenceKey.availableVersion)
        preferences.removeObject(forKey: PreferenceKey.availableReleaseURL)
        preferences.removeObject(forKey: PreferenceKey.availableDownloadURL)
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
            preferences.removeObject(forKey: PreferenceKey.availableDownloadURL)
            return nil
        }
        let downloadURL = preferences.string(forKey: PreferenceKey.availableDownloadURL)
            .flatMap(URL.init(string:))
        return AppUpdate(version: version, releaseURL: releaseURL, downloadURL: downloadURL)
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
