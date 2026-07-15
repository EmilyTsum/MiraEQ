import CoreAudio
import AudioToolbox
import Atomics
import AVFAudio
import Foundation
import Darwin
import os.log

private let appLog = OSLog(subsystem: AppInfo.logSubsystem, category: "audio")
private let maximumRealtimeSampleRate: Float64 = 768_000
private let maximumRealtimeChannelCount: UInt32 = 64
private let defaultSpatialHeadHeightCm: Float = 38
private let defaultSpatialDisplayAngleDegrees: Float = 150

private func finiteOrDefault(_ value: Float, default defaultValue: Float) -> Float {
    value.isFinite ? value : defaultValue
}

private func finiteClamped(_ value: Float, default defaultValue: Float, min minValue: Float, max maxValue: Float) -> Float {
    min(max(finiteOrDefault(value, default: defaultValue), minValue), maxValue)
}

private func linearGain(forReductionDb reductionDb: Float) -> Float {
    powf(10, -max(reductionDb, 0) / 20)
}

private func reductionDb(fromLinearGain gain: Float) -> Float {
    let clamped = min(max(finiteOrDefault(gain, default: 1), 0.000_001), 1)
    let db = -20 * log10f(clamped)
    return db < 0.005 ? 0 : db
}

private func amplitudeDb(fromLinearAmplitude amplitude: Float) -> Float {
    20 * log10f(max(finiteOrDefault(amplitude, default: 0), 0.000_001))
}

// MARK: - Real-time Audio Callbacks
private struct BiquadCoefficients {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float
}

private func lowpassBiquad(sampleRate: Float, cutoff: Float, q: Float) -> BiquadCoefficients {
    let clampedCutoff = min(max(cutoff, 20), sampleRate * 0.45)
    let omega = 2 * Float.pi * clampedCutoff / sampleRate
    let sinOmega = sinf(omega)
    let cosOmega = cosf(omega)
    let alpha = sinOmega / (2 * max(q, 0.1))
    let a0 = 1 + alpha

    return BiquadCoefficients(
        b0: ((1 - cosOmega) * 0.5) / a0,
        b1: (1 - cosOmega) / a0,
        b2: ((1 - cosOmega) * 0.5) / a0,
        a1: (-2 * cosOmega) / a0,
        a2: (1 - alpha) / a0
    )
}

private func bandpassBiquad(sampleRate: Float, center: Float, q: Float) -> BiquadCoefficients {
    let clampedCenter = min(max(center, 40), sampleRate * 0.45)
    let omega = 2 * Float.pi * clampedCenter / sampleRate
    let sinOmega = sinf(omega)
    let cosOmega = cosf(omega)
    let alpha = sinOmega / (2 * max(q, 0.1))
    let a0 = 1 + alpha

    return BiquadCoefficients(
        b0: alpha / a0,
        b1: 0,
        b2: -alpha / a0,
        a1: (-2 * cosOmega) / a0,
        a2: (1 - alpha) / a0
    )
}

private struct DSPConfig {
    let bassHarmonicsAmount: Float
    let bassHarmonicsCutoffHz: Float
    let bassHarmonicsSpeakerCutoffHz: Float
    let bassHarmonicsLowpass: BiquadCoefficients
    let bassHarmonicsBandpass: BiquadCoefficients
    let bassHarmonicsDCPole: Float
    let bassHarmonicsEnvelopeAttack: Float
    let bassHarmonicsEnvelopeRelease: Float
    let bassFocusAmount: Float
    let bassFocusThresholdDb: Float
    let bassFocusMaxHighCutDb: Float
    let bassFocusMaxHighCutGain: Float
    let lowEndGuardAmount: Float
    let lowEndGuardThresholdDb: Float
    let lowEndGuardThresholdLinear: Float
    let lowEndGuardCutoffHz: Float
    let lowEndGuardRatio: Float
    let lowEndGuardMaxReductionDb: Float
    let lowEndGuardMaxReductionGain: Float
    let bassCompAmount: Float
    let bassCompLowpass: BiquadCoefficients
    let bassCompEnvelopeAttack: Float
    let bassCompEnvelopeRelease: Float
    let bassCompGainSmoothing: Float
    let bassCompThresholdLinear: Float
    let bassCompInvThresholdLinear: Float
    let bassCompMaxMakeupGain: Float
    let softLimitDrive: Float
    let softLimitDriveGain: Float
    let stereoWidth: Float
    let rearSurroundAmount: Float
    let rearSurroundDelaySamples: Int
    let rearSurroundShadow: Float
    let crossTalkCancelAmount: Float
    let crossTalkDelaySamples: Int
    let sampleRate: Float
    let maxRealtimeLatencySeconds: Float
    // Diagnostic-only parameters
    let listenerDistanceCm: Float
    let headHeightCm: Float
    let displayAngleDegrees: Float
    let spatialStrengthPercent: Float
}

private let rtActiveConfig = ManagedAtomic<UnsafeMutablePointer<DSPConfig>?>(nil)

// RCU Reader count state
private let rtReaderCount = ManagedAtomic<Int>(0)
nonisolated(unsafe) private var rtRetiredConfigs: [UnsafeMutablePointer<DSPConfig>] = []
nonisolated(unsafe) private var rtCleanupInProgress = false

private let fallbackDSPConfig = DSPConfig(
    bassHarmonicsAmount: 0,
    bassHarmonicsCutoffHz: 140,
    bassHarmonicsSpeakerCutoffHz: 140,
    bassHarmonicsLowpass: BiquadCoefficients(
        b0: 0.000_082_883_7,
        b1: 0.000_165_767_4,
        b2: 0.000_082_883_7,
        a1: -1.974_080_791_7,
        a2: 0.974_412_326_4
    ),
    bassHarmonicsBandpass: BiquadCoefficients(
        b0: 0.017_988_250_2,
        b1: 0,
        b2: -0.017_988_250_2,
        a1: -1.961_386_490_5,
        a2: 0.964_023_499_5
    ),
    bassHarmonicsDCPole: 0.997_385_430_1,
    bassHarmonicsEnvelopeAttack: 0.004_157_998_2,
    bassHarmonicsEnvelopeRelease: 0.000_260_382_8,
    bassFocusAmount: 0,
    bassFocusThresholdDb: -18,
    bassFocusMaxHighCutDb: 7,
    bassFocusMaxHighCutGain: 0.446_683_592_2,
    lowEndGuardAmount: 0,
    lowEndGuardThresholdDb: -18,
    lowEndGuardThresholdLinear: 0.125_892_541_2,
    lowEndGuardCutoffHz: 180,
    lowEndGuardRatio: 4,
    lowEndGuardMaxReductionDb: 4.5,
    lowEndGuardMaxReductionGain: 0.595_662_143_5,
    bassCompAmount: 0,
    bassCompLowpass: BiquadCoefficients(
        b0: 0.000_168_225,
        b1: 0.000_336_450,
        b2: 0.000_168_225,
        a1: -1.962_975_817,
        a2: 0.963_648_000
    ),
    bassCompEnvelopeAttack: 0.001_734_607,
    bassCompEnvelopeRelease: 0.000_115_734,
    bassCompGainSmoothing: 0.002_081_164,
    bassCompThresholdLinear: 0.031_622_776_6,
    bassCompInvThresholdLinear: 31.622_776_6,
    bassCompMaxMakeupGain: 1,
    softLimitDrive: 0,
    softLimitDriveGain: 1,
    stereoWidth: 0,
    rearSurroundAmount: 0,
    rearSurroundDelaySamples: 0,
    rearSurroundShadow: 55,
    crossTalkCancelAmount: 0,
    crossTalkDelaySamples: 1,
    sampleRate: 48000,
    maxRealtimeLatencySeconds: 0.012,
    listenerDistanceCm: SpatialTuning.default.listenerDistanceCm,
    headHeightCm: defaultSpatialHeadHeightCm,
    displayAngleDegrees: defaultSpatialDisplayAngleDegrees,
    spatialStrengthPercent: SpatialTuning.default.strengthPercent
)

private func currentFallbackConfig() -> DSPConfig {
    fallbackDSPConfig
}

@MainActor
private func retireConfig(_ oldPtr: UnsafeMutablePointer<DSPConfig>) {
    rtRetiredConfigs.append(oldPtr)
    cleanUpRetiredConfigs()
}

@MainActor
private func cleanUpRetiredConfigs() {
    guard !rtRetiredConfigs.isEmpty else { return }
    
    if rtReaderCount.load(ordering: .acquiring) == 0 {
        for ptr in rtRetiredConfigs {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
        }
        rtRetiredConfigs.removeAll()
        rtCleanupInProgress = false
    } else {
        if !rtCleanupInProgress {
            rtCleanupInProgress = true
            scheduleDeferredCleanup()
        }
    }
}

@MainActor
private func scheduleDeferredCleanup() {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        if rtReaderCount.load(ordering: .acquiring) == 0 {
            for ptr in rtRetiredConfigs {
                ptr.deinitialize(count: 1)
                ptr.deallocate()
            }
            rtRetiredConfigs.removeAll()
            rtCleanupInProgress = false
        } else {
            scheduleDeferredCleanup()
        }
    }
}

@MainActor
private func purgeConfigs() {
    let oldPtr = rtActiveConfig.exchange(nil, ordering: .acquiringAndReleasing)
    if let oldPtr = oldPtr {
        retireConfig(oldPtr)
    }
    cleanUpRetiredConfigs()
}

private struct DSPResources {
    // Immutable format metadata
    let sampleRate: Float
    let channelCount: Int
    
    // SPSC Ring Buffer (wrapped in Unmanaged to prevent ARC retain/release on the audio thread)
    let ringBuffer: Unmanaged<AudioRingBuffer>
    
    // Scratch and IO interleave buffers (pre-allocated)
    let scratchBuffer: UnsafeMutablePointer<Float>
    let scratchCapacity: Int
    // Unprocessed copy of the render input, used to crossfade dry/wet while
    // the effect mix ramps in after a start.
    let dryBuffer: UnsafeMutablePointer<Float>
    let dryBufferCapacity: Int
    let ioInterleaveBuffer: UnsafeMutablePointer<Float>?
    let ioInterleaveCapacity: Int
    
    // Lowpass filter states (pre-allocated)
    let lowpassState: UnsafeMutablePointer<Float>
    let lowpassStateCapacity: Int
    let bassHarmonicsLowpassState2: UnsafeMutablePointer<Float>
    let bassHarmonicsLowpassStage2State1: UnsafeMutablePointer<Float>
    let bassHarmonicsLowpassStage2State2: UnsafeMutablePointer<Float>
    let bassHarmonicsBandpassState1: UnsafeMutablePointer<Float>
    let bassHarmonicsBandpassState2: UnsafeMutablePointer<Float>
    let bassHarmonicsDCInputState: UnsafeMutablePointer<Float>
    let bassHarmonicsDCOutputState: UnsafeMutablePointer<Float>
    let bassHarmonicsEnvelopeState: UnsafeMutablePointer<Float>
    let bassFocusLowpassState: UnsafeMutablePointer<Float>
    let bassFocusLowpassStateCapacity: Int
    let lowEndGuardLowpassState: UnsafeMutablePointer<Float>
    let lowEndGuardLowpassStateCapacity: Int
    let bassCompLowpassState1: UnsafeMutablePointer<Float>
    let bassCompLowpassState2: UnsafeMutablePointer<Float>
    let bassCompEnvelopeState: UnsafeMutablePointer<Float>
    let bassCompGainState: UnsafeMutablePointer<Float>

    // Rear surround delay lines and lowpass states
    let rearDelayLineLeft: UnsafeMutablePointer<Float>?
    let rearDelayLineRight: UnsafeMutablePointer<Float>?
    let rearDelayLineCapacity: Int
    var rearDelayLineIndex: Int
    var rearLowpassLeft: Float
    var rearLowpassRight: Float
    
    // Dynamic states mutated on the real-time callback thread
    var bassFocusEnvelope: Float
    var bassFocusCurrentHighGain: Float
    
    var lowEndGuardCurrentLowGain: Float
    var lowEndGuardPeakLinear: Float
    var lowEndGuardAverageReductionGain: Float
    var lowEndGuardObservedMinGain: Float
    var lowEndGuardMeasurementCount: UInt64
}

private let rtActiveResources = ManagedAtomic<UnsafeMutablePointer<DSPResources>?>(nil)
nonisolated(unsafe) private var rtRetiredResources: [UnsafeMutablePointer<DSPResources>] = []
nonisolated(unsafe) private var rtResourceCleanupInProgress = false

