import XCTest
@testable import MiraEQ

final class ConfigParserTests: XCTestCase {
    func testParsePreampAndFilter() {
        let content = """
        # MiraEQ Preset: Test
        Preamp: -3.5 dB
        Filter 1: ON PK Fc 100 Hz Gain 2.0 dB Q 1.0
        Filter 2: OFF HSC Fc 10000 Hz Gain -1.5 dB Q 0.7
        """
        let (config, warnings) = ConfigParser.parse(content: content)
        XCTAssertTrue(warnings.isEmpty, "unexpected warnings: \(warnings)")
        XCTAssertEqual(config.preamp, -3.5, accuracy: 0.001)
        XCTAssertEqual(config.bands.count, 2)
        XCTAssertFalse(config.bands[0].bypass)
        XCTAssertEqual(config.bands[0].frequency, 100, accuracy: 0.01)
        XCTAssertTrue(config.bands[1].bypass)
    }

    func testParseUnknownFilterTypeWarnsButParses() {
        let (config, warnings) = ConfigParser.parse(content: "Filter 1: ON XXX Fc 1000 Hz Gain 0 dB Q 1.0\n")
        XCTAssertEqual(config.bands.count, 1)
        XCTAssertFalse(warnings.isEmpty)
    }

    func testParseBassMonoAndLoudness() {
        let content = """
        Effect: BassMono cutoff 120 Hz
        Effect: Loudness amount 50
        """
        let (config, warnings) = ConfigParser.parse(content: content)
        XCTAssertTrue(warnings.isEmpty, "unexpected warnings: \(warnings)")
        XCTAssertTrue(config.effects.bassMono.isEnabled)
        XCTAssertEqual(config.effects.bassMono.cutoffHz, 120, accuracy: 0.01)
        XCTAssertTrue(config.effects.loudness.isEnabled)
        XCTAssertEqual(config.effects.loudness.amount, 50, accuracy: 0.01)
    }

    func testBassMonoAndLoudnessOffByDefault() {
        let (config, warnings) = ConfigParser.parse(content: "Preamp: 0 dB\n")
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertFalse(config.effects.bassMono.isEnabled)
        XCTAssertFalse(config.effects.loudness.isEnabled)
    }

    func testBassMonoAndLoudnessClamping() {
        let content = """
        Effect: BassMono cutoff 900 Hz
        Effect: Loudness amount 250
        """
        let (config, warnings) = ConfigParser.parse(content: content)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertLessThanOrEqual(config.effects.bassMono.cutoffHz, 300)
        XCTAssertLessThanOrEqual(config.effects.loudness.amount, 100)
    }

    func testParseRoutingRoundTrip() {
        let mappings = [
            DeviceMapping(pattern: "MacBook Air Speakers", devicePresetFile: "A.txt", addOnPresetFile: ".MiraEQ_X_Processing.txt"),
            DeviceMapping(pattern: "uid-123", devicePresetFile: nil, addOnPresetFile: nil),
        ]
        let text = ConfigParser.writeRouting(mappings: mappings)
        let reparsed = ConfigParser.parseRouting(content: text)
        XCTAssertEqual(reparsed.count, 2)
        XCTAssertEqual(reparsed[0].pattern, "MacBook Air Speakers")
        XCTAssertEqual(reparsed[0].devicePresetFile, "A.txt")
        XCTAssertEqual(reparsed[0].addOnPresetFile, ".MiraEQ_X_Processing.txt")
        XCTAssertEqual(reparsed[1].pattern, "uid-123")
        XCTAssertNil(reparsed[1].devicePresetFile)
    }

    func testRoutingNoneBecomesNil() {
        let mappings = ConfigParser.parseRouting(content: "My Device = None\n")
        XCTAssertEqual(mappings.count, 1)
        XCTAssertNil(mappings[0].devicePresetFile)
    }

    func testEffectClamping() {
        let content = "Effect: BassHarmonics amount 500 cutoff 10 Hz\n"
        let (config, warnings) = ConfigParser.parse(content: content)
        XCTAssertTrue(warnings.isEmpty)
        // 500 is clamped to 100, 10 Hz clamped to >= 50.
        XCTAssertLessThanOrEqual(config.effects.bassHarmonics.amount, 100)
        XCTAssertGreaterThanOrEqual(config.effects.bassHarmonics.cutoffHz, 50)
    }

    func testHiddenPresetRoundTrip() {
        let tuning = DeviceTuning(latencyTargetMs: 5, bassHarmonicsAmount: 0, bassFocusAmount: 30)
        let (reparsed, warnings) = ConfigParser.parseTuning(content: tuning.presetContent)
        XCTAssertTrue(warnings.isEmpty, "warnings: \(warnings)")
        XCTAssertEqual(reparsed, tuning)
    }
}

final class AudioRingBufferTests: XCTestCase {
    func testWriteReadRoundTrip() {
        let ring = AudioRingBuffer(capacityFrames: 256, channels: 2)
        var input = [Float](repeating: 0, count: 128)
        for i in 0..<input.count { input[i] = Float(i) * 0.01 }
        let dropped = input.withUnsafeBufferPointer { ptr in
            ring.write(ptr.baseAddress!, count: input.count)
        }
        XCTAssertEqual(dropped, 0)
        var output = [Float](repeating: -1, count: 128)
        let read = output.withUnsafeMutableBufferPointer { ptr in
            ring.read(ptr.baseAddress!, count: ptr.count)
        }
        XCTAssertEqual(read, 128)
        XCTAssertEqual(output, input)
    }

    func testOverflowPreservesUnreadSamples() {
        let ring = AudioRingBuffer(capacityFrames: 4, channels: 1)
        let input = (0..<16).map { Float($0) }
        let dropped = input.withUnsafeBufferPointer { ptr in
            ring.write(ptr.baseAddress!, count: input.count)
        }
        XCTAssertEqual(dropped, 12)
        XCTAssertEqual(ring.availableToRead, 4)
        var output = [Float](repeating: -1, count: 4)
        let read = output.withUnsafeMutableBufferPointer { ring.read($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(output, [0, 1, 2, 3])
    }
}
