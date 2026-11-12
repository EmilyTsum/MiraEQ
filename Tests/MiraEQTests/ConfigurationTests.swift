import Foundation
import XCTest
@testable import MiraEQ

private final class ConfigurationFixture {
    let store: ConfigurationStore

    init() throws {
        store = ConfigurationStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try store.prepareSupportFiles(bundledPresetRoots: [])
        try writePreset("A.txt", content: "Preamp: -4 dB\nEffect: BassHarmonics amount 6 cutoff 145 speaker 125\n")
        try writePreset("B.txt", content: "Preamp: -8 dB\n")
    }

    func writePreset(_ name: String, content: String) throws {
        try content.write(to: store.devicePresetDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: store.directory) }
}

final class DeviceTuningTests: XCTestCase {
    private let baseContent = """
    Preamp: -4 dB
    Effect: Latency target 8.25
    Effect: Surround width 18 rear 20 distance 43.25 strength 90
    Effect: BassHarmonics amount 6 cutoff 145 speaker 125
    Effect: LowEndGuard amount 45 threshold -16 cutoff 170 ratio 3 maxreduction 5
    Effect: BassFocus amount 35 threshold -20 highcut 6
    Effect: BassComp amount 75 crossover 180
    Effect: SoftLimit drive 20
    Effect: BassMono cutoff 120
    Effect: Loudness amount 50
    Filter 1: ON PK Fc 125 Hz Gain 4 dB Q 1
    """

    func testUnspecifiedSettingsInheritTheBasePreset() {
        let base = ConfigParser.parse(content: baseContent).config
        XCTAssertEqual(DeviceTuning().applying(to: base), base)
    }

    func testOnlySelectedSettingChangesAcrossSaveAndReload() {
        let base = ConfigParser.parse(content: baseContent).config
        let tuning = DeviceTuning(bassFocusAmount: 70)
        let parsed = ConfigParser.parseTuning(content: tuning.presetContent)
        XCTAssertTrue(parsed.warnings.isEmpty)
        var expected = base
        expected.effects.bassFocus.amountPercent = 70
        XCTAssertEqual(parsed.tuning.applying(to: base), expected)
        XCTAssertNil(parsed.tuning.spatialEnabled)
        XCTAssertNil(parsed.tuning.latencyTargetMs)
        XCTAssertNil(parsed.tuning.bassHarmonicsAmount)
    }

    func testExplicitOffSurvivesRoundTrip() {
        let tuning = DeviceTuning(spatialEnabled: false, bassHarmonicsAmount: 0, lowEndGuardAmount: 0,
                                  bassFocusAmount: 0, bassCompAmount: 0, softLimitDrive: 0)
        let parsed = ConfigParser.parseTuning(content: tuning.presetContent)
        XCTAssertEqual(parsed.tuning, tuning)
        let result = parsed.tuning.applying(to: ConfigParser.parse(content: baseContent).config)
        XCTAssertFalse(result.effects.bassHarmonics.isEnabled)
        XCTAssertFalse(result.effects.lowEndGuard.isEnabled)
        XCTAssertFalse(result.effects.bassFocus.isEnabled)
        XCTAssertFalse(result.effects.bassComp.isEnabled)
        XCTAssertFalse(result.effects.softLimit.isEnabled)
        XCTAssertFalse(result.effects.surround.isEnabled)
        XCTAssertFalse(result.effects.delay.isEnabled)
    }

    func testAllOverridesRoundTripWithoutQuantizingLatencyOrPrecision() {
        let tuning = DeviceTuning(latencyTargetMs: 7.2345, spatialEnabled: true, listenerDistanceCm: 44.123,
                                  spatialStrengthPercent: 115.555, bassHarmonicsAmount: 12.125,
                                  bassHarmonicsCutoffHz: 137.345, bassHarmonicsSpeakerCutoffHz: 125.125,
                                  lowEndGuardAmount: 33.333, bassFocusAmount: 66.666,
                                  bassCompAmount: 25.25, bassCompCrossoverHz: 175.125, softLimitDrive: 10.125)
        let parsed = ConfigParser.parseTuning(content: tuning.presetContent)
        XCTAssertTrue(parsed.warnings.isEmpty)
        XCTAssertEqual(parsed.tuning, tuning)
        let base = ConfigParser.parse(content: baseContent).config
        XCTAssertEqual(parsed.tuning.applying(to: base), tuning.applying(to: base))
        XCTAssertEqual(tuning.applying(to: base).preamp, -10.5)
    }