@MainActor
private func deallocateResources(_ ptr: UnsafeMutablePointer<DSPResources>) {
    ptr.pointee.scratchBuffer.deallocate()
    ptr.pointee.dryBuffer.deallocate()
    ptr.pointee.ioInterleaveBuffer?.deallocate()
    ptr.pointee.lowpassState.deallocate()
    ptr.pointee.bassHarmonicsLowpassState2.deallocate()
    ptr.pointee.bassHarmonicsLowpassStage2State1.deallocate()
    ptr.pointee.bassHarmonicsLowpassStage2State2.deallocate()
    ptr.pointee.bassHarmonicsBandpassState1.deallocate()
    ptr.pointee.bassHarmonicsBandpassState2.deallocate()
    ptr.pointee.bassHarmonicsDCInputState.deallocate()
    ptr.pointee.bassHarmonicsDCOutputState.deallocate()
    ptr.pointee.bassHarmonicsEnvelopeState.deallocate()
    ptr.pointee.bassFocusLowpassState.deallocate()
    ptr.pointee.lowEndGuardLowpassState.deallocate()
    ptr.pointee.bassCompLowpassState1.deallocate()
    ptr.pointee.bassCompLowpassState2.deallocate()
    ptr.pointee.bassCompEnvelopeState.deallocate()
    ptr.pointee.bassCompGainState.deallocate()
    ptr.pointee.rearDelayLineLeft?.deallocate()
    ptr.pointee.rearDelayLineRight?.deallocate()
    
    // Release the ring buffer reference (decrement ARC count)
    ptr.pointee.ringBuffer.release()
    
    ptr.deinitialize(count: 1)
    ptr.deallocate()
}

@MainActor
private func retireResources(_ oldPtr: UnsafeMutablePointer<DSPResources>) {
    rtRetiredResources.append(oldPtr)
    cleanUpRetiredResources()
}

@MainActor
private func cleanUpRetiredResources() {
    guard !rtRetiredResources.isEmpty else { return }
    
    if rtReaderCount.load(ordering: .acquiring) == 0 {
        for ptr in rtRetiredResources {
            deallocateResources(ptr)
        }
        rtRetiredResources.removeAll()
        rtResourceCleanupInProgress = false
    } else {
        if !rtResourceCleanupInProgress {
            rtResourceCleanupInProgress = true
            scheduleDeferredResourceCleanup()
        }
    }
}

@MainActor
private func scheduleDeferredResourceCleanup() {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        if rtReaderCount.load(ordering: .acquiring) == 0 {
            for ptr in rtRetiredResources {
                deallocateResources(ptr)
            }
            rtRetiredResources.removeAll()
            rtResourceCleanupInProgress = false
        } else {
            scheduleDeferredResourceCleanup()
        }
    }
}

@MainActor
private func purgeResources() {
    let oldPtr = rtActiveResources.exchange(nil, ordering: .acquiringAndReleasing)
    if let oldPtr = oldPtr {
        retireResources(oldPtr)
    }
    cleanUpRetiredResources()
}

@MainActor
private func setupResources(sampleRate: Double, channels: Int, ringBuf: AudioRingBuffer) {
    let preallocCapacity = 8192 * channels
    let lowpassCapacity = max(16, channels)
    let surroundCapacity = max(1024, Int(sampleRate * 0.06))
    
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: preallocCapacity)
    let dry = UnsafeMutablePointer<Float>.allocate(capacity: preallocCapacity)
    let interleave = UnsafeMutablePointer<Float>.allocate(capacity: preallocCapacity)
    let lp = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let lp2 = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let lpStage2_1 = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let lpStage2_2 = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let bp1 = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let bp2 = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let dcIn = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let dcOut = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let bassEnv = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let lpBF = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let lpLEG = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let bcLP1 = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let bcLP2 = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let bcEnv = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let bcGain = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)

    scratch.initialize(repeating: 0, count: preallocCapacity)
    dry.initialize(repeating: 0, count: preallocCapacity)
    interleave.initialize(repeating: 0, count: preallocCapacity)
    lp.initialize(repeating: 0, count: lowpassCapacity)
    lp2.initialize(repeating: 0, count: lowpassCapacity)
    lpStage2_1.initialize(repeating: 0, count: lowpassCapacity)
    lpStage2_2.initialize(repeating: 0, count: lowpassCapacity)
    bp1.initialize(repeating: 0, count: lowpassCapacity)
    bp2.initialize(repeating: 0, count: lowpassCapacity)
    dcIn.initialize(repeating: 0, count: lowpassCapacity)
    dcOut.initialize(repeating: 0, count: lowpassCapacity)
    bassEnv.initialize(repeating: 0, count: lowpassCapacity)
    lpBF.initialize(repeating: 0, count: lowpassCapacity)
    lpLEG.initialize(repeating: 0, count: lowpassCapacity)
    bcLP1.initialize(repeating: 0, count: lowpassCapacity)
    bcLP2.initialize(repeating: 0, count: lowpassCapacity)
    bcEnv.initialize(repeating: 0, count: lowpassCapacity)
    bcGain.initialize(repeating: 1, count: lowpassCapacity)

    var delayL: UnsafeMutablePointer<Float>? = nil
    var delayR: UnsafeMutablePointer<Float>? = nil
    if channels >= 2 {
        let dl = UnsafeMutablePointer<Float>.allocate(capacity: surroundCapacity)
        let dr = UnsafeMutablePointer<Float>.allocate(capacity: surroundCapacity)
        dl.initialize(repeating: 0, count: surroundCapacity)
        dr.initialize(repeating: 0, count: surroundCapacity)
        delayL = dl
        delayR = dr
    }
    
    let ringBufUnmanaged = Unmanaged.passRetained(ringBuf)
    
    let newResources = DSPResources(
        sampleRate: Float(sampleRate),
        channelCount: channels,
        ringBuffer: ringBufUnmanaged,
        scratchBuffer: scratch,
        scratchCapacity: preallocCapacity,
        dryBuffer: dry,
        dryBufferCapacity: preallocCapacity,
        ioInterleaveBuffer: interleave,
        ioInterleaveCapacity: preallocCapacity,
        lowpassState: lp,
        lowpassStateCapacity: lowpassCapacity,
        bassHarmonicsLowpassState2: lp2,
        bassHarmonicsLowpassStage2State1: lpStage2_1,
        bassHarmonicsLowpassStage2State2: lpStage2_2,
        bassHarmonicsBandpassState1: bp1,
        bassHarmonicsBandpassState2: bp2,
        bassHarmonicsDCInputState: dcIn,
        bassHarmonicsDCOutputState: dcOut,
        bassHarmonicsEnvelopeState: bassEnv,
        bassFocusLowpassState: lpBF,
        bassFocusLowpassStateCapacity: lowpassCapacity,
        lowEndGuardLowpassState: lpLEG,
        lowEndGuardLowpassStateCapacity: lowpassCapacity,
        bassCompLowpassState1: bcLP1,
        bassCompLowpassState2: bcLP2,
        bassCompEnvelopeState: bcEnv,
        bassCompGainState: bcGain,
        rearDelayLineLeft: delayL,
        rearDelayLineRight: delayR,
        rearDelayLineCapacity: channels >= 2 ? surroundCapacity : 0,
        rearDelayLineIndex: 0,
        rearLowpassLeft: 0,
        rearLowpassRight: 0,
        bassFocusEnvelope: 0,
        bassFocusCurrentHighGain: 1,
        lowEndGuardCurrentLowGain: 1,
        lowEndGuardPeakLinear: 0,
        lowEndGuardAverageReductionGain: 1,
        lowEndGuardObservedMinGain: 1,
        lowEndGuardMeasurementCount: 0
    )
    
    let newResourcesPtr = UnsafeMutablePointer<DSPResources>.allocate(capacity: 1)
    newResourcesPtr.initialize(to: newResources)
    
    let oldResourcesPtr = rtActiveResources.exchange(newResourcesPtr, ordering: .acquiringAndReleasing)
    if let oldResourcesPtr = oldResourcesPtr {
        retireResources(oldResourcesPtr)
    }
}

private let rtOutputVolumeScalarBits = ManagedAtomic<UInt32>(Float(0.60).bitPattern)

private let rtRenderCallbackCount = ManagedAtomic<UInt64>(0)
private let rtIOCallbackCount = ManagedAtomic<UInt64>(0)
private let rtUnderrunCount = ManagedAtomic<UInt64>(0)
private let rtUnderrunSampleCount = ManagedAtomic<UInt64>(0)
private let rtLastUnderrunSamples = ManagedAtomic<UInt64>(0)
private let rtDroppedSampleCount = ManagedAtomic<UInt64>(0)
private let rtAvailableSamples = ManagedAtomic<UInt64>(0)
private let rtQueuedAfterRenderSamples = ManagedAtomic<UInt64>(0)
private let rtLastInputFrameCount = ManagedAtomic<UInt64>(0)
private let rtLastRenderFrameCount = ManagedAtomic<UInt64>(0)
private let rtLastRenderDurationTicks = ManagedAtomic<UInt64>(0)
private let rtMaxRenderDurationTicks = ManagedAtomic<UInt64>(0)
private let rtIdleRenderCallbackCount = ManagedAtomic<UInt64>(0)
private let rtNeedsPriming = ManagedAtomic<UInt32>(1)
// mach_absolute_time of the last tapped buffer that contained audible samples.
// Written by the IO callback, read on the main actor for auto-standby.
private let rtLastAudibleHostTime = ManagedAtomic<UInt64>(0)
// -60 dBFS: high enough to ignore mixer noise floor / dither that some
// processes emit while "silent", low enough to catch real playback.
private let audibleSampleThreshold: Float = 0.001

// Global dry/wet mix for the custom DSP chain (0 = bypass, 1 = full effects).
// Ramped on the main actor after each engine start so processing fades in
// instead of snapping on; read by the render callback.
private let rtEffectMixBits = ManagedAtomic<UInt32>(Float(1).bitPattern)
// Peak of the most recent audible input buffer, for diagnostics.
private let rtLastAudiblePeakBits = ManagedAtomic<UInt32>(0)

private func loadEffectMix() -> Float {
    let value = Float(bitPattern: rtEffectMixBits.load(ordering: .relaxed))
    guard value.isFinite else { return 1 }
    return min(max(value, 0), 1)
}

private func storeEffectMix(_ mix: Float) {
    rtEffectMixBits.store(min(max(mix, 0), 1).bitPattern, ordering: .relaxed)
}

private let machTimebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

