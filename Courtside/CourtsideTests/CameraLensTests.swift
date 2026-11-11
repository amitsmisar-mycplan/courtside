import AVFoundation
import SwiftData
import XCTest
@testable import Courtside

/// Lens choice for recording (decision 0026). The Simulator has no camera, so these cover the
/// selection logic, the fallback when a lens is missing, and remembering the choice.
@MainActor
final class CameraLensTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var container: ModelContainer!
    private var service: FakeRecordingService!

    override func setUp() async throws {
        suiteName = "CameraLensTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        container = try ModelContainer(for: Game.self, Mark.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        service = FakeRecordingService()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func readySession() async -> RecordingSession {
        let session = RecordingSession(service: service, context: container.mainContext, freeSpace: { 50_000_000_000 }, defaults: defaults)
        await session.prepare(preflight: [])
        return session
    }

    // MARK: Choosing a lens

    func testDefaultsToUltraWideWhenThePhoneHasIt() {
        XCTAssertEqual(LensSettings.choose(saved: nil, available: [.ultraWide, .wide]), .ultraWide)
    }

    func testDefaultsToMainCameraWithoutUltraWide() {
        XCTAssertEqual(LensSettings.choose(saved: nil, available: [.wide]), .wide)
    }

    func testSavedChoiceWinsWhenAvailable() {
        XCTAssertEqual(LensSettings.choose(saved: .wide, available: [.ultraWide, .wide]), .wide)
        XCTAssertEqual(LensSettings.choose(saved: .ultraWide, available: [.ultraWide, .wide]), .ultraWide)
    }

    func testSavedUltraWideFallsBackToMainCameraWhenMissing() {
        XCTAssertEqual(LensSettings.choose(saved: .ultraWide, available: [.wide]), .wide)
    }

    func testSavedMainCameraFallsBackToUltraWideWhenMissing() {
        XCTAssertEqual(LensSettings.choose(saved: .wide, available: [.ultraWide]), .ultraWide)
    }

    func testNoCameraGivesNoLens() {
        XCTAssertNil(LensSettings.choose(saved: .ultraWide, available: []))
        XCTAssertNil(LensSettings.choose(saved: nil, available: []))
    }

    func testDeviceTypesMapToLensesWidestFirst() {
        XCTAssertEqual(CaptureSessionController.lenses(forDeviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera]), [.ultraWide, .wide])
        XCTAssertEqual(CaptureSessionController.lenses(forDeviceTypes: [.builtInWideAngleCamera]), [.wide])
        XCTAssertEqual(CaptureSessionController.lenses(forDeviceTypes: [.builtInTelephotoCamera]), [])
        XCTAssertEqual(CaptureSessionController.deviceType(for: .ultraWide), .builtInUltraWideCamera)
        XCTAssertEqual(CaptureSessionController.deviceType(for: .wide), .builtInWideAngleCamera)
    }

    func testLabelsMatchTheCameraApp() {
        XCTAssertEqual(CameraLens.ultraWide.label, "0.5×")
        XCTAssertEqual(CameraLens.wide.label, "1×")
    }

    // MARK: Remembering the choice

    func testChoiceIsRememberedAcrossLaunches() {
        XCTAssertNil(LensSettings.saved(in: defaults))
        LensSettings.save(.wide, in: defaults)
        // A new launch reads the same defaults.
        let reopened = UserDefaults(suiteName: suiteName)!
        XCTAssertEqual(LensSettings.saved(in: reopened), .wide)
        LensSettings.save(.ultraWide, in: reopened)
        XCTAssertEqual(LensSettings.saved(in: defaults), .ultraWide)
    }

    func testUnknownStoredValueCountsAsNoChoice() {
        defaults.set("telephoto", forKey: LensSettings.key)
        XCTAssertNil(LensSettings.saved(in: defaults))
    }

    // MARK: The record screen's session

    func testPrepareOpensUltraWideByDefault() async {
        let session = await readySession()
        XCTAssertEqual(service.preferredLensAsked, .some(nil))
        XCTAssertEqual(session.lens, .ultraWide)
        XCTAssertEqual(session.availableLenses, [.ultraWide, .wide])
        XCTAssertTrue(session.canChooseLens)
    }

    func testPrepareAsksForTheSavedLens() async {
        LensSettings.save(.wide, in: defaults)
        let session = await readySession()
        XCTAssertEqual(service.preferredLensAsked, .some(.wide))
        XCTAssertEqual(session.lens, .wide)
    }

    func testSavedUltraWideOnAPhoneWithoutOneOpensMainCamera() async {
        LensSettings.save(.ultraWide, in: defaults)
        service.lensesOnPhone = [.wide]
        let session = await readySession()
        XCTAssertEqual(session.lens, .wide)
        XCTAssertFalse(session.canChooseLens, "nothing to choose with one lens")
        XCTAssertEqual(LensSettings.saved(in: defaults), .ultraWide, "the choice is kept for a phone that has it")
    }

    func testSwitchingBeforeRecordingChangesAndRemembers() async {
        let session = await readySession()
        await session.selectLens(.wide)
        XCTAssertEqual(service.selectedLenses, [.wide])
        XCTAssertEqual(session.lens, .wide)
        XCTAssertEqual(LensSettings.saved(in: defaults), .wide)
        XCTAssertFalse(session.isSwitchingLens)
        XCTAssertTrue(session.canStart)
    }

    func testSelectingTheCurrentLensDoesNothing() async {
        let session = await readySession()
        await session.selectLens(.ultraWide)
        XCTAssertEqual(service.selectedLenses, [])
        XCTAssertNil(LensSettings.saved(in: defaults))
    }

    func testLensIsLockedWhileRecording() async {
        let session = await readySession()
        await session.start()
        XCTAssertEqual(session.phase, .recording)
        XCTAssertFalse(session.canChooseLens)
        await session.selectLens(.wide)
        XCTAssertEqual(service.selectedLenses, [], "no switch reaches the camera while recording")
        XCTAssertEqual(session.lens, .ultraWide)
        XCTAssertNil(LensSettings.saved(in: defaults))
    }

    func testFailedSwitchKeepsTheOldLensAndChoice() async {
        LensSettings.save(.ultraWide, in: defaults)
        service.selectLensError = RecordingError.configurationFailed("camera input")
        let session = await readySession()
        await session.selectLens(.wide)
        XCTAssertEqual(session.lens, .ultraWide)
        XCTAssertEqual(LensSettings.saved(in: defaults), .ultraWide)
        XCTAssertEqual(session.phase, .ready, "a failed switch doesn't stop the parent from recording")
    }

    func testCannotChooseALensThePhoneLacks() async {
        service.lensesOnPhone = [.wide]
        let session = await readySession()
        await session.selectLens(.ultraWide)
        XCTAssertEqual(service.selectedLenses, [])
        XCTAssertEqual(session.lens, .wide)
    }
}