    func testSparseSpatialPositionDoesNotToggleSpatialProcessing() {
        let parsed = ConfigParser.parseTuning(content: "Effect: Wide listener 45 spatialstrength 120\n")
        XCTAssertTrue(parsed.warnings.isEmpty)
        XCTAssertNil(parsed.tuning.spatialEnabled)
        let base = ConfigParser.parse(content: baseContent).config
        let result = parsed.tuning.applying(to: base)
        XCTAssertEqual(result.preamp, base.preamp)
        XCTAssertEqual(result.effects.surround.width, 18)
        XCTAssertEqual(result.effects.surround.listenerDistanceCm, 45)
        XCTAssertEqual(result.effects.surround.spatialStrengthPercent, 120)
    }

    func testLegacyAliasesAndExplicitZeros() {
        let result = ConfigParser.parseTuning(content: """
        Effect: Buffer ms 8
        Effect: Bass amount 0 cutoffhz 150 speakercutoffhz 130
        Effect: BassLimiter strength 0
        Effect: Inverse_Loudness mix 0
        Effect: BassComp strength 0 freq 190
        Effect: SoftLimit amount 0
        """)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.tuning, DeviceTuning(latencyTargetMs: 8, bassHarmonicsAmount: 0,
                                                  bassHarmonicsCutoffHz: 150, bassHarmonicsSpeakerCutoffHz: 130,
                                                  lowEndGuardAmount: 0, bassFocusAmount: 0,
                                                  bassCompAmount: 0, bassCompCrossoverHz: 190, softLimitDrive: 0))
    }

    func testBuiltInPresetMatchesDedicatedSpeakerProfile() throws {
        let fixture = try ConfigurationFixture()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try fixture.store.prepareSupportFiles(bundledPresetRoots: [repo.appendingPathComponent("presets")])
        let preset = "M5_MacBook_Air_Rich.txt"
        let hidden = ".MiraEQ_BuiltInSpeakerDevice_Processing.txt"
        try fixture.store.writeRouting([DeviceMapping(pattern: "Speakers", devicePresetFile: preset, addOnPresetFile: hidden)])
        try verifyRoundTrip(devicePresetName: preset, addOnPresetName: hidden, store: fixture.store)
        let config = try effectiveConfig(devicePresetName: preset, addOnPresetName: hidden, store: fixture.store)
        XCTAssertEqual(config.preamp, 0)
        XCTAssertEqual(config.bands.count, 11)
        XCTAssertEqual(config.effects.latency.targetMs, 1)
        XCTAssertEqual(config.effects.bassHarmonics.amount, 8)
        XCTAssertEqual(config.effects.bassFocus.amountPercent, 70)
        XCTAssertEqual(config.effects.bassComp.amountPercent, 0)
        XCTAssertEqual(config.effects.lowEndGuard.maxReductionDb, 5)
        XCTAssertEqual(config.effects.bassMono.cutoffHz, 0)
        XCTAssertEqual(config.effects.loudness.amount, 50)
        XCTAssertFalse(config.effects.surround.isEnabled)
        XCTAssertFalse(config.effects.softLimit.isEnabled)
    }
}

final class DeviceRoutingTests: XCTestCase {
    @MainActor
    func testPresetSwitchAndBypassKeepPerDeviceTuning() async throws {
        let fixture = try ConfigurationFixture()
        let routing = DeviceRoutingController(store: fixture.store)
        routing.reload()
        routing.selectDevice(OutputDevice(id: 1, name: "Speakers", uid: "uid-1"))
        try routing.selectPreset("A.txt")
        XCTAssertEqual(routing.effectiveConfig?.effects.bassHarmonics.amount, 6)
        try routing.updateTuning { $0.bassHarmonicsAmount = 0; $0.bassFocusAmount = 70 }
        let hidden = try XCTUnwrap(routing.activeMapping?.addOnPresetFile)
        try routing.selectPreset(nil)
        XCTAssertNil(routing.effectiveConfig)
        XCTAssertEqual(try fixture.store.loadRouting().first?.addOnPresetFile, hidden)
        try routing.selectPreset("B.txt")
        XCTAssertEqual(routing.baseConfig?.preamp, -8)
        XCTAssertEqual(routing.tuning.bassFocusAmount, 70)
        XCTAssertEqual(routing.effectiveConfig?.effects.bassHarmonics.amount, 0)
        routing.reload()
        XCTAssertEqual(routing.tuning.bassFocusAmount, 70)
        try routing.updateTuning { $0 = DeviceTuning() }
        try routing.selectPreset("A.txt")
        XCTAssertEqual(routing.effectiveConfig?.effects.bassHarmonics.amount, 6)
    }

