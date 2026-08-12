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

@MainActor
private final class RecordingAnnouncer: UpdateAnnouncing {
    private(set) var announcedVersions: [String] = []

    func announce(_ update: AppUpdate) async {
        announcedVersions.append(update.version)
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
    releaseURL: URL(string: "https://github.com/quentinzhang/cairn/releases/tag/v0.7.0")!,
    downloadURL: URL(string: "https://github.com/quentinzhang/cairn/releases/download/v0.7.0/Cairn-0.7.0.dmg")!
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
    #expect(checker.available?.downloadURL == newerRelease.downloadURL)
    // The click target is the DMG, exactly as the website's download button.
    #expect(checker.available?.installURL == newerRelease.downloadURL)
    #expect(checker.status == .idle)
    #expect(defaults.object(forKey: "cairn.update.lastCheckDate") as? Date != nil)

    let relaunched = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" }
    )
    #expect(relaunched.available == checker.available)
    // The download URL survives the relaunch, not just the version.
    #expect(relaunched.available?.downloadURL == newerRelease.downloadURL)
}

@Test @MainActor
func aReleaseWithoutADmgFallsBackToItsPage() async {
    let noDMG = ReleaseDescriptor(
        tag: "v0.7.0",
        releaseURL: URL(string: "https://github.com/quentinzhang/cairn/releases/tag/v0.7.0")!
    )
    let checker = UpdateChecker(
        client: StubReleaseClient(release: noDMG),
        preferences: isolatedDefaults(),
        currentVersion: { "0.6.3" }
    )
    await checker.checkNow()?.value

    #expect(checker.available?.downloadURL == nil)
    #expect(checker.available?.installURL == noDMG.releaseURL)
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

@Test @MainActor
func automaticDiscoveryAnnouncesAnUpdateOncePerVersion() async {
    let defaults = isolatedDefaults()
    let announcer = RecordingAnnouncer()
    let checker = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" },
        announcer: announcer
    )

    await checker.checkIfDue()?.value
    #expect(announcer.announcedVersions == ["0.7.0"])
    // Spending the version is the presenter's job, once it is actually drawn.
    checker.confirmAnnounced("0.7.0")

    defaults.removeObject(forKey: "cairn.update.lastCheckDate")
    await checker.checkIfDue()?.value
    #expect(announcer.announcedVersions == ["0.7.0"])
}

/// An announcement that never reached a screen is not spent. The check runs
/// from `CairnApp.init()`, so it can answer before the app has finished
/// launching, and onboarding can be holding every surface — if either counted
/// as announced, that version would never be seen at all.
@Test @MainActor
func anUnconfirmedAnnouncementIsTriedAgain() async {
    let defaults = isolatedDefaults()
    let announcer = RecordingAnnouncer()
    let checker = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" },
        announcer: announcer
    )

    await checker.checkIfDue()?.value
    #expect(announcer.announcedVersions == ["0.7.0"])

    // No confirmation: nothing drew it.
    defaults.removeObject(forKey: "cairn.update.lastCheckDate")
    await checker.checkIfDue()?.value
    #expect(announcer.announcedVersions == ["0.7.0", "0.7.0"])
}

/// A confirmation outlives the process — the whole reason it is a preference
/// and not a flag on the checker.
@Test @MainActor
func aConfirmedAnnouncementStaysSpentAcrossRelaunch() async {
    let defaults = isolatedDefaults()
    let first = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" },
        announcer: RecordingAnnouncer()
    )
    await first.checkIfDue()?.value
    first.confirmAnnounced("0.7.0")

    let announcer = RecordingAnnouncer()
    let relaunched = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" },
        announcer: announcer
    )
    defaults.removeObject(forKey: "cairn.update.lastCheckDate")
    await relaunched.checkIfDue()?.value
    #expect(announcer.announcedVersions.isEmpty)
}

/// The panel is the automatic path's job alone. A manual check already puts
/// the answer on screen — in the menu row and in Settings — so drawing a panel
/// on top of it would be Cairn interrupting a conversation it is already in.
@Test @MainActor
func aManualCheckNeverAnnouncesItself() async {
    let defaults = isolatedDefaults()
    let announcer = RecordingAnnouncer()
    let checker = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" },
        announcer: announcer
    )

    await checker.checkNow()?.value
    #expect(checker.available?.version == "0.7.0")
    #expect(announcer.announcedVersions.isEmpty)
}

/// A version the user has already turned down stays turned down: the panel is
/// once per version, and skipping is the stronger signal.
@Test @MainActor
func aSkippedVersionNeverAnnouncesItself() async {
    let defaults = isolatedDefaults()
    defaults.set("0.7.0", forKey: "cairn.update.skippedVersion")
    let announcer = RecordingAnnouncer()
    let checker = UpdateChecker(
        client: StubReleaseClient(release: newerRelease),
        preferences: defaults,
        currentVersion: { "0.6.3" },
        announcer: announcer
    )

    await checker.checkIfDue()?.value
    #expect(announcer.announcedVersions.isEmpty)
}