private func renderCallback(
    _: UnsafeMutablePointer<ObjCBool>,
    _: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32,
    audioBufferList: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    let callbackStart = mach_absolute_time()
    defer {
        let elapsed = mach_absolute_time() &- callbackStart
        rtLastRenderDurationTicks.store(elapsed, ordering: .relaxed)
        storeAtomicMax(rtMaxRenderDurationTicks, elapsed)
        rtLastRenderFrameCount.store(UInt64(frameCount), ordering: .relaxed)
        rtRenderCallbackCount.wrappingIncrement(ordering: .relaxed)
    }

    rtReaderCount.wrappingIncrement(ordering: .acquiring)
    defer {
        rtReaderCount.wrappingDecrement(ordering: .releasing)
    }

    let config: DSPConfig
    if let configPtr = rtActiveConfig.load(ordering: .acquiring) {
        config = configPtr.pointee
    } else {
        config = currentFallbackConfig()
    }

    guard let resourcesPtr = rtActiveResources.load(ordering: .acquiring) else {
        clearOutputBuffers(audioBufferList)
        return noErr
    }
    let ringBuf = resourcesPtr.pointee.ringBuffer.takeUnretainedValue()
    let ch = resourcesPtr.pointee.channelCount
    let frames = Int(frameCount)
    guard ch > 0, frames > 0, frames <= Int.max / ch else {
        clearOutputBuffers(audioBufferList)
        return noErr
    }
    let interleavedCount = frames * ch
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)

    guard resourcesPtr.pointee.scratchCapacity >= interleavedCount else {
        clearOutputBuffers(audioBufferList)
        return noErr
    }
    let scratch = resourcesPtr.pointee.scratchBuffer

    // Keep two render quanta plus the requested latency. If the render callback runs
    // just before the input callback, this still leaves the requested latency queued.
    let requestedLatencySamples = Int(config.sampleRate * config.maxRealtimeLatencySeconds) * ch
    let maxBufferedSamples = max(interleavedCount, interleavedCount * 2 + requestedLatencySamples)
    if rtNeedsPriming.load(ordering: .relaxed) != 0 {
        let available = max(ringBuf.availableToRead, 0)
        rtAvailableSamples.store(UInt64(available), ordering: .relaxed)
        rtQueuedAfterRenderSamples.store(UInt64(available), ordering: .relaxed)

        guard available >= maxBufferedSamples else {
            rtIdleRenderCallbackCount.wrappingIncrement(ordering: .relaxed)
            clearOutputBuffers(audioBufferList)
            return noErr
        }

        rtNeedsPriming.store(0, ordering: .relaxed)
    }

    let trimmedSamples = ringBuf.trimToLatest(maxSamples: maxBufferedSamples)
    if trimmedSamples > 0 {
        rtDroppedSampleCount.wrappingIncrement(by: UInt64(trimmedSamples), ordering: .relaxed)
    }
    rtAvailableSamples.store(UInt64(max(ringBuf.availableToRead, 0)), ordering: .relaxed)

    let read = ringBuf.read(scratch, count: interleavedCount)
    rtQueuedAfterRenderSamples.store(UInt64(max(ringBuf.availableToRead, 0)), ordering: .relaxed)

    if read == 0 {
        rtNeedsPriming.store(1, ordering: .relaxed)
        rtIdleRenderCallbackCount.wrappingIncrement(ordering: .relaxed)
        rtUnderrunCount.wrappingIncrement(ordering: .relaxed)
        rtUnderrunSampleCount.wrappingIncrement(by: UInt64(interleavedCount), ordering: .relaxed)
        rtLastUnderrunSamples.store(UInt64(interleavedCount), ordering: .relaxed)
        clearOutputBuffers(audioBufferList)
        return noErr
    }

    if read < interleavedCount {
        rtNeedsPriming.store(1, ordering: .relaxed)
        // Zero-fill remaining frames if buffer underrun
        let missingSamples = interleavedCount - read
        rtUnderrunCount.wrappingIncrement(ordering: .relaxed)
        rtUnderrunSampleCount.wrappingIncrement(by: UInt64(missingSamples), ordering: .relaxed)
        rtLastUnderrunSamples.store(UInt64(missingSamples), ordering: .relaxed)
        memset(scratch.advanced(by: read), 0, missingSamples * MemoryLayout<Float>.size)
    }

    let effectMix = loadEffectMix()
    if effectMix < 0.999, resourcesPtr.pointee.dryBufferCapacity >= interleavedCount {
        // Fade-in after start: keep the DSP state advancing, but crossfade the
        // custom-chain output with the untouched input.
        let dry = resourcesPtr.pointee.dryBuffer
        memcpy(dry, scratch, interleavedCount * MemoryLayout<Float>.size)
        applyRealtimeEffects(scratch, frames: frames, channels: ch, config: config, resources: resourcesPtr)
        let dryGain = 1 - effectMix
        for sampleIndex in 0..<interleavedCount {
            scratch[sampleIndex] = dry[sampleIndex] * dryGain + scratch[sampleIndex] * effectMix
        }
    } else {
        applyRealtimeEffects(scratch, frames: frames, channels: ch, config: config, resources: resourcesPtr)
    }

    for i in 0..<bufferList.count {
        guard i < ch else { break }
        guard let outData = bufferList[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let channelIndex = i
        for f in 0..<frames {
            outData[f] = scratch[f * ch + channelIndex]
        }
    }

    return noErr
}