    @MainActor
    func testDeviceUIDSeparatesDevicesWithTheSameName() async throws {
        let fixture = try ConfigurationFixture()
        let routing = DeviceRoutingController(store: fixture.store)
        routing.reload()
        routing.selectDevice(OutputDevice(id: 1, name: "USB Audio", uid: "uid-1"))
        try routing.selectPreset("A.txt")
        try routing.updateTuning { $0.bassFocusAmount = 70 }
        routing.selectDevice(OutputDevice(id: 2, name: "USB Audio", uid: "uid-2"))
        XCTAssertNil(routing.effectiveConfig)
        try routing.selectPreset("B.txt")
        routing.selectDevice(OutputDevice(id: 3, name: "Renamed USB Audio", uid: "uid-1"))
        XCTAssertEqual(routing.baseConfig?.preamp, -4)
        XCTAssertEqual(routing.tuning.bassFocusAmount, 70)
        XCTAssertEqual(routing.mappings.map(\.pattern), ["uid-2", "uid-1"])
    }

    @MainActor
    func testLegacyNameRulesKeepFirstMatchSemantics() async throws {
        let fixture = try ConfigurationFixture()
        try fixture.store.writeRouting([
            DeviceMapping(pattern: " speakers ", devicePresetFile: "A.txt"),
            DeviceMapping(pattern: "UID-1", devicePresetFile: "B.txt")
        ])
        let routing = DeviceRoutingController(store: fixture.store)
        routing.reload()
        routing.selectDevice(OutputDevice(id: 1, name: "Speakers", uid: "uid-1"))
        XCTAssertEqual(routing.baseConfig?.preamp, -4)
        try routing.selectPreset(nil)
        XCTAssertEqual(routing.mappings.count, 1)
        XCTAssertNil(routing.effectiveConfig)
    }

    @MainActor
    func testFailedReloadPreservesTheLastCompleteConfiguration() async throws {
        let fixture = try ConfigurationFixture()
        try fixture.store.writeRouting([DeviceMapping(pattern: "uid-1", devicePresetFile: "A.txt")])
        let routing = DeviceRoutingController(store: fixture.store)
        routing.reload()
        routing.selectDevice(OutputDevice(id: 1, name: "Speakers", uid: "uid-1"))
        let previous = routing.effectiveConfig
        try fixture.store.writeRouting([DeviceMapping(pattern: "uid-1", devicePresetFile: "Missing.txt")])
        routing.reload()
        XCTAssertNotNil(routing.lastError)
        XCTAssertEqual(routing.effectiveConfig, previous)
        XCTAssertEqual(routing.activeMapping?.devicePresetFile, "A.txt")
        try fixture.writePreset("Missing.txt", content: "Preamp: -9 dB\n")
        routing.reload()
        XCTAssertNil(routing.lastError)
        XCTAssertEqual(routing.baseConfig?.preamp, -9)
    }

    @MainActor
    func testFailedDeviceSwitchDoesNotReuseTheOldDeviceEQ() async throws {
        let fixture = try ConfigurationFixture()
        try fixture.store.writeRouting([
            DeviceMapping(pattern: "uid-1", devicePresetFile: "A.txt"),
            DeviceMapping(pattern: "uid-2", devicePresetFile: "Missing.txt")
        ])
        let routing = DeviceRoutingController(store: fixture.store)
        routing.reload()
        routing.selectDevice(OutputDevice(id: 1, name: "A", uid: "uid-1"))
        XCTAssertNotNil(routing.effectiveConfig)
        routing.selectDevice(OutputDevice(id: 2, name: "B", uid: "uid-2"))
        XCTAssertNil(routing.effectiveConfig)
        XCTAssertNotNil(routing.lastError)
        routing.selectDevice(nil)
        XCTAssertNil(routing.activeMapping)
        XCTAssertNil(routing.lastError)
    }

    @MainActor
    func testWriteFailureDoesNotChangeTheSelectedRoute() async throws {
        let fixture = try ConfigurationFixture()
        let routing = DeviceRoutingController(store: fixture.store)
        routing.reload()
        routing.selectDevice(OutputDevice(id: 1, name: "Speakers", uid: "uid-1"))
        try routing.selectPreset("A.txt")
        let previous = routing.effectiveConfig
        try FileManager.default.removeItem(at: fixture.store.routingURL)
        try FileManager.default.createDirectory(at: fixture.store.routingURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try routing.selectPreset("B.txt"))
        XCTAssertEqual(routing.effectiveConfig, previous)
        XCTAssertEqual(routing.activeMapping?.devicePresetFile, "A.txt")
    }

