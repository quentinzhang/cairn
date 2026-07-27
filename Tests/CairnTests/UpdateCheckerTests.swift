import Foundation
import Testing
@testable import Cairn

private enum StubReleaseError: Error {
    case unavailable
}

private struct StubReleaseClient: ReleaseChecking {
    let release: ReleaseDescriptor?

    func latestRelease() async throws -> ReleaseDescriptor {
        guard let release else { throw StubReleaseError.unavailable }
        return release
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "CairnTests.UpdateChecker.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private let newerRelease = ReleaseDescriptor(
    tag: "v0.7.0",
    releaseURL: URL(string: "https://github.com/quentinzhang/cairn/releases/tag/v0.7.0")!
)

@Test @MainActor
func manualCheckFindsAndPersistsAnUpdate() async {
    let defaults = isolatedDefaults()
    let checker = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" }
    )

    await checker.checkNow()?.value

    #expect(checker.available?.version == "0.7.0")
    #expect(checker.status == .idle)
    #expect(defaults.object(forKey: "cairn.update.lastCheckDate") as? Date != nil)

    let relaunched = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" }
    )
    #expect(relaunched.available == checker.available)
}

@Test @MainActor
func manualCheckReportsUpToDateAndFailureStates() async {
    let upToDate = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: isolatedDefaults(),
        currentVersion: { "0.7.0" }
    )
    await upToDate.checkNow()?.value
    #expect(upToDate.available == nil)
    #expect(upToDate.status == .upToDate)

    let failed = UpdateChecker(
        client: StubReleaseClient(release: nil),
        preferences: isolatedDefaults(),
        currentVersion: { "0.6.3" }
    )
    await failed.checkNow()?.value
    #expect(failed.available == nil)
    #expect(failed.status == .failed)
}

@Test @MainActor
func skipPersistsButAnExplicitCheckCanRevealTheVersionAgain() async {
    let defaults = isolatedDefaults()
    let checker = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" }
    )
    await checker.checkNow()?.value
    let update = try! #require(checker.available)

    checker.skip(update)
    #expect(checker.available == nil)

    let relaunched = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" }
    )
    #expect(relaunched.available == nil)

    await relaunched.checkNow()?.value
    #expect(relaunched.available?.version == "0.7.0")
}