private func clearOutputBuffers(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for buffer in bufferList {
        if let data = buffer.mData {
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}


private func estimatedCrossTalkDelaySamples(
    sampleRate: Double,
    listenerDistanceCm: Float,
    headHeightCm: Float
) -> Int {
    let speakerSpacingMeters = 0.26
    let listeningDistanceMeters = Double(max(listenerDistanceCm, 25)) / 100
    let headHeightMeters = Double(max(headHeightCm, 0)) / 100
    let earSpacingMeters = 0.18
    let speedOfSoundMetersPerSecond = 343.0
    let ipsilateralX = (speakerSpacingMeters - earSpacingMeters) * 0.5
    let contralateralX = (speakerSpacingMeters + earSpacingMeters) * 0.5
    let ipsilateralDistance = sqrt(
        ipsilateralX * ipsilateralX
            + listeningDistanceMeters * listeningDistanceMeters
            + headHeightMeters * headHeightMeters
    )
    let contralateralDistance = sqrt(
        contralateralX * contralateralX
            + listeningDistanceMeters * listeningDistanceMeters
            + headHeightMeters * headHeightMeters
    )
    let delaySeconds = max(0.00005, (contralateralDistance - ipsilateralDistance) / speedOfSoundMetersPerSecond)
    return max(1, Int((delaySeconds * sampleRate).rounded()))
}

private func modeledRearDelayMilliseconds(for surround: SurroundEffectConfig) -> Float {
    let listenerDistanceCm = finiteOrDefault(surround.listenerDistanceCm, default: SpatialTuning.default.listenerDistanceCm)
    let headHeightCm = finiteOrDefault(surround.headHeightCm, default: defaultSpatialHeadHeightCm)
    let displayAngleDegrees = finiteOrDefault(surround.displayAngleDegrees, default: defaultSpatialDisplayAngleDegrees)
    let rearDelayMs = finiteOrDefault(surround.rearDelayMs, default: 4.2)
    let distanceDelta = (listenerDistanceCm - SpatialTuning.default.listenerDistanceCm) / 10
    let heightDelta = (headHeightCm - defaultSpatialHeadHeightCm) / 10
    let angleDelta = (displayAngleDegrees - defaultSpatialDisplayAngleDegrees) / 15
    let modeled = rearDelayMs
        + distanceDelta * 0.30
        + heightDelta * 0.18
        + angleDelta * 0.35
    return min(max(modeled, 0.5), 30)
}

private func modeledRearShadow(for surround: SurroundEffectConfig) -> Float {
    let headHeightCm = finiteOrDefault(surround.headHeightCm, default: defaultSpatialHeadHeightCm)
    let displayAngleDegrees = finiteOrDefault(surround.displayAngleDegrees, default: defaultSpatialDisplayAngleDegrees)
    let rearShadow = finiteOrDefault(surround.rearShadow, default: 55)
    let heightDelta = (headHeightCm - defaultSpatialHeadHeightCm) / 10
    let angleDelta = (displayAngleDegrees - defaultSpatialDisplayAngleDegrees) / 15
    let modeled = rearShadow
        + heightDelta * 5
        + angleDelta * 3
    return min(max(modeled, 0), 100)
}

private func modeledSpatialStrength(for surround: SurroundEffectConfig) -> Float {
    min(max(surround.spatialStrengthPercent / 100, 0.60), 1.40)
}

private func modeledReverbWetDryMix(for surround: SurroundEffectConfig) -> Float {
    let spatialStrength = modeledSpatialStrength(for: surround)
    return min(max(surround.reverbMix * (0.90 + spatialStrength * 0.10), 0), 50)
}

private func applyRealtimeEffects(
    _ samples: UnsafeMutablePointer<Float>,
    frames: Int,
    channels: Int,
    config: DSPConfig,
    resources: UnsafeMutablePointer<DSPResources>
) {
    if config.bassCompAmount > 0.0001, resources.pointee.lowpassStateCapacity >= channels {
        let lowpass = config.bassCompLowpass
        let state1 = resources.pointee.bassCompLowpassState1
        let state2 = resources.pointee.bassCompLowpassState2
        let envelopeState = resources.pointee.bassCompEnvelopeState
        let gainState = resources.pointee.bassCompGainState
        let attack = config.bassCompEnvelopeAttack
        let release = config.bassCompEnvelopeRelease
        let gainSmoothing = config.bassCompGainSmoothing
        let threshold = config.bassCompThresholdLinear
        let invThreshold = config.bassCompInvThresholdLinear
        let maxMakeup = config.bassCompMaxMakeupGain

        for frame in 0..<frames {
            for channel in 0..<channels {
                let index = frame * channels + channel
                let input = samples[index]
                let low = lowpass.b0 * input + state1[channel]
                state1[channel] = lowpass.b1 * input - lowpass.a1 * low + state2[channel]
                state2[channel] = lowpass.b2 * input - lowpass.a2 * low
                let high = input - low

                let detector = fabsf(low)
                var envelope = envelopeState[channel]
                envelope += (detector - envelope) * (detector > envelope ? attack : release)
                envelopeState[channel] = envelope

                // Upward compression: makeup ramps linearly from 1 (at threshold)
                // to maxMakeup (at silence); envelope of true silence is 0, so
                // silence-in still yields silence-out (gain * 0 == 0).
                let position = min(max((threshold - envelope) * invThreshold, 0), 1)
                let targetGain = 1 + (maxMakeup - 1) * position
                var gain = gainState[channel]
                gain += (targetGain - gain) * gainSmoothing
                gainState[channel] = gain

                samples[index] = low * gain + high
            }
        }
    }

    if config.bassHarmonicsAmount > 0.0001, resources.pointee.lowpassStateCapacity >= channels {
        let lowpassState1 = resources.pointee.lowpassState
        let lowpassState2 = resources.pointee.bassHarmonicsLowpassState2
        let lowpassStage2State1 = resources.pointee.bassHarmonicsLowpassStage2State1
        let lowpassStage2State2 = resources.pointee.bassHarmonicsLowpassStage2State2
        let bandpassState1 = resources.pointee.bassHarmonicsBandpassState1
        let bandpassState2 = resources.pointee.bassHarmonicsBandpassState2
        let dcInputState = resources.pointee.bassHarmonicsDCInputState
        let dcOutputState = resources.pointee.bassHarmonicsDCOutputState
        let envelopeState = resources.pointee.bassHarmonicsEnvelopeState
        let amount = min(max(config.bassHarmonicsAmount / 100, 0), 1)
        let amountGain = amount * 0.90
        let lowpass = config.bassHarmonicsLowpass
        let bandpass = config.bassHarmonicsBandpass
        let dcPole = config.bassHarmonicsDCPole
        let attack = config.bassHarmonicsEnvelopeAttack
        let release = config.bassHarmonicsEnvelopeRelease

        for frame in 0..<frames {
            for channel in 0..<channels {
                let index = frame * channels + channel
                let input = samples[index]
                let lowStage1 = lowpass.b0 * input + lowpassState1[channel]
                lowpassState1[channel] = lowpass.b1 * input - lowpass.a1 * lowStage1 + lowpassState2[channel]
                lowpassState2[channel] = lowpass.b2 * input - lowpass.a2 * lowStage1

                let low = lowpass.b0 * lowStage1 + lowpassStage2State1[channel]
                lowpassStage2State1[channel] = lowpass.b1 * lowStage1 - lowpass.a1 * low + lowpassStage2State2[channel]
                lowpassStage2State2[channel] = lowpass.b2 * lowStage1 - lowpass.a2 * low

                let detector = fabsf(low)
                var envelope = envelopeState[channel]
                let envelopeSmoothing = detector > envelope ? attack : release
                envelope += (detector - envelope) * envelopeSmoothing
                envelopeState[channel] = envelope

                let normalized = min(max(low / max(envelope, 0.000_001), -1), 1)
                let normalized2 = normalized * normalized
                let normalized3 = normalized2 * normalized
                let secondHarmonic = 2 * normalized2
                let thirdHarmonic = 4 * normalized3 - 3 * normalized
                let generated = (secondHarmonic + 0.5 * thirdHarmonic) * envelope

                let dcBlocked = generated - dcInputState[channel] + dcPole * dcOutputState[channel]
                dcInputState[channel] = generated
                dcOutputState[channel] = dcBlocked

                let harmonic = bandpass.b0 * dcBlocked + bandpassState1[channel]
                bandpassState1[channel] = bandpass.b1 * dcBlocked - bandpass.a1 * harmonic + bandpassState2[channel]
                bandpassState2[channel] = bandpass.b2 * dcBlocked - bandpass.a2 * harmonic

                samples[index] = input + harmonic * amountGain
            }
        }
    }

    applyBassFocus(samples, frames: frames, channels: channels, config: config, resources: resources)
    applyRearSurround(samples, frames: frames, channels: channels, config: config, resources: resources)

    if channels >= 2, config.stereoWidth > 0.0001 {
        let widthGain = 1 + min(max(config.stereoWidth / 100, 0), 1) * 0.85
        for frame in 0..<frames {
            let leftIndex = frame * channels
            let rightIndex = leftIndex + 1
            let left = samples[leftIndex]
            let right = samples[rightIndex]
            let mid = (left + right) * 0.5
            let side = (left - right) * 0.5 * widthGain
            samples[leftIndex] = mid + side
            samples[rightIndex] = mid - side
        }
    }

    applyLowEndGuard(samples, frames: frames, channels: channels, config: config, resources: resources)

    if config.softLimitDrive > 0.0001 {
        // Pade approximation of tanh keeps the render path free of libm;
        // |x| clamped to 3 where the approximation saturates at +/-1.
        let driveGain = config.softLimitDriveGain
        let total = frames * channels
        for index in 0..<total {
            let x = min(max(samples[index] * driveGain, -3), 3)
            let x2 = x * x
            samples[index] = x * (27 + x2) / (27 + 9 * x2)
        }
    }
}

private func applyLowEndGuard(
    _ samples: UnsafeMutablePointer<Float>,
    frames: Int,
    channels: Int,
    config: DSPConfig,
    resources: UnsafeMutablePointer<DSPResources>
) {
    guard frames > 0, channels > 0, config.lowEndGuardAmount > 0.0001 else {
        resources.pointee.lowEndGuardCurrentLowGain += (1 - resources.pointee.lowEndGuardCurrentLowGain) * 0.06
        return
    }

    guard resources.pointee.lowEndGuardLowpassStateCapacity >= channels else { return }
    let lowpassState = resources.pointee.lowEndGuardLowpassState

    let volumeActivation = smoothstep(edge0: 0.86, edge1: 1.0, x: loadRealtimeOutputVolumeScalar())
    let amount = min(max(config.lowEndGuardAmount / 100, 0), 1) * volumeActivation
    guard amount > 0.0001 else {
        resources.pointee.lowEndGuardCurrentLowGain += (1 - resources.pointee.lowEndGuardCurrentLowGain) * 0.08
        resources.pointee.lowEndGuardPeakLinear = 0
        return
    }

    let cutoff = min(max(config.lowEndGuardCutoffHz, 90), 260)
    let alpha = min(max((2 * Float.pi * cutoff) / (2 * Float.pi * cutoff + config.sampleRate), 0.003), 0.12)
    let lowGain = min(max(resources.pointee.lowEndGuardCurrentLowGain, config.lowEndGuardMaxReductionGain), 1)
    var lowPeak: Float = 0

    for frame in 0..<frames {
        for channel in 0..<channels {
            let index = frame * channels + channel
            let input = samples[index]
            let low = lowpassState[channel] + alpha * (input - lowpassState[channel])
            lowpassState[channel] = low
            lowPeak = max(lowPeak, fabsf(low))
            samples[index] = (input - low) + low * lowGain
        }
    }

    resources.pointee.lowEndGuardPeakLinear = lowPeak
    let threshold = max(config.lowEndGuardThresholdLinear, 0.000_001)
    let ratio = min(max(config.lowEndGuardRatio, 1.5), 12)
    let overThreshold = max((lowPeak - threshold) / threshold, 0)
    let compression = max(0, 1 - 1 / ratio)
    let targetLowGain = max(1 / (1 + overThreshold * compression * amount), config.lowEndGuardMaxReductionGain)
    let smoothing: Float = targetLowGain < resources.pointee.lowEndGuardCurrentLowGain ? 0.32 : 0.055
    resources.pointee.lowEndGuardCurrentLowGain += (targetLowGain - resources.pointee.lowEndGuardCurrentLowGain) * smoothing
    resources.pointee.lowEndGuardObservedMinGain = min(resources.pointee.lowEndGuardObservedMinGain, resources.pointee.lowEndGuardCurrentLowGain)
    resources.pointee.lowEndGuardMeasurementCount &+= 1
    let count = Float(min(resources.pointee.lowEndGuardMeasurementCount, UInt64(UInt32.max)))
    resources.pointee.lowEndGuardAverageReductionGain += (resources.pointee.lowEndGuardCurrentLowGain - resources.pointee.lowEndGuardAverageReductionGain) / max(count, 1)
}

private func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
    let t = min(max((x - edge0) / max(edge1 - edge0, 0.0001), 0), 1)
    return t * t * (3 - 2 * t)
}

private func loadRealtimeOutputVolumeScalar() -> Float {
    let value = Float(bitPattern: rtOutputVolumeScalarBits.load(ordering: .relaxed))
    guard value.isFinite else { return 0.60 }
    return min(max(value, 0), 1)
}

private func storeRealtimeOutputVolumeScalar(_ scalar: Float) {
    let clamped = min(max(scalar, 0), 1)
    rtOutputVolumeScalarBits.store(clamped.bitPattern, ordering: .relaxed)
}

private func applyBassFocus(
    _ samples: UnsafeMutablePointer<Float>,
    frames: Int,
    channels: Int,
    config: DSPConfig,
    resources: UnsafeMutablePointer<DSPResources>
) {
    guard frames > 0, channels > 0, config.bassFocusAmount > 0.0001 else {
        resources.pointee.bassFocusEnvelope *= 0.98
        resources.pointee.bassFocusCurrentHighGain += (1 - resources.pointee.bassFocusCurrentHighGain) * 0.16
        return
    }

    guard resources.pointee.bassFocusLowpassStateCapacity >= channels else { return }
    let lowpassState = resources.pointee.bassFocusLowpassState

    let systemVolume = loadRealtimeOutputVolumeScalar()
    let target = smoothstep(edge0: 0.58, edge1: 0.92, x: systemVolume)
    let smoothing: Float = target > resources.pointee.bassFocusEnvelope ? 0.16 : 0.025
    resources.pointee.bassFocusEnvelope += (target - resources.pointee.bassFocusEnvelope) * smoothing

    let amount = min(max(config.bassFocusAmount / 100, 0), 1)
    let targetHighGain = 1 + (config.bassFocusMaxHighCutGain - 1) * resources.pointee.bassFocusEnvelope
    let gainSmoothing: Float = targetHighGain < resources.pointee.bassFocusCurrentHighGain ? 0.16 : 0.025
    resources.pointee.bassFocusCurrentHighGain += (targetHighGain - resources.pointee.bassFocusCurrentHighGain) * gainSmoothing
    let highGain = min(max(resources.pointee.bassFocusCurrentHighGain, config.bassFocusMaxHighCutGain), 1)
    let cutoff = 2_650 - amount * 950
    let alpha = min(max((2 * Float.pi * cutoff) / (2 * Float.pi * cutoff + config.sampleRate), 0.02), 0.45)

    for frame in 0..<frames {
        for channel in 0..<channels {
            let index = frame * channels + channel
            let input = samples[index]
            let low = lowpassState[channel] + alpha * (input - lowpassState[channel])
            lowpassState[channel] = low
            samples[index] = low + (input - low) * highGain
        }
    }
}

private func applyRearSurround(
    _ samples: UnsafeMutablePointer<Float>,
    frames: Int,
    channels: Int,
    config: DSPConfig,
    resources: UnsafeMutablePointer<DSPResources>
) {
    guard channels >= 2,
          config.rearSurroundAmount > 0.0001,
          resources.pointee.rearDelayLineCapacity > 1,
          let delayLeft = resources.pointee.rearDelayLineLeft,
          let delayRight = resources.pointee.rearDelayLineRight else { return }

    let amount = min(max(config.rearSurroundAmount / 100, 0), 1)
    let wet = 0.18 + amount * 0.34
    let selfCancel = 0.12 + amount * 0.12
    let dryTrim = 1 - wet * 0.10
    let delaySamples = min(max(config.rearSurroundDelaySamples, 1), resources.pointee.rearDelayLineCapacity - 1)
    let crossTalkDelaySamples = min(max(config.crossTalkDelaySamples, 1), resources.pointee.rearDelayLineCapacity - 1)
    let crossTalkCancel = min(max(config.crossTalkCancelAmount, 0), 0.26)
    let shadow = min(max(config.rearSurroundShadow / 100, 0), 1)
    let cutoff = 5_800 - shadow * 3_900
    let alpha = min(max((2 * Float.pi * cutoff) / (2 * Float.pi * cutoff + config.sampleRate), 0.02), 0.65)
    var index = resources.pointee.rearDelayLineIndex

    for frame in 0..<frames {
        let leftIndex = frame * channels
        let rightIndex = leftIndex + 1
        let left = samples[leftIndex]
        let right = samples[rightIndex]
        let readIndex = (index - delaySamples + resources.pointee.rearDelayLineCapacity) % resources.pointee.rearDelayLineCapacity
        let crossTalkReadIndex = (index - crossTalkDelaySamples + resources.pointee.rearDelayLineCapacity) % resources.pointee.rearDelayLineCapacity
        let delayedLeft = delayLeft[readIndex]
        let delayedRight = delayRight[readIndex]
        let crossTalkLeft = delayLeft[crossTalkReadIndex]
        let crossTalkRight = delayRight[crossTalkReadIndex]

        delayLeft[index] = left
        delayRight[index] = right
        index += 1
        if index >= resources.pointee.rearDelayLineCapacity {
            index = 0
        }

        resources.pointee.rearLowpassLeft += alpha * (delayedLeft - resources.pointee.rearLowpassLeft)
        resources.pointee.rearLowpassRight += alpha * (delayedRight - resources.pointee.rearLowpassRight)

        let rearToLeft = resources.pointee.rearLowpassRight - resources.pointee.rearLowpassLeft * selfCancel
        let rearToRight = resources.pointee.rearLowpassLeft - resources.pointee.rearLowpassRight * selfCancel
        samples[leftIndex] = left * dryTrim - crossTalkRight * crossTalkCancel + rearToLeft * wet
        samples[rightIndex] = right * dryTrim - crossTalkLeft * crossTalkCancel + rearToRight * wet
    }

    resources.pointee.rearDelayLineIndex = index
}

// MARK: - Core Audio Helpers
private func caCheck(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else {
        throw NSError(domain: AppInfo.displayName, code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(message): OSStatus \(status)"])
    }
}

private func isSupportedSampleRate(_ sampleRate: Float64) -> Bool {
    sampleRate.isFinite && sampleRate > 0 && sampleRate <= maximumRealtimeSampleRate
}

private func resetRuntimeDiagnostics() {
    rtRenderCallbackCount.store(0, ordering: .relaxed)
    rtIOCallbackCount.store(0, ordering: .relaxed)
    rtUnderrunCount.store(0, ordering: .relaxed)
    rtUnderrunSampleCount.store(0, ordering: .relaxed)
    rtLastUnderrunSamples.store(0, ordering: .relaxed)
    rtDroppedSampleCount.store(0, ordering: .relaxed)
    rtAvailableSamples.store(0, ordering: .relaxed)
    rtQueuedAfterRenderSamples.store(0, ordering: .relaxed)
    rtLastInputFrameCount.store(0, ordering: .relaxed)
    rtLastRenderFrameCount.store(0, ordering: .relaxed)
    rtLastRenderDurationTicks.store(0, ordering: .relaxed)
    rtMaxRenderDurationTicks.store(0, ordering: .relaxed)
    rtIdleRenderCallbackCount.store(0, ordering: .relaxed)
    rtNeedsPriming.store(1, ordering: .relaxed)
    if let resPtr = rtActiveResources.load(ordering: .acquiring) {
        resPtr.pointee.bassFocusCurrentHighGain = 1
        resPtr.pointee.lowEndGuardCurrentLowGain = 1
        resPtr.pointee.lowEndGuardPeakLinear = 0
        resPtr.pointee.lowEndGuardAverageReductionGain = 1
        resPtr.pointee.lowEndGuardObservedMinGain = 1
        resPtr.pointee.lowEndGuardMeasurementCount = 0
    }
}

private func storeAtomicMax(_ atomic: ManagedAtomic<UInt64>, _ value: UInt64) {
    var current = atomic.load(ordering: .relaxed)
    while value > current {
        let result = atomic.compareExchange(
            expected: current,
            desired: value,
            ordering: .relaxed
        )
        if result.exchanged { return }
        current = result.original
    }
}

private func machTicksToMilliseconds(_ ticks: UInt64) -> Double {
    guard machTimebaseInfo.denom != 0 else { return 0 }
    let nanos = Double(ticks) * Double(machTimebaseInfo.numer) / Double(machTimebaseInfo.denom)
    return nanos / 1_000_000
}

private func readOutputVolumeScalar(deviceID: AudioObjectID) -> Float? {
    var masterAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceID, &masterAddress) {
        var scalar: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &masterAddress, 0, nil, &size, &scalar)
        if status == noErr {
            return min(max(scalar, 0), 1)
        }
    }

    var total: Float = 0
    var count: Float = 0
    for element in [UInt32(1), UInt32(2)] {
        var channelAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &channelAddress) else { continue }

        var scalar: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &channelAddress, 0, nil, &size, &scalar)
        if status == noErr {
            total += min(max(scalar, 0), 1)
            count += 1
        }
    }

    return count > 0 ? total / count : nil
}