    func testSupportFileSetupIsIdempotentAndPreservesUserEdits() throws {
        let fixture = try ConfigurationFixture()
        let before = try fixture.store.devicePresetContent(named: "A.txt")
        try fixture.store.writeRouting([DeviceMapping(pattern: "Speakers", devicePresetFile: "A.txt")])
        try fixture.store.prepareSupportFiles(bundledPresetRoots: [])
        XCTAssertEqual(try fixture.store.devicePresetContent(named: "A.txt"), before)
        XCTAssertEqual(try fixture.store.loadRouting().count, 1)
    }
}

final class ConfigurationMonitorTests: XCTestCase {
    @MainActor
    func testActivePresetReloadsForInPlaceAndAtomicSaves() async throws {
        let fixture = try ConfigurationFixture()
        let first = expectation(description: "in-place save")
        let second = expectation(description: "atomic save")
        var phase = 0
        let monitor = ConfigurationMonitor(store: fixture.store) {
            let preamp = try? fixture.store.loadDevicePreset(named: "A.txt").preamp
            if phase == 0, preamp == -7 { phase = 1; first.fulfill() }
            if phase == 1, preamp == -9 { phase = 2; second.fulfill() }
        }
        monitor.watchPresets(devicePreset: "A.txt", addOnPreset: nil)
        monitor.start()
        defer { monitor.stop() }
        let handle = try FileHandle(forWritingTo: fixture.store.devicePresetDirectory.appendingPathComponent("A.txt"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("Preamp: -7 dB\n".utf8))
        try handle.close()
        await fulfillment(of: [first], timeout: 3)
        try fixture.writePreset("A.txt", content: "Preamp: -9 dB\n")
        await fulfillment(of: [second], timeout: 3)
    }

    @MainActor
    func testMissingActiveTuningIsWatchedAfterItIsCreated() async throws {
        let fixture = try ConfigurationFixture()
        let name = ".Processing.txt"
        let created = expectation(description: "new tuning file")
        let edited = expectation(description: "in-place tuning edit")
        var phase = 0
        var monitor: ConfigurationMonitor!
        monitor = ConfigurationMonitor(store: fixture.store) {
            let tuning = try? fixture.store.loadTuning(named: name)
            monitor.watchPresets(devicePreset: "A.txt", addOnPreset: name)
            if phase == 0, tuning?.bassFocusAmount == 30 { phase = 1; created.fulfill() }
            if phase == 1, tuning?.bassFocusAmount == 70 { phase = 2; edited.fulfill() }
        }
        monitor.watchPresets(devicePreset: "A.txt", addOnPreset: name)
        monitor.start()
        defer { monitor.stop(); monitor = nil }
        try fixture.store.writeTuning(DeviceTuning(bassFocusAmount: 30), named: name)
        await fulfillment(of: [created], timeout: 3)
        let handle = try FileHandle(forWritingTo: fixture.store.addOnPresetDirectory.appendingPathComponent(name))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("Effect: BassFocus amount 70\n".utf8))
        try handle.close()
        await fulfillment(of: [edited], timeout: 3)
    }

    @MainActor
    func testStoppingAWatcherCancelsPendingReattachWithoutCreatingFiles() async throws {
        let fixture = try ConfigurationFixture()
        let url = fixture.store.devicePresetDirectory.appendingPathComponent("A.txt")
        var changes = 0
        let watcher = FileWatcher(url: url) { changes += 1 }
        watcher.start()
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(nanoseconds: 80_000_000)
        watcher.stop()
        let stoppedAt = changes
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try fixture.writePreset("A.txt", content: "Preamp: -9 dB\n")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(changes, stoppedAt)
    }

    @MainActor
    func testStoppingMonitorCancelsDebouncedReload() async throws {
        let fixture = try ConfigurationFixture()
        var reloads = 0
        let monitor = ConfigurationMonitor(store: fixture.store) { reloads += 1 }
        monitor.start()
        try fixture.store.writeRouting([DeviceMapping(pattern: "Speakers", devicePresetFile: "A.txt")])
        try await Task.sleep(nanoseconds: 80_000_000)
        monitor.stop()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(reloads, 0)
    }
}
