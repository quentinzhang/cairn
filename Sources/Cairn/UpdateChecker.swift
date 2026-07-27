import Foundation

/// Polls GitHub Releases so Cairn never sits on a stale build indefinitely.
///
/// Checks are silent by design: a failed or offline check just tries again
/// next interval, and a found update surfaces as a dismissible row in the
/// menu bar list rather than an interruption.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var available: AppUpdate?

    private enum Config {
        static let repository = "everflyzhang/cairn"
        static let checkInterval: TimeInterval = 24 * 60 * 60
    }

    private enum PreferenceKey {
        static let lastCheckDate = "cairn.update.lastCheckDate"
        static let skippedVersion = "cairn.update.skippedVersion"
    }

    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Config.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }

        let preferences = UserDefaults.standard
        let lastCheck = preferences.object(forKey: PreferenceKey.lastCheckDate) as? Date
        guard lastCheck == nil || Date().timeIntervalSince(lastCheck!) >= Config.checkInterval else { return }
        check()
    }

    func skip(_ update: AppUpdate) {
        UserDefaults.standard.set(update.version, forKey: PreferenceKey.skippedVersion)
        if available == update {
            available = nil
        }
    }

    private func check() {
        Task { [weak self] in
            await self?.performCheck()
        }
    }

    private func performCheck() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Config.repository)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = payload["tag_name"] as? String,
              let releaseURLString = payload["html_url"] as? String,
              let releaseURL = URL(string: releaseURLString) else { return }

        UserDefaults.standard.set(Date(), forKey: PreferenceKey.lastCheckDate)

        let latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              latestVersion.isNewerVersion(than: currentVersion) else { return }

        guard UserDefaults.standard.string(forKey: PreferenceKey.skippedVersion) != latestVersion else { return }

        available = AppUpdate(version: latestVersion, releaseURL: releaseURL)
    }
}

struct AppUpdate: Equatable {
    let version: String
    let releaseURL: URL
}

private extension String {
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