private func readOutputMute(deviceID: AudioObjectID) -> Bool {
    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &muteAddress) else { return false }

    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &muted)
    return status == noErr && muted != 0
}

/// The set of process objects currently emitting audio output. Unlike
/// kAudioDevicePropertyDeviceIsRunningSomewhere (which stays true whenever any
/// client merely holds the device open), IsRunningOutput only reports live
/// playback, so playback start/stop edges are visible without needing a tap.
private func runningOutputProcessObjects() -> Set<AudioObjectID> {
    var listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize
    ) == noErr, dataSize > 0 else { return [] }

    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var processObjects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize, &processObjects
    ) == noErr else { return [] }

    var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: Set<AudioObjectID> = []
    for processObject in processObjects where processObject != kAudioObjectUnknown {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(processObject, &runningAddress, 0, nil, &size, &isRunning) == noErr,
           isRunning != 0 {
            running.insert(processObject)
        }
    }
    return running
}

private struct AudioBufferFrameSizeRestorePoint {
    let deviceID: AudioObjectID
    let frames: UInt32
}

private enum AudioEngineStartCancellation: Error {
    case superseded
}

private func bufferFrameSizeAddress(
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func withBufferFrameSizeAddress<T>(
    for deviceID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    _ body: (inout AudioObjectPropertyAddress) -> T?
) -> T? {
    let scopes = [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput]
    for scope in scopes {
        var address = bufferFrameSizeAddress(selector: selector, scope: scope)
        guard AudioObjectHasProperty(deviceID, &address) else { continue }
        if let result = body(&address) {
            return result
        }
    }
    return nil
}

private func readBufferFrameSize(deviceID: AudioObjectID) -> UInt32? {
    withBufferFrameSizeAddress(for: deviceID, selector: kAudioDevicePropertyBufferFrameSize) { address in
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
        return status == noErr ? frames : nil
    }
}

private func readBufferFrameSizeRange(deviceID: AudioObjectID) -> AudioValueRange? {
    withBufferFrameSizeAddress(for: deviceID, selector: kAudioDevicePropertyBufferFrameSizeRange) { address in
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &range)
        return status == noErr ? range : nil
    }
}

private func writeBufferFrameSize(deviceID: AudioObjectID, frames: UInt32) -> OSStatus {
    withBufferFrameSizeAddress(for: deviceID, selector: kAudioDevicePropertyBufferFrameSize) { address in
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else {
            return kAudioHardwareIllegalOperationError
        }

        var mutableFrames = frames
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableFrames)
    } ?? kAudioHardwareUnknownPropertyError
}

private func nearestPowerOfTwo(_ value: UInt32) -> UInt32 {
    guard value > 1 else { return 1 }

    var lower: UInt32 = 1
    while lower <= value / 2 {
        lower <<= 1
    }

    let upper = lower <= UInt32.max / 2 ? lower << 1 : lower
    return value - lower < upper - value ? lower : upper
}

private func preferredBufferFrameSize(sampleRate: Double, targetLatencyMs: Float, range: AudioValueRange?) -> UInt32 {
    let minimumStableFrames: UInt32 = 128
    let targetFrames = max(minimumStableFrames, UInt32((sampleRate * Double(max(targetLatencyMs, 0.25)) / 1_000).rounded()))
    var frames = nearestPowerOfTwo(targetFrames)

    if let range {
        let minimum = max(1, UInt32(range.mMinimum.rounded(.up)))
        let maximum = max(minimum, UInt32(range.mMaximum.rounded(.down)))
        frames = min(max(frames, minimum), maximum)
    }

    return max(frames, 1)
}

public struct AudioEngineDiagnostics {
    public let isActive: Bool
    public let engineRunning: Bool
    public let activeDeviceName: String?
    public let sampleRate: Double
    public let channels: UInt32
    public let targetLatencyMs: Double
    public let bufferedLatencyMs: Double
    public let queuedFrames: Int
    public let queuedBeforeRenderMs: Double
    public let queuedBeforeRenderFrames: Int
    public let bufferCapacityMs: Double
    public let bufferFillPercent: Double
    public let requestedBufferFrames: UInt32
    public let outputBufferFrames: UInt32
    public let aggregateBufferFrames: UInt32
    public let effectDelayMs: Double
    public let renderCallbacks: UInt64
    public let idleRenderCallbacks: UInt64
    public let ioCallbacks: UInt64
    public let underruns: UInt64
    public let underrunFrames: UInt64
    public let lastUnderrunFrames: UInt64
    public let droppedFrames: UInt64
    public let lastInputFrameCount: UInt64
    public let lastRenderFrameCount: UInt64
    public let lastRenderDurationMs: Double
    public let maxRenderDurationMs: Double
    public let renderBudgetMs: Double
    public let spatialListenerDistanceCm: Float
    public let spatialHeadHeightCm: Float
    public let spatialDisplayAngleDegrees: Float
    public let spatialStrengthPercent: Float
    public let crossTalkDelayMs: Double
    public let outputVolumePercent: Float
    public let bassFocusAmountPercent: Float
    public let bassFocusReductionDb: Float
    public let lowEndGuardReductionDb: Float
    public let lowEndGuardAverageReductionDb: Float
    public let lowEndGuardMaxReductionDb: Float
    public let lowEndGuardPeakDb: Float
    public let finalSafetyCompressionDb: Float
    public let startedAt: Date?
    public let startCount: UInt64
}

// MARK: - AudioEngineManager
@MainActor
public final class AudioEngineManager {
    public private(set) var isActive = false
    private var activeDeviceID: AudioObjectID?
    private var activeDeviceName: String?
    private var currentConfig: EQConfig?
    private var processingSampleRate: Double = 0
    private var processingChannels: UInt32 = 0
    private var bufferCapacitySamples: Int = 0
    private var outputBufferFrameRestorePoint: AudioBufferFrameSizeRestorePoint?
    private var requestedBufferFrames: UInt32 = 0
    private var outputBufferFrames: UInt32 = 0
    private var aggregateBufferFrames: UInt32 = 0
    private var outputVolumeScalar: Float = 0.60
    private var startedAt: Date?
    private var startCount: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var pendingStartTask: Task<Void, Never>?
    private var effectFadeTask: Task<Void, Never>?
    private var standbyPollTask: Task<Void, Never>?
    // Whether flipping the tap's mute behavior after creation works on this
    // system; when it doesn't, fall back to creating the tap muted (which
    // reintroduces a short dropout at start but never doubled audio).
    private var muteFlipSupported = true

    // Auto-standby: engine torn down while playback is silent so the system
    // audio-capture indicator disappears; device/config kept for resume.
    public private(set) var isInStandby = false
    private var standbyDeviceID: AudioObjectID?
    private var standbyConfig: EQConfig?
    private var standbyBaselinePlayers: Set<AudioObjectID> = []
    private let autoStandbySilenceSeconds: Double = 120

    /// When false, silence never triggers standby — only mute / zero volume
    /// does. Persisted by the app layer.
    public var silenceStandbyEnabled = true

    /// Called on the main actor whenever a serialized start/stop/standby
    /// transition finishes, so the UI can refresh.
    public var onStateChange: (() -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private var eqNode: AVAudioUnitEQ?
    private var delayNode: AVAudioUnitDelay?
    private var reverbNode: AVAudioUnitReverb?
    private var dynamicsNode: AVAudioUnitEffect?
    private var limiterNode: AVAudioUnitEffect?
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: AudioRingBuffer?
    
    public init() {}

    public var canRestart: Bool {
        activeDeviceID != nil && currentConfig != nil
    }

    private func beginLifecycleChange() -> UInt64 {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    private func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        generation == lifecycleGeneration
    }

    private func checkCurrentLifecycle(_ generation: UInt64) throws {
        guard generation == lifecycleGeneration else {
            throw AudioEngineStartCancellation.superseded
        }
        try Task.checkCancellation()
    }

    public func refreshOutputVolumeScalar() {
        refreshOutputVolumeScalar(allowInactive: false)
    }

    private func refreshOutputVolumeScalar(allowInactive: Bool) {
        guard (allowInactive || isActive),
              let activeDeviceID,
              let scalar = readOutputVolumeScalar(deviceID: activeDeviceID) else { return }
        outputVolumeScalar = scalar
        storeRealtimeOutputVolumeScalar(scalar)
    }

    private func requestLowLatencyBufferFrameSize(
        deviceID: AudioObjectID,
        sampleRate: Double,
        targetLatencyMs: Float,
        shouldRestoreOnStop: Bool
    ) {
        let current = readBufferFrameSize(deviceID: deviceID)
        let range = readBufferFrameSizeRange(deviceID: deviceID)
        let preferred = preferredBufferFrameSize(
            sampleRate: sampleRate,
            targetLatencyMs: targetLatencyMs,
            range: range
        )

        requestedBufferFrames = max(requestedBufferFrames, preferred)

        guard current != preferred else {
            updateKnownBufferFrameSize(deviceID: deviceID, frames: current ?? preferred)
            return
        }

        if shouldRestoreOnStop, outputBufferFrameRestorePoint == nil, let current {
            outputBufferFrameRestorePoint = AudioBufferFrameSizeRestorePoint(deviceID: deviceID, frames: current)
        }

        let status = writeBufferFrameSize(deviceID: deviceID, frames: preferred)
        if status != noErr {
            os_log(.default, log: appLog,
                   "%{public}s could not set low-latency buffer size to %u frames on device %u: OSStatus %d",
                   AppInfo.displayName, preferred, deviceID, status)
        }

        updateKnownBufferFrameSize(deviceID: deviceID, frames: readBufferFrameSize(deviceID: deviceID) ?? current ?? preferred)
    }

    private func updateKnownBufferFrameSize(deviceID: AudioObjectID, frames: UInt32) {
        if deviceID == activeDeviceID {
            outputBufferFrames = frames
        } else if deviceID == aggregateDeviceID {
            aggregateBufferFrames = frames
        }
    }

    private func restoreOutputBufferFrameSize() {
        guard let restorePoint = outputBufferFrameRestorePoint else { return }

        let status = writeBufferFrameSize(deviceID: restorePoint.deviceID, frames: restorePoint.frames)
        if status != noErr {
            os_log(.default, log: appLog,
                   "%{public}s could not restore output buffer size to %u frames on device %u: OSStatus %d",
                   AppInfo.displayName, restorePoint.frames, restorePoint.deviceID, status)
        }
        outputBufferFrameRestorePoint = nil
    }
    
    /// Serialized entry point for starting the engine. Cancels any start still
    /// in flight and waits for it to unwind before beginning a new one, so two
    /// starts can never interleave and leak taps or aggregate devices.
    public func requestStart(outputDeviceID: AudioObjectID, config: EQConfig) {
        isInStandby = false
        standbyDeviceID = nil
        standbyConfig = nil

        let previous = pendingStartTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.start(outputDeviceID: outputDeviceID, config: config)
            self?.onStateChange?()
        }
        pendingStartTask = task
    }

    /// Evaluates auto-standby entry. Returns true when the state changed.
    /// Resume is handled by a faster dedicated poll (startStandbyPolling).
    public func updateAutoStandby() -> Bool {
        guard isActive, let deviceID = activeDeviceID, let config = currentConfig else { return false }
        let muted = readOutputMute(deviceID: deviceID)
        let volumeIsZero = outputVolumeScalar <= 0.000_1
        let silentForSeconds = secondsSinceLastAudibleAudio()
        let silenceTriggered = silenceStandbyEnabled && silentForSeconds >= autoStandbySilenceSeconds
        if muted || volumeIsZero || silenceTriggered {
            os_log(.default, log: appLog,
                   "%{public}s entering standby (muted: %d, volumeZero: %d, silentSeconds: %.1f)",
                   AppInfo.displayName, muted ? 1 : 0, volumeIsZero ? 1 : 0, silentForSeconds)
            stop()
            standbyDeviceID = deviceID
            standbyConfig = config
            isInStandby = true
            // Processes already emitting (silent) output when we entered
            // standby (e.g. a browser holding an idle audio stream) must not
            // count as a resume signal; only a playback start edge should.
            // When we stopped because of mute/zero volume the user may still
            // have something playing, so keep the baseline empty there and let
            // unmuting resume immediately.
            standbyBaselinePlayers = (muted || volumeIsZero) ? [] : runningOutputProcessObjects()
            startStandbyPolling()
            return true
        }
        return false
    }

