import XCTest
import AVFAudio
import AudioToolbox
import Darwin
@testable import MiraEQ

private final class OfflineSpeakerInput: @unchecked Sendable {
    let config: DSPConfig
    let resources: UnsafeMutablePointer<DSPResources>
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let rate: Double
    var cursor = 0

    init(config: DSPConfig, resources: UnsafeMutablePointer<DSPResources>, rate: Double) {
        self.config = config; self.resources = resources; self.rate = rate
    }
    deinit { scratch.deallocate() }

    func render(_ count: UInt32, _ buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = Int(count)
        guard frames <= 256 else { return kAudio_ParamError }
        // Full-scale low-frequency tones, multitone, impulses, and silence.
        // These exercise EQ boost and limiter recovery without hardware output.
        for frame in 0..<frames {
            let t = Double(cursor + frame) / rate
            let section = Int(t * 2) % 6
            let sample: Float
            switch section {
            case 0: sample = Float(sin(t * 2 * .pi * 125)) * 0.999
            case 1: sample = Float(sin(t * 2 * .pi * 64)) * 0.999
            case 2: sample = Float((sin(t * 2 * .pi * 80) + sin(t * 2 * .pi * 180) + sin(t * 2 * .pi * 1_000)) / 3) * 0.999
            case 3: sample = (cursor + frame) % 997 == 0 ? 1 : 0
            case 4: sample = Float(sin(t * 2 * .pi * 8_000)) * 0.999
            default: sample = 0
            }
            scratch[frame * 2] = sample
            scratch[frame * 2 + 1] = sample
        }
        cursor += frames
        applyRealtimeEffects(scratch, frames: frames, channels: 2, config: config, resources: resources)
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        for channel in 0..<min(list.count, 2) {
            if let out = list[channel].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frames { out[frame] = scratch[frame * 2 + channel] }
            }
        }
        return noErr
    }
}

final class SpeakerEngineTests: XCTestCase {
    @MainActor
    private func configuration() throws -> EQConfig {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store = ConfigurationStore(directory: repo)
        let base = try store.loadDevicePreset(named: "M5_MacBook_Air_Rich.txt")
        let tuning = try store.loadTuning(named: ".MiraEQ_BuiltInSpeakerDevice_Processing.txt")
        return SpeakerEngineProfile.prepare(tuning.applying(to: base))
    }

    @MainActor
    private func renderConfiguration(_ config: EQConfig, rate: Float) -> DSPConfig {
        return DSPConfig(effects: config.effects, sampleRate: rate)
    }

