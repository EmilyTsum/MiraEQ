import CoreAudio
import AudioToolbox
import Atomics
import Foundation
import Darwin

// MARK: - Real-time Audio Callbacks
//
// Lock-free DSP state shared with the CoreAudio render threads. Everything
// here is either immutable after publication (DSPConfig), pre-allocated and
// swapped atomically (DSPResources), or a lock-free atomic counter. Nothing
// in this file allocates, retains/releases Swift objects, or blocks.

struct BiquadCoefficients {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float
}

func lowpassBiquad(sampleRate: Float, cutoff: Float, q: Float) -> BiquadCoefficients {
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

func bandpassBiquad(sampleRate: Float, center: Float, q: Float) -> BiquadCoefficients {
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

let rtActiveConfig = ManagedAtomic<UnsafeMutablePointer<DSPConfig>?>(nil)

// RCU Reader count state
let rtReaderCount = ManagedAtomic<Int>(0)
nonisolated(unsafe) var rtRetiredConfigs: [UnsafeMutablePointer<DSPConfig>] = []
nonisolated(unsafe) var rtCleanupInProgress = false

let fallbackDSPConfig = DSPConfig()

func currentFallbackConfig() -> DSPConfig {
    fallbackDSPConfig
}

@MainActor
func retireConfig(_ oldPtr: UnsafeMutablePointer<DSPConfig>) {
    rtRetiredConfigs.append(oldPtr)
    cleanUpRetiredConfigs()
}

@MainActor
func cleanUpRetiredConfigs() {
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
func scheduleDeferredCleanup() {
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
func purgeConfigs() {
    let oldPtr = rtActiveConfig.exchange(nil, ordering: .acquiringAndReleasing)
    if let oldPtr = oldPtr {
        retireConfig(oldPtr)
    }
    cleanUpRetiredConfigs()
}

struct DSPResources {
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
    // Felt-bass stage states (pre-allocated, mutated on the render thread)
    let loudnessLowpassState: UnsafeMutablePointer<Float>
    let loudnessLowpassStateCapacity: Int

    // Rear surround delay lines and lowpass states

    // Dynamic states mutated on the real-time callback thread
    var bassFocusEnvelope: Float
    var bassFocusCurrentHighGain: Float

    var lowEndGuardCurrentLowGain: Float
    var lowEndGuardPeakLinear: Float
    var lowEndGuardAverageReductionGain: Float
    var lowEndGuardObservedMinGain: Float
    var lowEndGuardMeasurementCount: UInt64
}

let rtActiveResources = ManagedAtomic<UnsafeMutablePointer<DSPResources>?>(nil)
nonisolated(unsafe) var rtRetiredResources: [UnsafeMutablePointer<DSPResources>] = []
nonisolated(unsafe) var rtResourceCleanupInProgress = false

@MainActor
func deallocateResources(_ ptr: UnsafeMutablePointer<DSPResources>) {
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
    ptr.pointee.loudnessLowpassState.deallocate()

    // Release the ring buffer reference (decrement ARC count)
    ptr.pointee.ringBuffer.release()

    ptr.deinitialize(count: 1)
    ptr.deallocate()
}

@MainActor
func retireResources(_ oldPtr: UnsafeMutablePointer<DSPResources>) {
    rtRetiredResources.append(oldPtr)
    cleanUpRetiredResources()
}

@MainActor
func cleanUpRetiredResources() {
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
func scheduleDeferredResourceCleanup() {
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
func purgeResources() {
    let oldPtr = rtActiveResources.exchange(nil, ordering: .acquiringAndReleasing)
    if let oldPtr = oldPtr {
        retireResources(oldPtr)
    }
    cleanUpRetiredResources()
}

@MainActor
func setupResources(sampleRate: Double, channels: Int, ringBuf: AudioRingBuffer) {
    let preallocCapacity = 8192 * channels
    let lowpassCapacity = max(16, channels)

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
    let loudLP = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)

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
    loudLP.initialize(repeating: 0, count: lowpassCapacity)

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
        loudnessLowpassState: loudLP,
        loudnessLowpassStateCapacity: lowpassCapacity,
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

let rtOutputVolumeScalarBits = ManagedAtomic<UInt32>(Float(0.60).bitPattern)

let rtRenderCallbackCount = ManagedAtomic<UInt64>(0)
let rtIOCallbackCount = ManagedAtomic<UInt64>(0)
let rtUnderrunCount = ManagedAtomic<UInt64>(0)
let rtUnderrunSampleCount = ManagedAtomic<UInt64>(0)
let rtLastUnderrunSamples = ManagedAtomic<UInt64>(0)
let rtDroppedSampleCount = ManagedAtomic<UInt64>(0)
let rtAvailableSamples = ManagedAtomic<UInt64>(0)
let rtQueuedAfterRenderSamples = ManagedAtomic<UInt64>(0)
let rtLastInputFrameCount = ManagedAtomic<UInt64>(0)
let rtLastRenderFrameCount = ManagedAtomic<UInt64>(0)
let rtLastRenderDurationTicks = ManagedAtomic<UInt64>(0)
let rtMaxRenderDurationTicks = ManagedAtomic<UInt64>(0)
let rtIdleRenderCallbackCount = ManagedAtomic<UInt64>(0)
let rtNeedsPriming = ManagedAtomic<UInt32>(1)
// mach_absolute_time of the last tapped buffer that contained audible samples.
// Written by the IO callback, read on the main actor for auto-standby.
let rtLastAudibleHostTime = ManagedAtomic<UInt64>(0)
// -60 dBFS: high enough to ignore mixer noise floor / dither that some
// processes emit while "silent", low enough to catch real playback.
let audibleSampleThreshold: Float = 0.001

// Global dry/wet mix for the custom DSP chain (0 = bypass, 1 = full effects).
// Ramped on the main actor after each engine start so processing fades in
// instead of snapping on; read by the render callback.
let rtEffectMixBits = ManagedAtomic<UInt32>(Float(1).bitPattern)
// Peak of the most recent audible input buffer, for diagnostics.
let rtLastAudiblePeakBits = ManagedAtomic<UInt32>(0)

func loadEffectMix() -> Float {
    let value = Float(bitPattern: rtEffectMixBits.load(ordering: .relaxed))
    guard value.isFinite else { return 1 }
    return min(max(value, 0), 1)
}

func storeEffectMix(_ mix: Float) {
    rtEffectMixBits.store(min(max(mix, 0), 1).bitPattern, ordering: .relaxed)
}

func renderCallback(
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

    // Retain one output quantum of scheduling margin. Capacity is not latency;
    // stale frames are trimmed before rendering rather than accumulating delay.
    let requestedLatencySamples = Int(config.sampleRate * config.maxRealtimeLatencySeconds) * ch
    let maxBufferedSamples = interleavedCount + max(interleavedCount, requestedLatencySamples)
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

func clearOutputBuffers(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for buffer in bufferList {
        if let data = buffer.mData {
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}

/// Loudness compensation: human hearing is much less sensitive to bass at low
/// volumes (Fletcher-Munson), so quiet listening feels thin. This lifts the
/// lows progressively as the system volume drops, fading to zero near maximum
/// volume where no lift is needed (and headroom is scarcest).
func applyLoudness(
    _ samples: UnsafeMutablePointer<Float>,
    frames: Int,
    channels: Int,
    config: DSPConfig,
    outputVolume: Float,
    resources: UnsafeMutablePointer<DSPResources>
) {
    guard frames > 0, channels > 0, config.loudnessAmount > 0.0001 else { return }
    guard resources.pointee.loudnessLowpassStateCapacity >= channels else { return }

    let volume = outputVolume
    let depth = 1 - smoothstep(edge0: 0.25, edge1: 0.85, x: volume)
    // amount 0-100 maps to 0 to +6 dB of extra lows at minimum volume.
    let boost = min(max(config.loudnessAmount / 100, 0), 1) * depth
    guard boost > 0.0001 else { return }

    let lowpassState = resources.pointee.loudnessLowpassState
    let alpha = config.loudnessAlpha

    for frame in 0..<frames {
        for channel in 0..<channels {
            let index = frame * channels + channel
            let input = samples[index]
            let low = lowpassState[channel] + alpha * (input - lowpassState[channel])
            lowpassState[channel] = low
            samples[index] = input + low * boost
        }
    }
}

func applyRealtimeEffects(
    _ samples: UnsafeMutablePointer<Float>,
    frames: Int,
    channels: Int,
    config: DSPConfig,
    resources: UnsafeMutablePointer<DSPResources>
) {
    let volume = loadRealtimeOutputVolumeScalar()
    // Fixed speaker order: Loudness -> Harmonics -> Focus -> Guard.
    // EQ and final protection follow in SpeakerAudioGraph.

    // Loudness lift next: quiet-volume low boost before harmonics are
    // derived, so the generated harmonics also benefit from the lift.
    applyLoudness(samples, frames: frames, channels: channels, config: config, outputVolume: volume, resources: resources)

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

    applyBassFocus(samples, frames: frames, channels: channels, config: config, outputVolume: volume, resources: resources)

    applyLowEndGuard(samples, frames: frames, channels: channels, config: config, outputVolume: volume, resources: resources)

}

func applyLowEndGuard(
    _ samples: UnsafeMutablePointer<Float>,
    frames: Int,
    channels: Int,
    config: DSPConfig,
    outputVolume: Float,
    resources: UnsafeMutablePointer<DSPResources>
) {
    guard frames > 0, channels > 0, config.lowEndGuardAmount > 0.0001 else {
        resources.pointee.lowEndGuardCurrentLowGain += (1 - resources.pointee.lowEndGuardCurrentLowGain) * 0.06
        return
    }

    guard resources.pointee.lowEndGuardLowpassStateCapacity >= channels else { return }
    let lowpassState = resources.pointee.lowEndGuardLowpassState

    let volumeActivation = smoothstep(edge0: 0.86, edge1: 1.0, x: outputVolume)
    let amount = min(max(config.lowEndGuardAmount / 100, 0), 1) * volumeActivation
    guard amount > 0.0001 else {
        resources.pointee.lowEndGuardCurrentLowGain += (1 - resources.pointee.lowEndGuardCurrentLowGain) * 0.08
        resources.pointee.lowEndGuardPeakLinear = 0
        return
    }

    let alpha = config.lowEndGuardAlpha
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

func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
    let t = min(max((x - edge0) / max(edge1 - edge0, 0.0001), 0), 1)
    return t * t * (3 - 2 * t)
}

func loadRealtimeOutputVolumeScalar() -> Float {
    let value = Float(bitPattern: rtOutputVolumeScalarBits.load(ordering: .relaxed))
    guard value.isFinite else { return 0.60 }
    return min(max(value, 0), 1)
}

func storeRealtimeOutputVolumeScalar(_ scalar: Float) {
    let clamped = min(max(scalar, 0), 1)
    rtOutputVolumeScalarBits.store(clamped.bitPattern, ordering: .relaxed)
}

func applyBassFocus(
    _ samples: UnsafeMutablePointer<Float>,
    frames: Int,
    channels: Int,
    config: DSPConfig,
    outputVolume: Float,
    resources: UnsafeMutablePointer<DSPResources>
) {
    guard frames > 0, channels > 0, config.bassFocusAmount > 0.0001 else {
        resources.pointee.bassFocusEnvelope *= 0.98
        resources.pointee.bassFocusCurrentHighGain += (1 - resources.pointee.bassFocusCurrentHighGain) * 0.16
        return
    }

    guard resources.pointee.bassFocusLowpassStateCapacity >= channels else { return }
    let lowpassState = resources.pointee.bassFocusLowpassState

    let systemVolume = outputVolume
    let target = smoothstep(edge0: 0.58, edge1: 0.92, x: systemVolume)
    let smoothing: Float = target > resources.pointee.bassFocusEnvelope ? 0.16 : 0.025
    resources.pointee.bassFocusEnvelope += (target - resources.pointee.bassFocusEnvelope) * smoothing

    let targetHighGain = 1 + (config.bassFocusMaxHighCutGain - 1) * resources.pointee.bassFocusEnvelope
    let gainSmoothing: Float = targetHighGain < resources.pointee.bassFocusCurrentHighGain ? 0.16 : 0.025
    resources.pointee.bassFocusCurrentHighGain += (targetHighGain - resources.pointee.bassFocusCurrentHighGain) * gainSmoothing
    let highGain = min(max(resources.pointee.bassFocusCurrentHighGain, config.bassFocusMaxHighCutGain), 1)
    let alpha = config.bassFocusAlpha

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