    /// While in standby, watch the output device every 100 ms so processing
    /// resumes almost immediately when playback restarts. The check is two
    /// cheap HAL property reads.
    private func startStandbyPolling() {
        standbyPollTask?.cancel()
        standbyPollTask = Task { @MainActor [weak self] in
            // Grace period: right after we tear the engine down the output
            // device still reports "running somewhere" for a moment, which
            // would resume us instantly and loop standby/start forever.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                guard let self, self.isInStandby else { return }
                if self.tryResumeFromStandby() { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Manual wake, e.g. from the menu: restarts processing immediately
    /// regardless of playback state.
    public func wakeFromStandbyNow() {
        guard isInStandby, let deviceID = standbyDeviceID, let config = standbyConfig else { return }
        os_log(.default, log: appLog, "%{public}s waking from standby (manual)", AppInfo.displayName)
        requestStart(outputDeviceID: deviceID, config: config)
    }

    private func tryResumeFromStandby() -> Bool {
        guard isInStandby, let deviceID = standbyDeviceID, let config = standbyConfig else { return false }

        let playersNow = runningOutputProcessObjects()
        // A baseline process that stops releases its exemption, so its next
        // playback start (a pause -> play in the same app) triggers resume.
        standbyBaselinePlayers.formIntersection(playersNow)
        let hasNewPlayer = !playersNow.subtracting(standbyBaselinePlayers).isEmpty

        let muted = readOutputMute(deviceID: deviceID)
        let volume = readOutputVolumeScalar(deviceID: deviceID) ?? 0
        guard !muted, volume > 0.000_1, hasNewPlayer else { return false }
        os_log(.default, log: appLog, "%{public}s resuming from standby", AppInfo.displayName)
        requestStart(outputDeviceID: deviceID, config: config)
        return true
    }

    /// Ramps processing from bypass to fully applied over ~1.2 s after a
    /// start, so effects blend in instead of snapping on. Covers both the
    /// custom DSP chain (atomic dry/wet mix read by the render callback) and
    /// the AVAudioEngine nodes (EQ gains, delay/reverb wet mix).
    private func beginEffectFadeIn(durationSeconds: Double = 1.2) {
        effectFadeTask?.cancel()
        storeEffectMix(0)
        applyEffectMixToNodes(0)
        effectFadeTask = Task { @MainActor [weak self] in
            let steps = 24
            let stepNanoseconds = UInt64(durationSeconds / Double(steps) * 1_000_000_000)
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: stepNanoseconds)
                guard let self, !Task.isCancelled, self.isActive else { return }
                let mix = Float(step) / Float(steps)
                storeEffectMix(mix)
                self.applyEffectMixToNodes(mix)
            }
        }
    }

    private func cancelEffectFadeIn() {
        effectFadeTask?.cancel()
        effectFadeTask = nil
        storeEffectMix(1)
    }

    private func applyEffectMixToNodes(_ mix: Float) {
        guard let config = currentConfig else { return }
        if let eqNode {
            eqNode.globalGain = config.preamp * mix
            for i in 0..<min(eqNode.bands.count, config.bands.count) {
                eqNode.bands[i].gain = config.bands[i].gain * mix
            }
        }
        delayNode?.wetDryMix = config.effects.delay.mix * mix
        reverbNode?.wetDryMix = modeledReverbWetDryMix(for: config.effects.surround) * mix
    }

    public func secondsSinceLastAudible() -> Double {
        secondsSinceLastAudibleAudio()
    }

    public func lastAudiblePeak() -> Float {
        Float(bitPattern: rtLastAudiblePeakBits.load(ordering: .relaxed))
    }

    private func secondsSinceLastAudibleAudio() -> Double {
        let last = rtLastAudibleHostTime.load(ordering: .relaxed)
        guard last > 0 else { return 0 }
        let now = mach_absolute_time()
        guard now > last else { return 0 }
        return machTicksToMilliseconds(now - last) / 1_000
    }

    public func start(outputDeviceID: AudioObjectID, config: EQConfig) async {
        if isActive && activeDeviceID == outputDeviceID {
            if requiresRestartForLatencyChange(to: config) {
                os_log(.default, log: appLog, "%{public}s restarting to apply latency target change.", AppInfo.displayName)
            } else {
                updateConfig(config)
                return
            }
        }

        let startBeganTicks = mach_absolute_time()
        let generation = beginLifecycleChange()

        stopCurrent()
        
        let info = DeviceMonitor.getDeviceInfo(deviceID: outputDeviceID)
        os_log(.default, log: appLog, "Starting %{public}s on output device: %{public}s (ID: %u)", AppInfo.displayName, info.name, outputDeviceID)
        
        self.activeDeviceID = outputDeviceID
        self.activeDeviceName = info.name
        self.currentConfig = config
        refreshOutputVolumeScalar(allowInactive: true)
        
        do {
            try checkCurrentLifecycle(generation)
            let outputUID = info.uid
            let deviceName = info.name
            
            // 1. Translate our PID -> AudioObjectID to exclude ourselves from the tap
            var translateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var myPID = ProcessInfo.processInfo.processIdentifier
            var myProcessObjectID = AudioObjectID(kAudioObjectUnknown)
            var processObjectSize = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &translateAddress,
                UInt32(MemoryLayout<pid_t>.size), &myPID,
                &processObjectSize, &myProcessObjectID
            )
            
            // 2. Create process tap excluding our app
            let tapUUID = UUID()
            let excludeProcesses: [AudioObjectID] = myProcessObjectID != kAudioObjectUnknown ? [myProcessObjectID] : []
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcesses)
            tapDesc.uuid = tapUUID
            // Start unmuted so the original audio keeps playing while the
            // engine spins up (no audible dropout); switched to muted right
            // after our processed output is running.
            tapDesc.muteBehavior = muteFlipSupported ? .unmuted : .muted
            tapDesc.name = AppInfo.tapName
            
            tapID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(
                AudioHardwareCreateProcessTap(tapDesc, &tapID),
                "Failed to create process tap"
            )
            
            // 3. Read tap format
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var tapFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try caCheck(
                AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &tapFormat),
                "Failed to get tap format"
            )
            let tapSampleRate = tapFormat.mSampleRate
            let channels = tapFormat.mChannelsPerFrame
            guard isSupportedSampleRate(tapSampleRate) else {
                throw NSError(domain: AppInfo.displayName, code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid tap sample rate: \(tapSampleRate)"])
            }
            guard channels > 0, channels <= maximumRealtimeChannelCount else {
                throw NSError(domain: AppInfo.displayName, code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Unsupported tap channel count: \(channels)"])
            }
            
            // Read output device sample rate
            var nominalRateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceSampleRate: Float64 = 0
            var rateSize = UInt32(MemoryLayout<Float64>.size)
            AudioObjectGetPropertyData(outputDeviceID, &nominalRateAddress, 0, nil, &rateSize, &deviceSampleRate)
            
            let sampleRate = isSupportedSampleRate(deviceSampleRate) ? deviceSampleRate : tapSampleRate
            requestedBufferFrames = 0
            outputBufferFrames = readBufferFrameSize(deviceID: outputDeviceID) ?? 0
            aggregateBufferFrames = 0

            requestLowLatencyBufferFrameSize(
                deviceID: outputDeviceID,
                sampleRate: sampleRate,
                targetLatencyMs: config.effects.latency.targetMs,
                shouldRestoreOnStop: true
            )
            
            os_log(.default, log: appLog,
                   "%{public}s: tapRate: %.0f, deviceRate: %.0f, usingRate: %.0f, channels: %u, device: %{public}s",
                   AppInfo.displayName, tapSampleRate, deviceSampleRate, sampleRate, channels, deviceName)
            
            // 4. Create Aggregate Device containing the tap and physical output device
            let aggregateUID = UUID().uuidString
            let aggregateDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: AppInfo.aggregateDeviceName,
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapUUID.uuidString
                    ]
                ]
            ]
            
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(
                AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregateDeviceID),
                "Failed to create aggregate device"
            )
            
            // Wait for aggregate device to be alive (non-blocking)
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            for _ in 1...150 {
                var isAlive: UInt32 = 0
                var aliveSize = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(aggregateDeviceID, &aliveAddress, 0, nil, &aliveSize, &isAlive)
                if isAlive != 0 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
                try checkCurrentLifecycle(generation)
            }
            try checkCurrentLifecycle(generation)

            aggregateBufferFrames = readBufferFrameSize(deviceID: aggregateDeviceID) ?? 0
            requestLowLatencyBufferFrameSize(
                deviceID: aggregateDeviceID,
                sampleRate: sampleRate,
                targetLatencyMs: config.effects.latency.targetMs,
                shouldRestoreOnStop: false
            )
            
            // 5. Setup SPSC ring buffer & DSP Resources
            let bufferSeconds = 0.08
            let ringBuf = AudioRingBuffer(capacityFrames: Int(sampleRate * bufferSeconds), channels: Int(channels))
            self.ringBuffer = ringBuf
            self.processingSampleRate = sampleRate
            self.processingChannels = channels
            self.bufferCapacitySamples = ringBuf.capacitySamples
            resetRuntimeDiagnostics()
            setupResources(sampleRate: sampleRate, channels: Int(channels), ringBuf: ringBuf)
            
            // 6. Setup AVAudioEngine
            let avEngine = AVAudioEngine()
            
            // Set output directly to physical device
            var outputID = outputDeviceID
            guard let outputAU = avEngine.outputNode.audioUnit else {
                throw NSError(domain: AppInfo.displayName, code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to get output AudioUnit"])
            }
            AudioUnitSetProperty(
                outputAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &outputID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
                throw NSError(domain: AppInfo.displayName, code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format for \(sampleRate) Hz, \(channels) channels"])
            }
            let sourceNode = AVAudioSourceNode(format: format, renderBlock: renderCallback)
            self.sourceNode = sourceNode
            
            // Create EQ node with 32 bands
            let eqNode = AVAudioUnitEQ(numberOfBands: 32)
            self.eqNode = eqNode

            let delayNode = AVAudioUnitDelay()
            self.delayNode = delayNode

            let reverbNode = AVAudioUnitReverb()
            reverbNode.loadFactoryPreset(.mediumHall)
            self.reverbNode = reverbNode

            let dynamicsDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_DynamicsProcessor,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            let dynamicsNode = AVAudioUnitEffect(audioComponentDescription: dynamicsDesc)
            let dynamicsAU = dynamicsNode.audioUnit
            AudioUnitSetParameter(dynamicsAU, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -2.0, 0)
            AudioUnitSetParameter(dynamicsAU, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 3.0, 0)
            AudioUnitSetParameter(dynamicsAU, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 1.0, 0)
            AudioUnitSetParameter(dynamicsAU, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, -90.0, 0)
            AudioUnitSetParameter(dynamicsAU, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.003, 0)
            AudioUnitSetParameter(dynamicsAU, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.080, 0)
            AudioUnitSetParameter(dynamicsAU, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 0.0, 0)
            self.dynamicsNode = dynamicsNode
            
            // Create native peak limiter
            let limiterDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            let limiterNode = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
            self.limiterNode = limiterNode
            
            let au = limiterNode.audioUnit
            AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.007, 0)
            AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.024, 0)
            AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0.0, 0)
            
            // Apply initial config
            applyConfigToNodes(config)
            
            // Attach nodes
            avEngine.attach(sourceNode)
            avEngine.attach(eqNode)
            avEngine.attach(delayNode)
            avEngine.attach(reverbNode)
            avEngine.attach(dynamicsNode)
            avEngine.attach(limiterNode)
            
            // Connect nodes
            avEngine.connect(sourceNode, to: eqNode, format: format)
            avEngine.connect(eqNode, to: delayNode, format: format)
            avEngine.connect(delayNode, to: reverbNode, format: format)
            avEngine.connect(reverbNode, to: dynamicsNode, format: format)
            avEngine.connect(dynamicsNode, to: limiterNode, format: format)
            avEngine.connect(limiterNode, to: avEngine.outputNode, format: format)
            
            // 7. Setup IOProc callback on aggregate device to pull audio -> ring buffer
            let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
                rtReaderCount.wrappingIncrement(ordering: .acquiring)
                defer {
                    rtReaderCount.wrappingDecrement(ordering: .releasing)
                }
                guard let resPtr = rtActiveResources.load(ordering: .acquiring) else { return }
                let ringBuf = resPtr.pointee.ringBuffer.takeUnretainedValue()
                rtIOCallbackCount.wrappingIncrement(ordering: .relaxed)

                let inBufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let expectedChannels = resPtr.pointee.channelCount
                guard expectedChannels > 0, inBufList.count > 0 else { return }

                let frames: Int
                let totalSamples: Int
                if inBufList.count == 1 {
                    guard let data = inBufList[0].mData else { return }
                    let availableSamples = Int(inBufList[0].mDataByteSize) / MemoryLayout<Float>.size
                    totalSamples = availableSamples - (availableSamples % expectedChannels)
                    guard totalSamples > 0 else { return }
                    frames = totalSamples / expectedChannels
                    let interleavedSource = data.assumingMemoryBound(to: Float.self)
                    var peak: Float = 0
                    for sampleIndex in 0..<totalSamples {
                        peak = max(peak, fabsf(interleavedSource[sampleIndex]))
                    }
                    if peak > audibleSampleThreshold {
                        rtLastAudibleHostTime.store(mach_absolute_time(), ordering: .relaxed)
                        rtLastAudiblePeakBits.store(peak.bitPattern, ordering: .relaxed)
                    }
                    let dropped = ringBuf.write(interleavedSource, count: totalSamples)
                    if dropped > 0 {
                        rtDroppedSampleCount.wrappingIncrement(by: UInt64(dropped), ordering: .relaxed)
                    }
                    rtLastInputFrameCount.store(UInt64(frames), ordering: .relaxed)
                    rtAvailableSamples.store(UInt64(max(ringBuf.availableToRead, 0)), ordering: .relaxed)

                    // Zero out output (silence aggregate device playback)
                    let outBufList = UnsafeMutableAudioBufferListPointer(outOutputData)
                    for i in 0..<outBufList.count {
                        if let data = outBufList[i].mData {
                            memset(data, 0, Int(outBufList[i].mDataByteSize))
                        }
                    }
                    return
                }

                let inputChannelsToCopy = min(expectedChannels, inBufList.count)
                var availableFrames = Int.max
                for c in 0..<inputChannelsToCopy {
                    let samples = Int(inBufList[c].mDataByteSize) / MemoryLayout<Float>.size
                    availableFrames = min(availableFrames, samples)
                }
                guard availableFrames != Int.max, availableFrames > 0 else { return }
                frames = availableFrames
                guard frames <= Int.max / expectedChannels else { return }
                totalSamples = frames * expectedChannels
                rtLastInputFrameCount.store(UInt64(frames), ordering: .relaxed)

                if let interleaveBuf = resPtr.pointee.ioInterleaveBuffer, resPtr.pointee.ioInterleaveCapacity >= totalSamples {
                    for f in 0..<frames {
                        for c in 0..<expectedChannels {
                            if c < inBufList.count, let src = inBufList[c].mData?.assumingMemoryBound(to: Float.self) {
                                interleaveBuf[f * expectedChannels + c] = src[f]
                            } else {
                                interleaveBuf[f * expectedChannels + c] = 0.0
                            }
                        }
                    }
                    var peak: Float = 0
                    for sampleIndex in 0..<totalSamples {
                        peak = max(peak, fabsf(interleaveBuf[sampleIndex]))
                    }
                    if peak > audibleSampleThreshold {
                        rtLastAudibleHostTime.store(mach_absolute_time(), ordering: .relaxed)
                        rtLastAudiblePeakBits.store(peak.bitPattern, ordering: .relaxed)
                    }
                    let dropped = ringBuf.write(interleaveBuf, count: totalSamples)
                    if dropped > 0 {
                        rtDroppedSampleCount.wrappingIncrement(by: UInt64(dropped), ordering: .relaxed)
                    }
                }
                rtAvailableSamples.store(UInt64(max(ringBuf.availableToRead, 0)), ordering: .relaxed)

                // Zero out output (silence aggregate device playback)
                let outBufList = UnsafeMutableAudioBufferListPointer(outOutputData)
                for i in 0..<outBufList.count {
                    if let data = outBufList[i].mData {
                        memset(data, 0, Int(outBufList[i].mDataByteSize))
                    }
                }
            }
            
            try caCheck(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock),
                "Failed to create IOProc"
            )
            
            try caCheck(
                AudioDeviceStart(aggregateDeviceID, procID),
                "Failed to start aggregate device"
            )

            let targetLatencySeconds = Double(config.effects.latency.targetMs) / 1_000
            let renderQuantumSeconds = outputBufferFrames > 0
                ? Double(outputBufferFrames) / sampleRate
                : targetLatencySeconds
            let prebufferSeconds = min(max(targetLatencySeconds + renderQuantumSeconds, 0.008), 0.060)
            try await Task.sleep(nanoseconds: UInt64(prebufferSeconds * 1_000_000_000))
            try checkCurrentLifecycle(generation)

            // Start playback after the producer has had a short chance to fill the jitter buffer.
            // Begin with effects bypassed; the fade-in ramp brings them up after start.
            storeEffectMix(0)
            applyEffectMixToNodes(0)
            try avEngine.start()
            self.engine = avEngine

            // Our processed output is now running: mute the original signal.
            var muteFlipFailed = false
            if muteFlipSupported {
                let muteStatus = setTapMuted(tapID: tapID, description: tapDesc, muted: true)
                if muteStatus != noErr {
                    os_log(.error, log: appLog,
                           "%{public}s failed to switch tap to muted (OSStatus %d); falling back to muted-at-creation",
                           AppInfo.displayName, muteStatus)
                    muteFlipSupported = false
                    muteFlipFailed = true
                }
            }

            try checkCurrentLifecycle(generation)
            self.isActive = true
            self.startedAt = Date()
            self.startCount &+= 1
            rtLastAudibleHostTime.store(mach_absolute_time(), ordering: .relaxed)
            beginEffectFadeIn()
            let startDurationMs = machTicksToMilliseconds(mach_absolute_time() &- startBeganTicks)
            os_log(.default, log: appLog, "%{public}s started in %.0f ms, tapping audio for: %{public}s",
                   AppInfo.displayName, startDurationMs, deviceName)

            if muteFlipFailed {
                // Never leave doubled audio (original + processed) playing.
                Task { @MainActor [weak self] in
                    await self?.restart()
                }
            }

        } catch is AudioEngineStartCancellation {
            // Starts are serialized through requestStart, so everything in the
            // instance fields belongs to this invocation: always tear it down,
            // even when this start was superseded, so taps and aggregate
            // devices can never leak.
            stopCurrent()
        } catch is CancellationError {
            stopCurrent()
        } catch {
            os_log(.error, log: appLog, "Error starting %{public}s: %{public}s", AppInfo.displayName, error.localizedDescription)
            print(AppInfo.logPrefix("Error starting audio engine: \(error.localizedDescription)"))
            stopCurrent()
        }
    }

    private func setTapMuted(tapID: AudioObjectID, description: CATapDescription, muted: Bool) -> OSStatus {
        description.muteBehavior = muted ? .muted : .unmuted
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var descriptionRef: CATapDescription? = description
        let size = UInt32(MemoryLayout<CATapDescription?>.size)
        return withUnsafeMutablePointer(to: &descriptionRef) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, size, $0)
        }
    }

    private func requiresRestartForLatencyChange(to config: EQConfig) -> Bool {
        guard let currentConfig else { return false }
        let currentTarget = currentConfig.effects.latency.targetMs
        let nextTarget = config.effects.latency.targetMs
        return abs(currentTarget - nextTarget) >= 0.25
    }
    
    public func stop() {
        pendingStartTask?.cancel()
        standbyPollTask?.cancel()
        isInStandby = false
        standbyDeviceID = nil
        standbyConfig = nil
        _ = beginLifecycleChange()
        stopCurrent()
    }

    private func stopCurrent() {
        guard isActive
                || activeDeviceID != nil
                || currentConfig != nil
                || tapID != AudioObjectID(kAudioObjectUnknown)
                || aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        os_log(.default, log: appLog, "Stopping %{public}s...", AppInfo.displayName)
        cancelEffectFadeIn()

        // 1. Stop IOProc first (stops producer thread)
        if let procID, aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.procID = nil
        }
        
        // 2. Stop AVAudioEngine (stops consumer thread)
        if let engine = engine {
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
        }

        restoreOutputBufferFrameSize()
        
        // 3. Safety: nil-out and purge DSP resources
        self.ringBuffer = nil
        purgeResources()
        storeRealtimeOutputVolumeScalar(0.60)
        
        // 4. Destroy hardware device mappings
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        
        engine = nil
        eqNode = nil
        delayNode = nil
        reverbNode = nil
        dynamicsNode = nil
        limiterNode = nil
        sourceNode = nil
        isActive = false
        activeDeviceID = nil
        activeDeviceName = nil
        currentConfig = nil
        processingSampleRate = 0
        processingChannels = 0
        bufferCapacitySamples = 0
        requestedBufferFrames = 0
        outputBufferFrames = 0
        aggregateBufferFrames = 0
        outputVolumeScalar = 0.60
        startedAt = nil
        purgeConfigs()
        resetRuntimeDiagnostics()
    }

    public func restart() async {
        guard let deviceID = activeDeviceID, let config = currentConfig else { return }
        stop()
        requestStart(outputDeviceID: deviceID, config: config)
        await pendingStartTask?.value
    }
    
    public func updateConfig(_ config: EQConfig) {
        self.currentConfig = config
        if isActive {
            // A live config change lands at full strength; abandon any fade.
            cancelEffectFadeIn()
            applyConfigToNodes(config)
            os_log(.default, log: appLog, "%{public}s updated configuration.", AppInfo.displayName)
        }
    }
    
    private func applyConfigToNodes(_ config: EQConfig) {
        guard let eqNode = eqNode else { return }
        eqNode.globalGain = config.preamp
        
        for i in 0..<32 {
            let eqBand = eqNode.bands[i]
            if i < config.bands.count {
                let band = config.bands[i]
                eqBand.filterType = band.filterType
                eqBand.frequency = band.frequency
                eqBand.bandwidth = band.bandwidth
                eqBand.gain = band.gain
                eqBand.bypass = band.bypass
            } else {
                eqBand.bypass = true
            }
        }

        delayNode?.delayTime = TimeInterval(config.effects.delay.timeMs / 1000)
        delayNode?.feedback = config.effects.delay.feedback
        delayNode?.wetDryMix = config.effects.delay.mix

        let surround = config.effects.surround
        let spatialStrength = modeledSpatialStrength(for: surround)
        let modeledRearAmount = min(max(surround.rearAmount * spatialStrength, 0), 100)
        let modeledRearDelayMs = modeledRearDelayMilliseconds(for: surround)
        let modeledShadow = modeledRearShadow(for: surround)
        let modeledWidth = min(max(surround.width * (0.85 + spatialStrength * 0.15), 0), 100)

        reverbNode?.wetDryMix = modeledReverbWetDryMix(for: surround)

        let sampleRate: Float
        let delayCapacity: Int
        if let resPtr = rtActiveResources.load(ordering: .acquiring) {
            sampleRate = resPtr.pointee.sampleRate
            delayCapacity = resPtr.pointee.rearDelayLineCapacity
        } else {
            sampleRate = 48000
            delayCapacity = 0
        }

        let stereoWidth = modeledWidth
        let rearSurroundAmount = modeledRearAmount
        let rearSurroundDelaySamples = min(
            max(Int((Double(modeledRearDelayMs) / 1_000) * Double(sampleRate)), 1),
            max(delayCapacity - 1, 1)
        )
        let rearSurroundShadow = modeledShadow
        let listenerDistanceCm = finiteClamped(
            surround.listenerDistanceCm,
            default: SpatialTuning.default.listenerDistanceCm,
            min: 25,
            max: 80
        )
        let headHeightCm = finiteClamped(surround.headHeightCm, default: defaultSpatialHeadHeightCm, min: 0, max: 120)
        let displayAngleDegrees = finiteClamped(
            surround.displayAngleDegrees,
            default: defaultSpatialDisplayAngleDegrees,
            min: 60,
            max: 180
        )
        let spatialStrengthPercent = finiteClamped(
            surround.spatialStrengthPercent,
            default: SpatialTuning.default.strengthPercent,
            min: 60,
            max: 140
        )
        let crossTalkDelaySamples = estimatedCrossTalkDelaySamples(
            sampleRate: Double(sampleRate),
            listenerDistanceCm: listenerDistanceCm,
            headHeightCm: headHeightCm
        )
        let crossTalkCancelAmount = min(max(modeledRearAmount / 100, 0), 1) * 0.18 * spatialStrength
        let bassHarmonicsAmount = config.effects.bassHarmonics.amount
        let bassHarmonicsCutoffHz = config.effects.bassHarmonics.cutoffHz
        let bassHarmonicsSpeakerCutoffHz = config.effects.bassHarmonics.speakerCutoffHz
        let bassHarmonicsSpeakerCutoff = min(max(bassHarmonicsSpeakerCutoffHz, 40), 260)
        let bassHarmonicsLowpass = lowpassBiquad(sampleRate: sampleRate, cutoff: bassHarmonicsSpeakerCutoff, q: 0.707)
        let harmonicCenter = min(max(bassHarmonicsSpeakerCutoff * 2.828, 90), sampleRate * 0.42)
        let bassHarmonicsBandpass = bandpassBiquad(sampleRate: sampleRate, center: harmonicCenter, q: 1.414)
        let bassHarmonicsDCPole = expf(-2 * Float.pi * 20 / sampleRate)
        let bassHarmonicsEnvelopeAttack = 1 - expf(-1 / (sampleRate * 0.005))
        let bassHarmonicsEnvelopeRelease = 1 - expf(-1 / (sampleRate * 0.080))
        let bassFocusAmount = config.effects.bassFocus.amountPercent
        let bassFocusThresholdDb = config.effects.bassFocus.thresholdDb
        let bassFocusMaxHighCutDb = config.effects.bassFocus.maxHighCutDb
        let bassFocusMaxHighCutGain = linearGain(
            forReductionDb: min(max(bassFocusAmount / 100, 0), 1) * min(max(bassFocusMaxHighCutDb, 1), 12)
        )
        let lowEndGuardAmount = config.effects.lowEndGuard.amountPercent
        let lowEndGuardThresholdDb = config.effects.lowEndGuard.thresholdDb
        let lowEndGuardThresholdLinear = linearGain(forReductionDb: -min(max(lowEndGuardThresholdDb, -36), -6))
        let lowEndGuardCutoffHz = config.effects.lowEndGuard.cutoffHz
        let lowEndGuardRatio = config.effects.lowEndGuard.ratio
        let lowEndGuardMaxReductionDb = config.effects.lowEndGuard.maxReductionDb
        let lowEndGuardMaxReductionGain = linearGain(forReductionDb: min(max(lowEndGuardMaxReductionDb, 1), 10))
        let bassCompAmount = config.effects.bassComp.amountPercent
        let bassCompCrossoverHz = config.effects.bassComp.crossoverHz
        let softLimitDrive = config.effects.softLimit.drivePercent
        let bassCompAmountNorm = min(max(bassCompAmount / 100, 0), 1)
        let bassCompLowpass = lowpassBiquad(
            sampleRate: sampleRate,
            cutoff: finiteClamped(bassCompCrossoverHz, default: 200, min: 80, max: 400),
            q: 0.707
        )
        let bassCompEnvelopeAttack = 1 - expf(-1 / (sampleRate * 0.012))
        let bassCompEnvelopeRelease = 1 - expf(-1 / (sampleRate * 0.180))
        let bassCompGainSmoothing = 1 - expf(-1 / (sampleRate * 0.010))
        let bassCompThresholdLinear: Float = 0.031_622_776_6 // -30 dBFS
        let bassCompMaxMakeupGain = powf(10, (6 * bassCompAmountNorm) / 20)
        let softLimitDriveGain = 1 + min(max(softLimitDrive / 100, 0), 1) * 0.6
        let maxRealtimeLatencySeconds = max(0.001, min(config.effects.latency.targetMs / 1000, 0.08))

        let newConfig = DSPConfig(
            bassHarmonicsAmount: bassHarmonicsAmount,
            bassHarmonicsCutoffHz: bassHarmonicsCutoffHz,
            bassHarmonicsSpeakerCutoffHz: bassHarmonicsSpeakerCutoffHz,
            bassHarmonicsLowpass: bassHarmonicsLowpass,
            bassHarmonicsBandpass: bassHarmonicsBandpass,
            bassHarmonicsDCPole: bassHarmonicsDCPole,
            bassHarmonicsEnvelopeAttack: bassHarmonicsEnvelopeAttack,
            bassHarmonicsEnvelopeRelease: bassHarmonicsEnvelopeRelease,
            bassFocusAmount: bassFocusAmount,
            bassFocusThresholdDb: bassFocusThresholdDb,
            bassFocusMaxHighCutDb: bassFocusMaxHighCutDb,
            bassFocusMaxHighCutGain: bassFocusMaxHighCutGain,
            lowEndGuardAmount: lowEndGuardAmount,
            lowEndGuardThresholdDb: lowEndGuardThresholdDb,
            lowEndGuardThresholdLinear: lowEndGuardThresholdLinear,
            lowEndGuardCutoffHz: lowEndGuardCutoffHz,
            lowEndGuardRatio: lowEndGuardRatio,
            lowEndGuardMaxReductionDb: lowEndGuardMaxReductionDb,
            lowEndGuardMaxReductionGain: lowEndGuardMaxReductionGain,
            bassCompAmount: bassCompAmount,
            bassCompLowpass: bassCompLowpass,
            bassCompEnvelopeAttack: bassCompEnvelopeAttack,
            bassCompEnvelopeRelease: bassCompEnvelopeRelease,
            bassCompGainSmoothing: bassCompGainSmoothing,
            bassCompThresholdLinear: bassCompThresholdLinear,
            bassCompInvThresholdLinear: 1 / bassCompThresholdLinear,
            bassCompMaxMakeupGain: bassCompMaxMakeupGain,
            softLimitDrive: softLimitDrive,
            softLimitDriveGain: softLimitDriveGain,
            stereoWidth: stereoWidth,
            rearSurroundAmount: rearSurroundAmount,
            rearSurroundDelaySamples: rearSurroundDelaySamples,
            rearSurroundShadow: rearSurroundShadow,
            crossTalkCancelAmount: crossTalkCancelAmount,
            crossTalkDelaySamples: crossTalkDelaySamples,
            sampleRate: sampleRate,
            maxRealtimeLatencySeconds: maxRealtimeLatencySeconds,
            listenerDistanceCm: listenerDistanceCm,
            headHeightCm: headHeightCm,
            displayAngleDegrees: displayAngleDegrees,
            spatialStrengthPercent: spatialStrengthPercent
        )

        let newPtr = UnsafeMutablePointer<DSPConfig>.allocate(capacity: 1)
        newPtr.initialize(to: newConfig)

        let oldPtr = rtActiveConfig.exchange(newPtr, ordering: .acquiringAndReleasing)
        if let oldPtr = oldPtr {
            retireConfig(oldPtr)
        }
    }

    private func finalSafetyCompressionDb() -> Float {
        guard let dynamicsAU = dynamicsNode?.audioUnit else { return 0 }
        var value: AudioUnitParameterValue = 0
        let status = AudioUnitGetParameter(
            dynamicsAU,
            kDynamicsProcessorParam_CompressionAmount,
            kAudioUnitScope_Global,
            0,
            &value
        )
        guard status == noErr else { return 0 }
        let amount = fabsf(value)
        return amount < 0.005 ? 0 : amount
    }

    public func diagnostics() -> AudioEngineDiagnostics {
        rtReaderCount.wrappingIncrement(ordering: .acquiring)
        defer {
            rtReaderCount.wrappingDecrement(ordering: .releasing)
        }
        let config: DSPConfig
        if let configPtr = rtActiveConfig.load(ordering: .acquiring) {
            config = configPtr.pointee
        } else {
            config = currentFallbackConfig()
        }
        let res = rtActiveResources.load(ordering: .acquiring)?.pointee

        let channelCount = max(Int(processingChannels), 1)
        let queuedBeforeRenderSamples = Int(rtAvailableSamples.load(ordering: .relaxed))
        let queuedAfterRenderSamples = Int(rtQueuedAfterRenderSamples.load(ordering: .relaxed))
        let queuedBeforeRenderFrames = max(queuedBeforeRenderSamples, 0) / channelCount
        let queuedFrames = max(queuedAfterRenderSamples, 0) / channelCount
        let sampleRate = processingSampleRate
        let bufferedLatencyMs = sampleRate > 0 ? (Double(queuedFrames) / sampleRate) * 1_000 : 0
        let queuedBeforeRenderMs = sampleRate > 0 ? (Double(queuedBeforeRenderFrames) / sampleRate) * 1_000 : 0
        let bufferCapacityFrames = bufferCapacitySamples / channelCount
        let bufferCapacityMs = sampleRate > 0 ? (Double(bufferCapacityFrames) / sampleRate) * 1_000 : 0
        let bufferFillPercent = bufferCapacitySamples > 0
            ? min(100, max(0, Double(queuedAfterRenderSamples) / Double(bufferCapacitySamples) * 100))
            : 0
        let lastRenderFrames = rtLastRenderFrameCount.load(ordering: .relaxed)
        let renderBudgetMs = sampleRate > 0 && lastRenderFrames > 0
            ? (Double(lastRenderFrames) / sampleRate) * 1_000
            : 0
        let underrunSamples = rtUnderrunSampleCount.load(ordering: .relaxed)
        let lastUnderrunSamples = rtLastUnderrunSamples.load(ordering: .relaxed)
        let droppedSamples = rtDroppedSampleCount.load(ordering: .relaxed)
        let crossTalkDelayMs = sampleRate > 0
            ? Double(config.crossTalkDelaySamples) / sampleRate * 1_000
            : 0
        let bassFocusReductionDb = reductionDb(fromLinearGain: res?.bassFocusCurrentHighGain ?? 1)
        let lowEndGuardReductionDb = reductionDb(fromLinearGain: res?.lowEndGuardCurrentLowGain ?? 1)
        let lowEndGuardAverageReductionDb = reductionDb(fromLinearGain: res?.lowEndGuardAverageReductionGain ?? 1)
        let lowEndGuardMaxReductionDb = reductionDb(fromLinearGain: res?.lowEndGuardObservedMinGain ?? 1)
        let lowEndGuardPeakDb = amplitudeDb(fromLinearAmplitude: res?.lowEndGuardPeakLinear ?? 0)

        return AudioEngineDiagnostics(
            isActive: isActive,
            engineRunning: engine?.isRunning ?? false,
            activeDeviceName: activeDeviceName,
            sampleRate: sampleRate,
            channels: processingChannels,
            targetLatencyMs: Double(max(0.001, min(currentConfig?.effects.latency.targetMs ?? 0, 80))),
            bufferedLatencyMs: bufferedLatencyMs,
            queuedFrames: queuedFrames,
            queuedBeforeRenderMs: queuedBeforeRenderMs,
            queuedBeforeRenderFrames: queuedBeforeRenderFrames,
            bufferCapacityMs: bufferCapacityMs,
            bufferFillPercent: bufferFillPercent,
            requestedBufferFrames: requestedBufferFrames,
            outputBufferFrames: outputBufferFrames,
            aggregateBufferFrames: aggregateBufferFrames,
            effectDelayMs: Double(currentConfig?.effects.delay.timeMs ?? 0),
            renderCallbacks: rtRenderCallbackCount.load(ordering: .relaxed),
            idleRenderCallbacks: rtIdleRenderCallbackCount.load(ordering: .relaxed),
            ioCallbacks: rtIOCallbackCount.load(ordering: .relaxed),
            underruns: rtUnderrunCount.load(ordering: .relaxed),
            underrunFrames: underrunSamples / UInt64(channelCount),
            lastUnderrunFrames: lastUnderrunSamples / UInt64(channelCount),
            droppedFrames: droppedSamples / UInt64(channelCount),
            lastInputFrameCount: rtLastInputFrameCount.load(ordering: .relaxed),
            lastRenderFrameCount: lastRenderFrames,
            lastRenderDurationMs: machTicksToMilliseconds(rtLastRenderDurationTicks.load(ordering: .relaxed)),
            maxRenderDurationMs: machTicksToMilliseconds(rtMaxRenderDurationTicks.load(ordering: .relaxed)),
            renderBudgetMs: renderBudgetMs,
            spatialListenerDistanceCm: config.listenerDistanceCm,
            spatialHeadHeightCm: config.headHeightCm,
            spatialDisplayAngleDegrees: config.displayAngleDegrees,
            spatialStrengthPercent: config.spatialStrengthPercent,
            crossTalkDelayMs: crossTalkDelayMs,
            outputVolumePercent: outputVolumeScalar * 100,
            bassFocusAmountPercent: config.bassFocusAmount,
            bassFocusReductionDb: bassFocusReductionDb,
            lowEndGuardReductionDb: lowEndGuardReductionDb,
            lowEndGuardAverageReductionDb: lowEndGuardAverageReductionDb,
            lowEndGuardMaxReductionDb: lowEndGuardMaxReductionDb,
            lowEndGuardPeakDb: lowEndGuardPeakDb,
            finalSafetyCompressionDb: finalSafetyCompressionDb(),
            startedAt: startedAt,
            startCount: startCount
        )
    }
}
