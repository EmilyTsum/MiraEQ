import CoreAudio
import AudioToolbox
import AVFAudio
import Atomics
import Foundation
import Darwin

// MARK: - Core Audio Helpers
//
// Synchronous HAL property access used by the control thread
// (AudioEngineManager) and the diagnostics path. None of these run on the
// real-time callbacks, so plain AudioObject calls are fine here.

let machTimebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func caCheck(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else {
        throw NSError(domain: AppInfo.displayName, code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(message): OSStatus \(status)"])
    }
}

func isSupportedSampleRate(_ sampleRate: Float64) -> Bool {
    sampleRate.isFinite && sampleRate > 0 && sampleRate <= maximumRealtimeSampleRate
}

func resetRuntimeDiagnostics() {
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

func storeAtomicMax(_ atomic: ManagedAtomic<UInt64>, _ value: UInt64) {
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

func machTicksToMilliseconds(_ ticks: UInt64) -> Double {
    guard machTimebaseInfo.denom != 0 else { return 0 }
    let nanos = Double(ticks) * Double(machTimebaseInfo.numer) / Double(machTimebaseInfo.denom)
    return nanos / 1_000_000
}

func readOutputVolumeScalar(deviceID: AudioObjectID) -> Float? {
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

func readOutputMute(deviceID: AudioObjectID) -> Bool {
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

/// Active output streams on the routed device, excluding our playback engine.
/// A stream may keep running through silence; this is not an audibility meter.
/// `nil` means enumeration failed, so callers must not assume playback stopped.
func runningOutputProcessObjects(on outputDeviceID: AudioObjectID) -> Set<AudioObjectID>? {
    var listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize
    ) == noErr else { return nil }
    guard dataSize > 0 else { return [] }

    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var processObjects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize, &processObjects
    ) == noErr else { return nil }

    var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: Set<AudioObjectID> = []
    let currentPID = ProcessInfo.processInfo.processIdentifier
    for processObject in processObjects.prefix(Int(dataSize) / MemoryLayout<AudioObjectID>.size)
    where processObject != kAudioObjectUnknown {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObject, &runningAddress, 0, nil, &size, &isRunning)
        if status != noErr && status != kAudioHardwareBadObjectError { return nil }
        if status == noErr, isRunning != 0 {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(processObject, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
               pid == currentPID { continue }

            // Streams on another physical output cannot wake this route.
            // If the device list is unavailable, conservatively count the
            // stream rather than tearing down an unobservable live player.
            if let devices = outputDevices(forProcessObject: processObject), !devices.contains(outputDeviceID) { continue }
            running.insert(processObject)
        }
    }
    return running
}

private func outputDevices(forProcessObject processObject: AudioObjectID) -> [AudioObjectID]? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyDevices,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(processObject, &address, 0, nil, &size) == noErr else { return nil }
    guard size > 0 else { return [] }
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &devices) == noErr else { return nil }
    return Array(devices.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func bufferFrameSizeAddress(
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func withBufferFrameSizeAddress<T>(
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

func readBufferFrameSize(deviceID: AudioObjectID) -> UInt32? {
    withBufferFrameSizeAddress(for: deviceID, selector: kAudioDevicePropertyBufferFrameSize) { address in
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
        return status == noErr ? frames : nil
    }
}

func readBufferFrameSizeRange(deviceID: AudioObjectID) -> AudioValueRange? {
    withBufferFrameSizeAddress(for: deviceID, selector: kAudioDevicePropertyBufferFrameSizeRange) { address in
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &range)
        return status == noErr ? range : nil
    }
}

func writeBufferFrameSize(deviceID: AudioObjectID, frames: UInt32) -> OSStatus {
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

func nearestPowerOfTwo(_ value: UInt32) -> UInt32 {
    guard value > 1 else { return 1 }

    var lower: UInt32 = 1
    while lower <= value / 2 {
        lower <<= 1
    }

    let upper = lower <= UInt32.max / 2 ? lower << 1 : lower
    return value - lower < upper - value ? lower : upper
}

func preferredBufferFrameSize(sampleRate: Double, targetLatencyMs: Float, range: AudioValueRange?) -> UInt32 {
    // Keep the proven HAL floor until a 64-frame physical/aggregate pair
    // has passed live capture tests; advertised support alone is insufficient.
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
