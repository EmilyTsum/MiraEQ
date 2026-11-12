import CoreAudio
import AudioToolbox
import AVFAudio
import Foundation
import Darwin
import os.log

// MARK: - AudioEngineManager
//
// Engine lifecycle orchestration: process tap, aggregate device, AVAudioEngine
// graph, auto-standby, and diagnostics. The real-time DSP state it drives
// lives in RealtimeDSP.swift; HAL helpers in CoreAudioHelpers.swift.

struct AudioBufferFrameSizeRestorePoint {
    let deviceID: AudioObjectID
    let frames: UInt32
}

enum AudioEngineStartCancellation: Error {
    case superseded
}

/// Errors proving a HAL object is already gone (nothing left to leak), so a
/// failed destroy does not need to be retried.
private func isDefunctAudioObjectError(_ status: OSStatus) -> Bool {
    status == kAudioHardwareBadObjectError
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
    // A single flip failure can be transient (HAL still settling right after
    // launch); only give up on seamless starts after consecutive failures.
    private var muteFlipFailureStreak = 0
    // Set after a flip failure so the immediate fallback restart creates its
    // tap muted, without permanently giving up on seamless starts.
    private var forceMutedTapOnce = false

    /// Whether starts run seamlessly (tap created unmuted, flipped to muted
    /// once processed output is up). Exposed for diagnostics.
    public var seamlessStartActive: Bool { muteFlipSupported }

    // Auto-standby: engine torn down while playback is silent so the system
    // audio-capture indicator disappears; device/config kept for resume.
    public private(set) var isInStandby = false
    private var standbyDeviceID: AudioObjectID?
    private var standbyConfig: EQConfig?

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

    /// Applies the desired route, preserving standby and unchanged graph updates.
    /// Actual starts are serialized internally; callers cannot bypass that path.
    public func applyConfiguration(outputDeviceID: AudioObjectID, config: EQConfig) {
        // Reloading an unchanged route must not interrupt the fade or wake
        // standby. Settings edited in standby are used on the next resume.
        if isInStandby, standbyDeviceID == outputDeviceID {
            standbyConfig = config
            return
        }
        requestStart(outputDeviceID: outputDeviceID, config: config, retriesRemaining: 2)
    }

    private func requestStart(outputDeviceID: AudioObjectID, config: EQConfig, retriesRemaining: Int) {
        isInStandby = false
        standbyDeviceID = nil
        standbyConfig = nil

        let previous = pendingStartTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.start(outputDeviceID: outputDeviceID, config: config)
            guard let self else { return }
            self.onStateChange?()
            // A start can fail transiently (device still settling after a
            // hot-plug, CoreAudio busy). Without a retry the engine would stay
            // off until the next device change, with no enabled menu recovery.
            if !self.isActive, !Task.isCancelled, retriesRemaining > 0 {
                os_log(.default, log: appLog,
                       "%{public}s start did not come up; retrying in 2 s (%d left)",
                       AppInfo.displayName, retriesRemaining)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, !self.isActive, !self.isInStandby else { return }
                self.requestStart(outputDeviceID: outputDeviceID, config: config, retriesRemaining: retriesRemaining - 1)
            }
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
        let silenceTriggered = silenceStandbyEnabled && silentForSeconds >= AutoStandbyPolicy.silenceDelaySeconds
        let hasRunningOutput = silenceTriggered && !muted && !volumeIsZero
            ? runningOutputProcessObjects(on: deviceID).map { !$0.isEmpty }
            : nil
        if AutoStandbyPolicy.shouldEnter(
            muted: muted,
            outputVolume: outputVolumeScalar,
            silenceStandbyEnabled: silenceStandbyEnabled,
            silentSeconds: silentForSeconds,
            hasRunningOutput: hasRunningOutput
        ) {
            os_log(.default, log: appLog,
                   "%{public}s entering standby (muted: %d, volumeZero: %d, silentSeconds: %.1f)",
                   AppInfo.displayName, muted ? 1 : 0, volumeIsZero ? 1 : 0, silentForSeconds)
            stop()
            standbyDeviceID = deviceID
            standbyConfig = config
            isInStandby = true
            startStandbyPolling()
            return true
        }
        return false
    }

    /// While in standby, watch the output device so processing resumes soon
    /// after playback restarts. Each poll enumerates audio process objects,
    /// so it runs at 4 Hz instead of 10 Hz: resume still feels instant while
    /// long-running standby costs less than half the wakeups.
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
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Manual wake, e.g. from the menu: restarts processing immediately
    /// regardless of playback state.
    public func wakeFromStandbyNow() {
        guard isInStandby, let deviceID = standbyDeviceID, let config = standbyConfig else { return }
        os_log(.default, log: appLog, "%{public}s waking from standby (manual)", AppInfo.displayName)
        requestStart(outputDeviceID: deviceID, config: config, retriesRemaining: 2)
    }

    private func tryResumeFromStandby() -> Bool {
        guard isInStandby, let deviceID = standbyDeviceID, let config = standbyConfig else { return false }

        let muted = readOutputMute(deviceID: deviceID)
        let volume = readOutputVolumeScalar(deviceID: deviceID)
        let playersNow = runningOutputProcessObjects(on: deviceID)
        guard AutoStandbyPolicy.shouldResume(
            muted: muted, outputVolume: volume, hasRunningOutput: playersNow.map { !$0.isEmpty }
        ) else { return false }
        os_log(.default, log: appLog, "%{public}s resuming from standby", AppInfo.displayName)
        requestStart(outputDeviceID: deviceID, config: config, retriesRemaining: 2)
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

    private func start(outputDeviceID: AudioObjectID, config: EQConfig) async {
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
            let startedTapUnmuted = muteFlipSupported && !forceMutedTapOnce
            forceMutedTapOnce = false
            tapDesc.muteBehavior = startedTapUnmuted ? .unmuted : .muted
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
            if startedTapUnmuted {
                let muteStatus = setTapMuted(tapID: tapID, description: tapDesc, muted: true)
                if muteStatus != noErr {
                    muteFlipFailureStreak += 1
                    if muteFlipFailureStreak >= 2 {
                        muteFlipSupported = false
                    }
                    forceMutedTapOnce = true
                    muteFlipFailed = true
                    os_log(.error, log: appLog,
                           "%{public}s failed to switch tap to muted (OSStatus %d, streak %d); restarting with muted-at-creation",
                           AppInfo.displayName, muteStatus, muteFlipFailureStreak)
                } else {
                    muteFlipFailureStreak = 0
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
                || aggregateDeviceID != AudioObjectID(kAudioObjectUnknown)
                || procID != nil else { return }
        os_log(.default, log: appLog, "Stopping %{public}s...", AppInfo.displayName)
        cancelEffectFadeIn()

        // 1. Stop IOProc first (stops producer thread)
        if let procID, aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, procID)
            if stopStatus != noErr {
                os_log(.error, log: appLog,
                       "%{public}s could not stop IOProc on aggregate device %u: OSStatus %d",
                       AppInfo.displayName, aggregateDeviceID, stopStatus)
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            if destroyStatus == noErr || isDefunctAudioObjectError(destroyStatus) {
                self.procID = nil
            } else {
                // Keep procID so the next stop retries the destroy instead of
                // leaking the IOProc inside HAL.
                os_log(.error, log: appLog,
                       "%{public}s could not destroy IOProc on aggregate device %u: OSStatus %d",
                       AppInfo.displayName, aggregateDeviceID, destroyStatus)
            }
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

        // 4. Destroy hardware device mappings. IDs are only cleared when the
        // destroy succeeds (or the object is already gone); otherwise the next
        // stop/start retries instead of leaking taps and aggregate devices.
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status == noErr || isDefunctAudioObjectError(status) {
                aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            } else {
                os_log(.error, log: appLog,
                       "%{public}s could not destroy aggregate device %u: OSStatus %d",
                       AppInfo.displayName, aggregateDeviceID, status)
            }
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr || isDefunctAudioObjectError(status) {
                tapID = AudioObjectID(kAudioObjectUnknown)
            } else {
                os_log(.error, log: appLog,
                       "%{public}s could not destroy process tap %u: OSStatus %d",
                       AppInfo.displayName, tapID, status)
            }
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

    private func restart() async {
        guard let deviceID = activeDeviceID, let config = currentConfig else { return }
        stop()
        requestStart(outputDeviceID: deviceID, config: config, retriesRemaining: 2)
        await pendingStartTask?.value
    }

    private func updateConfig(_ config: EQConfig) {
        guard currentConfig != config else { return }
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
            default: defaultSpatialListenerDistanceCm,
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
            default: defaultSpatialStrengthPercent,
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
        let bassMonoCutoffHz = finiteClamped(config.effects.bassMono.cutoffHz, default: 0, min: 0, max: 300)
        let loudnessAmount = finiteClamped(config.effects.loudness.amount, default: 0, min: 0, max: 100)

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
            spatialStrengthPercent: spatialStrengthPercent,
            bassMonoCutoffHz: bassMonoCutoffHz,
            loudnessAmount: loudnessAmount
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