    @MainActor
    func testOfflineOutputAndBenchmark() async throws {
        let config = try configuration()
        let rate: Double = 44_100
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        var results: [[String: Double]] = []
        for volume: Float in [0.25, 0.75, 1.0] {
            setupResources(sampleRate: rate, channels: 2, ringBuf: AudioRingBuffer(capacityFrames: 1024, channels: 2))
            let resources = try XCTUnwrap(rtActiveResources.load(ordering: .acquiring))
            let input = OfflineSpeakerInput(config: renderConfiguration(config, rate: Float(rate)), resources: resources, rate: rate)
            storeRealtimeOutputVolumeScalar(volume)
            // Enter offline mode before creating the graph's output node so
            // the fixture never creates and tears down a physical HAL unit.
            let engine = AVAudioEngine()
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 128)
            let graph = SpeakerAudioGraph(format: format, config: config, engine: engine) { _, _, frames, buffers in input.render(frames, buffers) }
            XCTAssertEqual(graph.equalizer.bands.count, 11)
            try engine.start()
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            var peak: Float = 0
            var nonFinite = 0
            var timings: [Double] = []
            for i in 0..<4096 {
                let start = DispatchTime.now().uptimeNanoseconds
                let status = try engine.renderOffline(128, to: output)
                if i >= 128 { timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000) }
                XCTAssertEqual(status, .success)
                for c in 0..<2 {
                    let samples = output.floatChannelData![c]
                    for f in 0..<Int(output.frameLength) {
                        if !samples[f].isFinite { nonFinite += 1 }
                        peak = max(peak, abs(samples[f]))
                    }
                }
            }
            let effectLatencyMs = graph.latencyMs
            engine.stop()
            // Keep it offline through deallocation. Disabling manual mode
            // here would recreate an unnecessary physical output unit.
            purgeResources()
            XCTAssertEqual(nonFinite, 0)
            XCTAssertGreaterThan(peak, 0.1)
            XCTAssertLessThanOrEqual(peak, 1.001, "Final protection must contain full-scale boosted bass at unity gain")
            let sorted = timings.sorted()
            results.append(["native_effect_ms":effectLatencyMs,"volume":Double(volume),"mean_us":timings.reduce(0,+)/Double(timings.count),"p95_us":sorted[Int(Double(sorted.count)*0.95)],"peak":Double(peak)])
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        print("MIRAEQ_SPEAKER_BENCHMARK " + String(decoding:data,as:UTF8.self))
    }

    func testSpeakerProfileDisablesRemovedEnginesAndUsesUnityGain() {
        let legacy = ConfigParser.parse(content: """
        Preamp: -4 dB
        Effect: Surround width 100 reverb 30 rear 80
        Effect: Delay time 50 mix 40
        Effect: BassComp amount 70
        Effect: SoftLimit drive 80
        Effect: BassMono cutoff 120
        """).config
        let prepared = SpeakerEngineProfile.prepare(legacy)
        XCTAssertEqual(prepared.preamp, 0)
        XCTAssertFalse(prepared.effects.delay.isEnabled)
        XCTAssertFalse(prepared.effects.surround.isEnabled)
        XCTAssertFalse(prepared.effects.bassComp.isEnabled)
        XCTAssertFalse(prepared.effects.softLimit.isEnabled)
        XCTAssertFalse(prepared.effects.bassMono.isEnabled)
        XCTAssertEqual(SpeakerEngineProfile.prepare(prepared), prepared)
        XCTAssertEqual(DeviceTuning().applying(to: EQConfig(preamp: 0, bands: [])).effects.latency.targetMs, 1)
    }

    func testLowLatencyFramesRespectTheDeviceRange() {
        XCTAssertEqual(preferredBufferFrameSize(sampleRate: 44_100, targetLatencyMs: 1, range: AudioValueRange(mMinimum: 32, mMaximum: 512)), 128)
        XCTAssertEqual(preferredBufferFrameSize(sampleRate: 44_100, targetLatencyMs: 1, range: AudioValueRange(mMinimum: 128, mMaximum: 512)), 128)
        XCTAssertEqual(preferredBufferFrameSize(sampleRate: 48_000, targetLatencyMs: 12, range: AudioValueRange(mMinimum: 64, mMaximum: 1024)), 512)
    }
    @MainActor
    func testRenderQueuePrimesAndRecoversWithOneQuantumOfMargin() async throws {
        let ring = AudioRingBuffer(capacityFrames: 1024, channels: 2)
        setupResources(sampleRate: 44_100, channels: 2, ringBuf: ring)
        var effects = EffectConfig()
        effects.latency = LatencyEffectConfig(targetMs: 1, isSet: true)
        let ptr = UnsafeMutablePointer<DSPConfig>.allocate(capacity: 1)
        ptr.initialize(to: DSPConfig(effects: effects, sampleRate: 44_100))
        if let old = rtActiveConfig.exchange(ptr, ordering: .acquiringAndReleasing) { retireConfig(old) }
        resetRuntimeDiagnostics()
        storeEffectMix(1)
        defer { purgeResources(); purgeConfigs() }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        out.frameLength = 64
        func write(_ value: Float, frames: Int) {
            let input = [Float](repeating: value, count: frames * 2)
            input.withUnsafeBufferPointer { XCTAssertEqual(ring.write($0.baseAddress!, count: $0.count), 0) }
        }
        func render() {
            var silence = ObjCBool(false), stamp = AudioTimeStamp()
            XCTAssertEqual(renderCallback(&silence, &stamp, frameCount: 64, audioBufferList: out.mutableAudioBufferList), noErr)
        }
        write(0.2, frames: 64)
        render()
        XCTAssertEqual(rtNeedsPriming.load(ordering: .relaxed), 1)
        XCTAssertEqual(out.floatChannelData![0][0], 0)
        write(0.2, frames: 64)
        render()
        XCTAssertEqual(rtNeedsPriming.load(ordering: .relaxed), 0)
        XCTAssertEqual(out.floatChannelData![0][0], 0.2, accuracy: 0.00001)
        XCTAssertEqual(ring.availableToRead, 128) // one stereo quantum remains
        write(0.3, frames: 256)
        render()
        XCTAssertEqual(out.floatChannelData![0][0], 0.3, accuracy: 0.00001)
        XCTAssertEqual(ring.availableToRead, 128)
        XCTAssertEqual(rtDroppedSampleCount.load(ordering: .relaxed), 384)
        render()
        render()
        XCTAssertEqual(rtNeedsPriming.load(ordering: .relaxed), 1)
        XCTAssertEqual(rtUnderrunCount.load(ordering: .relaxed), 1)
        write(0.4, frames: 128)
        render()
        XCTAssertEqual(rtNeedsPriming.load(ordering: .relaxed), 0)
        XCTAssertEqual(out.floatChannelData![0][0], 0.4, accuracy: 0.00001)
    }

    func testMalformedNumericSettingsCannotPublishNonfiniteCoefficients() {
        var effects = EffectConfig()
        effects.bassHarmonics.amount = .nan
        effects.bassHarmonics.speakerCutoffHz = .infinity
        effects.lowEndGuard.thresholdDb = .nan
        effects.lowEndGuard.ratio = .nan
        effects.bassFocus.maxHighCutDb = .nan
        effects.latency.targetMs = .nan
        let config = DSPConfig(effects: effects, sampleRate: .nan)
        for value in [config.sampleRate, config.bassHarmonicsLowpass.b0, config.bassHarmonicsLowpass.a1,
                      config.bassHarmonicsBandpass.b0, config.lowEndGuardThresholdLinear,
                      config.lowEndGuardRatio, config.bassFocusMaxHighCutGain, config.maxRealtimeLatencySeconds] {
            XCTAssertTrue(value.isFinite)
        }
        let legacy = EQConfig(preamp: .nan, bands: [EQBand(filterType: .parametric, frequency: .nan, bandwidth: .nan, gain: .nan, bypass: false)])
        let prepared = SpeakerEngineProfile.prepare(legacy)
        XCTAssertEqual(prepared.preamp, 0)
        XCTAssertTrue(prepared.bands[0].frequency.isFinite)
        XCTAssertTrue(prepared.bands[0].gain.isFinite)
    }

    @MainActor
    func testCaptureInterleavesBothFormatsAndSilencesAggregateOutput() async throws {
        for interleaved in [false, true] {
            let ring = AudioRingBuffer(capacityFrames: 1024, channels: 2)
            setupResources(sampleRate: 44_100, channels: 2, ringBuf: ring)
            resetRuntimeDiagnostics()
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: interleaved)!
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
            input.frameLength = 64
            if interleaved {
                let data = input.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
                for f in 0..<64 { data[f * 2] = 0.1; data[f * 2 + 1] = -0.3 }
            } else {
                for f in 0..<64 { input.floatChannelData![0][f] = 0.1; input.floatChannelData![1][f] = -0.3 }
            }
            let out = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!, frameCapacity: 64)!
            out.frameLength = 64
            for c in 0..<2 { for f in 0..<64 { out.floatChannelData![c][f] = 1 } }
            var stamp = AudioTimeStamp()
            withUnsafePointer(to: &stamp) { time in
                captureAudioBlock(time, input.audioBufferList, time, out.mutableAudioBufferList, time)
            }
            XCTAssertEqual(ring.availableToRead, 128)
            var received = [Float](repeating: 0, count: 128)
            received.withUnsafeMutableBufferPointer { XCTAssertEqual(ring.read($0.baseAddress!, count: $0.count), 128) }
            for f in 0..<64 {
                XCTAssertEqual(received[f * 2], 0.1)
                XCTAssertEqual(received[f * 2 + 1], -0.3)
                XCTAssertEqual(out.floatChannelData![0][f], 0)
                XCTAssertEqual(out.floatChannelData![1][f], 0)
            }
            XCTAssertEqual(Float(bitPattern: rtLastAudiblePeakBits.load(ordering: .relaxed)), 0.3, accuracy: 0.00001)
            XCTAssertEqual(rtLastInputFrameCount.load(ordering: .relaxed), 64)
            XCTAssertEqual(rtReaderCount.load(ordering: .relaxed), 0)
            purgeResources()
        }
    }

}
