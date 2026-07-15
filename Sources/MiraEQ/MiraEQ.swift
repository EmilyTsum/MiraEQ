import AppKit
import Foundation
import CoreAudio
import ServiceManagement
import Darwin

private struct PresetSelection {
    let presetFile: String?
}

private enum SpatialTuningComponent {
    case listenerDistance
    case strength
    case reset
}

private struct SpatialTuningSelection {
    let component: SpatialTuningComponent
    let value: Float
}

private struct BassFocusSelection {
    let amountPercent: Float
    let shouldReset: Bool
}

private enum ProcessingTuningComponent {
    case latency
    case spatialEnabled
    case bassHarmonics
    case lowEndGuard
    case bassCompAmount
    case softLimitDrive
    case reset
}

private struct ProcessingTuningSelection {
    let component: ProcessingTuningComponent
    let latencyMode: LatencyMode?
    let boolValue: Bool
    let amountPercent: Float
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, DeviceMonitorDelegate {
    var statusItem: NSStatusItem!
    let audioEngine = AudioEngineManager()
    let deviceMonitor = DeviceMonitor()
    var fileWatcher: FileWatcher!
    
    var mappings: [DeviceMapping] = []
    var activeDevicePresetName: String? = nil
    var activeAddOnPresetName: String? = nil
    var processingTuning = ProcessingTuning.default
    var spatialTuning = SpatialTuning.default
    var bassFocusTuning = BassFocusTuning.default
    var bassPowerTuning = BassPowerTuning.default
    
    let configPath = AppInfo.configPath
    
    lazy var expandedConfigPath: String = {
        (configPath as NSString).expandingTildeInPath
    }()

    lazy var expandedPresetDirectoryPath: String = {
        (AppInfo.presetDirectoryPath as NSString).expandingTildeInPath
    }()

    lazy var expandedDevicePresetDirectoryPath: String = {
        (AppInfo.devicePresetDirectoryPath as NSString).expandingTildeInPath
    }()

    lazy var expandedAddOnPresetDirectoryPath: String = {
        (AppInfo.addOnPresetDirectoryPath as NSString).expandingTildeInPath
    }()

    lazy var expandedDiagnosticsSnapshotPath: String = {
        let directory = (AppInfo.configDirectoryPath as NSString).expandingTildeInPath
        return (directory as NSString).appendingPathComponent("diagnostics.txt")
    }()
    
    var isBuiltInSpeakers = false
    var activeDeviceName = "Unknown"
    var activeDeviceUID = ""
    var activeDeviceID: AudioObjectID = 0
    private var isAudioPausedByUser = false
    private var lastConfigLoadError: Error? = nil
    private var diagnosticsRefreshTimer: Timer?
    private var diagnosticsSnapshotTick = 0
    private var volumeRefreshGeneration: UInt64 = 0
    private var deviceChangeDebounceTask: Task<Void, Never>?
    private let silenceStandbyDefaultsKey = "SilenceStandbyEnabled"
    private var latencyCriticalActivity: NSObjectProtocol?
    private weak var diagnosticsMenu: NSMenu?
    private var engineDiagnosticItem: NSMenuItem?
    private var latencyDiagnosticItem: NSMenuItem?
    private var bufferDiagnosticItem: NSMenuItem?
    private var glitchesDiagnosticItem: NSMenuItem?
    private var renderDiagnosticItem: NSMenuItem?
    private var hardwareBufferDiagnosticItem: NSMenuItem?
    private var formatDiagnosticItem: NSMenuItem?
    private var effectDelayDiagnosticItem: NSMenuItem?
    private var spatialDiagnosticItem: NSMenuItem?
    private var bassFocusDiagnosticItem: NSMenuItem?
    private var lowEndGuardDiagnosticItem: NSMenuItem?
    private var finalSafetyDiagnosticItem: NSMenuItem?
    private var uptimeDiagnosticItem: NSMenuItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory so the app does not show in the dock
        NSApp.setActivationPolicy(.accessory)
        startRealtimeAudioActivity()
        boostProcessPriority()
        ensureSupportFiles()
        
        // Set up Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        
        // Initialize File Watcher
        fileWatcher = FileWatcher(path: expandedConfigPath) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.loadConfig()
            }
        }
        fileWatcher.start()
        
        // Load initial config
        loadConfig()
        startVolumeRefreshTimer()

        if UserDefaults.standard.object(forKey: silenceStandbyDefaultsKey) != nil {
            audioEngine.silenceStandbyEnabled = UserDefaults.standard.bool(forKey: silenceStandbyDefaultsKey)
        }

        audioEngine.onStateChange = { [weak self] in
            guard let self else { return }
            if !self.audioEngine.isActive && !self.audioEngine.isInStandby {
                print(AppInfo.logPrefix("Audio engine is not active for \(self.activeDeviceName)"))
            }
            self.updateIcon()
        }

        // Initialize Device Monitor
        deviceMonitor.delegate = self
        deviceMonitor.startMonitoring()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        deviceChangeDebounceTask?.cancel()
        diagnosticsRefreshTimer?.invalidate()
        volumeRefreshGeneration &+= 1
        deviceMonitor.stopMonitoring()
        fileWatcher.stop()
        audioEngine.stop()
        endRealtimeAudioActivity()
    }

    private func startRealtimeAudioActivity() {
        guard latencyCriticalActivity == nil else { return }

        let latencyCritical = ProcessInfo.ActivityOptions(rawValue: 0xFF00_0000_00)
        latencyCriticalActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, latencyCritical],
            reason: "\(AppInfo.displayName) realtime audio processing"
        )
        print(AppInfo.logPrefix("Started latency-critical audio activity"))
    }

    private func endRealtimeAudioActivity() {
        guard let activity = latencyCriticalActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        latencyCriticalActivity = nil
    }

    private func boostProcessPriority() {
        errno = 0
        let result = setpriority(PRIO_PROCESS, 0, -10)
        if result == 0 {
            print(AppInfo.logPrefix("Raised process priority to nice -10"))
        } else {
            let message = String(cString: strerror(errno))
            print(AppInfo.logPrefix("Could not raise process priority to nice -10: \(message)"))
        }
    }
    
    // MARK: - Config Loading & Routing
    private func ensureSupportFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: expandedDevicePresetDirectoryPath, withIntermediateDirectories: true, attributes: nil)
        try? fm.createDirectory(atPath: expandedAddOnPresetDirectoryPath, withIntermediateDirectories: true, attributes: nil)
        migrateLegacyPresetsIfNeeded()

        for sourceDirectory in bundledPresetDirectories() {
            guard let files = try? fm.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil) else {
                continue
            }

            for sourceURL in files where sourceURL.pathExtension.lowercased() == "txt" {
                let destinationURL = URL(fileURLWithPath: expandedDevicePresetDirectoryPath)
                    .appendingPathComponent(sourceURL.lastPathComponent)

                guard !fm.fileExists(atPath: destinationURL.path) else { continue }

                do {
                    try fm.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    print(AppInfo.logPrefix("Failed to install preset \(sourceURL.lastPathComponent): \(error)"))
                }
            }
        }
    }

    private func bundledPresetDirectories() -> [URL] {
        var directories: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL.appendingPathComponent("presets/device"))
        }

        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        directories.append(executableDirectory.appendingPathComponent("presets/device"))
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        directories.append(workingDirectory.appendingPathComponent("presets/device"))

        return directories
    }

    private func migrateLegacyPresetsIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: expandedPresetDirectoryPath) else { return }

        for file in files where file.hasSuffix(".txt") && file.lowercased() != "config.txt" {
            let sourceURL = URL(fileURLWithPath: expandedPresetDirectoryPath).appendingPathComponent(file)
            let destinationURL = URL(fileURLWithPath: expandedDevicePresetDirectoryPath).appendingPathComponent(file)

            if !fm.fileExists(atPath: destinationURL.path) {
                try? fm.copyItem(at: sourceURL, to: destinationURL)
            }
        }
    }

    private func loadConfig() {
        do {
            let content = try String(contentsOfFile: expandedConfigPath, encoding: .utf8)
            self.mappings = ConfigParser.parseRouting(content: content)
            self.lastConfigLoadError = nil
            print(AppInfo.logPrefix("Loaded routing config: \(self.mappings.count) rules"))
            
            evaluateRouting(deviceID: activeDeviceID)
        } catch {
            self.lastConfigLoadError = error
            print(AppInfo.logPrefix("Failed to load config file: \(error). Keeping previous routing rules (\(self.mappings.count) rules)."))
        }
    }
    
    private func evaluateRouting(deviceID: AudioObjectID) {
        guard deviceID != 0 else {
            audioEngine.stop()
            self.activeDevicePresetName = nil
            self.activeAddOnPresetName = nil
            resetCurrentDeviceTuningToDefaults()
            self.updateIcon()
            return
        }
        
        // Reuse the cached device info when routing the active device to avoid
        // redundant CoreAudio property queries during device-change bursts.
        let info: (name: String, uid: String)
        if deviceID == activeDeviceID, !activeDeviceName.isEmpty, activeDeviceName != "Unknown" {
            info = (activeDeviceName, activeDeviceUID)
        } else {
            let fetched = DeviceMonitor.getDeviceInfo(deviceID: deviceID)
            info = (fetched.name, fetched.uid)
        }

        for mapping in mappings {
            let pattern = mapping.pattern.lowercased()
            if info.name.lowercased() == pattern || info.uid.lowercased() == pattern {
                let deviceConfig = loadPreset(mapping.devicePresetFile, from: expandedDevicePresetDirectoryPath, for: info.name)

                self.activeDevicePresetName = mapping.devicePresetFile
                self.activeAddOnPresetName = mapping.addOnPresetFile

                guard let config = deviceConfig else {
                    audioEngine.stop()
                    self.updateIcon()
                    return
                }
                loadDeviceTuning(from: mapping.addOnPresetFile, for: info.name)
                let effectiveConfig = config
                    .applying(processingTuning: processingTuning, spatialTuning: spatialTuning)
                    .applying(bassFocusTuning: bassFocusTuning)
                    .applying(bassPowerTuning: bassPowerTuning)

                guard !isAudioPausedByUser else {
                    audioEngine.stop()
                    self.updateIcon()
                    return
                }

                audioEngine.requestStart(outputDeviceID: deviceID, config: effectiveConfig)
                self.updateIcon()
                return
            }
        }
        
        // No match found or preset loading failed -> Bypass EQ
        audioEngine.stop()
        self.activeDevicePresetName = nil
        self.activeAddOnPresetName = nil
        resetCurrentDeviceTuningToDefaults()
        self.updateIcon()
    }

    private func loadPreset(_ presetName: String?, from directory: String, for deviceName: String) -> EQConfig? {
        guard let presetName else { return nil }
        let presetPath = (directory as NSString).appendingPathComponent(presetName)

        do {
            let presetContent = try String(contentsOfFile: presetPath, encoding: .utf8)
            let (config, warnings) = ConfigParser.parse(content: presetContent)
            for warning in warnings {
                print(AppInfo.logPrefix("Preset \(presetName) warning: \(warning)"))
            }
            return config
        } catch {
            print(AppInfo.logPrefix("Failed to load preset \(presetName) for \(deviceName): \(error)"))
            return nil
        }
    }

    private func loadDeviceTuning(from addOnPresetName: String?, for deviceName: String) {
        guard let addOnConfig = loadPreset(addOnPresetName, from: expandedAddOnPresetDirectoryPath, for: deviceName) else {
            resetCurrentDeviceTuningToDefaults()
            return
        }

        processingTuning = ProcessingTuning(effects: addOnConfig.effects)
        spatialTuning = SpatialTuning(surround: addOnConfig.effects.surround)
        bassFocusTuning = BassFocusTuning(effects: addOnConfig.effects)
        bassPowerTuning = BassPowerTuning(effects: addOnConfig.effects)
    }

    private func resetCurrentDeviceTuningToDefaults() {
        processingTuning = .default
        spatialTuning = .default
        bassFocusTuning = .default
        bassPowerTuning = .default
    }
    
    // MARK: - DeviceMonitorDelegate
    nonisolated func defaultOutputDeviceDidChange(to deviceID: AudioObjectID, isBuiltInSpeakers: Bool, name: String, uid: String) {
        Task { @MainActor in
            self.scheduleDeviceChange(deviceID: deviceID, isBuiltInSpeakers: isBuiltInSpeakers, name: name, uid: uid)
        }
    }

    /// Debounces rapid default-device flapping so only the last change within
    /// the window is acted on; each engine start is expensive (tap + aggregate
    /// device creation).
    private func scheduleDeviceChange(deviceID: AudioObjectID, isBuiltInSpeakers: Bool, name: String, uid: String) {
        deviceChangeDebounceTask?.cancel()
        deviceChangeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.handleDeviceChange(deviceID: deviceID, isBuiltInSpeakers: isBuiltInSpeakers, name: name, uid: uid)
        }
    }

    private func handleDeviceChange(deviceID: AudioObjectID, isBuiltInSpeakers: Bool, name: String, uid: String) {
        self.activeDeviceID = deviceID
        self.isBuiltInSpeakers = isBuiltInSpeakers
        self.activeDeviceName = name
        self.activeDeviceUID = deviceID == 0 ? "" : uid

        print(AppInfo.logPrefix("Default device changed: \(name)"))
        evaluateRouting(deviceID: deviceID)
    }
    
    // MARK: - Menu Bar Delegate & UI
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        resetDiagnosticMenuItems()
        let diagnostics = audioEngine.diagnostics()
        
        // Status header
        let statusTitle: String
        if isAudioPausedByUser {
            statusTitle = "\(AppInfo.displayName): Paused"
        } else if audioEngine.isActive {
            statusTitle = "\(AppInfo.displayName): Active"
        } else if audioEngine.isInStandby {
            statusTitle = "\(AppInfo.displayName): Standby"
        } else {
            statusTitle = "\(AppInfo.displayName): Bypassed"
        }
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        // Active device
        let deviceItem = NSMenuItem(title: "Device: \(activeDeviceName)", action: nil, keyEquivalent: "")
        deviceItem.isEnabled = false
        menu.addItem(deviceItem)

        addDiagnosticsItems(to: menu, diagnostics: diagnostics)
        
        menu.addItem(.separator())

        if audioEngine.isInStandby {
            let wakeItem = NSMenuItem(title: "Wake from Standby", action: #selector(wakeFromStandby), keyEquivalent: "")
            wakeItem.target = self
            menu.addItem(wakeItem)
        }

        let restartItem = NSMenuItem(title: "Restart Audio Processing", action: #selector(restartAudioProcessing), keyEquivalent: "")
        restartItem.target = self
        restartItem.isEnabled = audioEngine.isActive && audioEngine.canRestart
        menu.addItem(restartItem)

        let pauseTitle = isAudioPausedByUser ? "Resume Audio Processing" : "Pause Audio Processing"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(toggleAudioProcessingPaused), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isEnabled = audioEngine.isActive || audioEngine.isInStandby || isAudioPausedByUser
        menu.addItem(pauseItem)

        // Mute / zero volume always stops capture; this only controls the
        // silence-based trigger.
        let standbyToggle = NSMenuItem(
            title: "Auto-Standby When Silent (2 min)",
            action: #selector(toggleSilenceStandby),
            keyEquivalent: ""
        )
        standbyToggle.target = self
        standbyToggle.state = audioEngine.silenceStandbyEnabled ? .on : .off
        menu.addItem(standbyToggle)
        
        menu.addItem(.separator())
        
        // Explain the per-device model right in the menu: an EQ preset turns
        // processing on for this device; every setting below is stored per
        // device and re-applied whenever this device becomes active.
        let scopeHint = disabledMenuItem(
            title: activeDevicePresetName == nil
                ? "This device is bypassed — choose an EQ preset to enable processing"
                : "EQ + Processing below apply to this device only"
        )
        menu.addItem(scopeHint)

        let presetItem = NSMenuItem(title: "EQ Preset (This Device)", action: nil, keyEquivalent: "")
        presetItem.submenu = makePresetMenu(
            directory: expandedDevicePresetDirectoryPath,
            activePreset: activeDevicePresetName
        )
        presetItem.isEnabled = (activeDeviceID != 0)
        menu.addItem(presetItem)

        let processingItem = NSMenuItem(title: "Processing (This Device)", action: nil, keyEquivalent: "")
        processingItem.submenu = makeProcessingMenu()
        // Processing settings are stored alongside the active preset; without
        // a preset there is nothing to attach them to, so keep this disabled.
        processingItem.isEnabled = (activeDeviceID != 0 && activeDevicePresetName != nil)
        menu.addItem(processingItem)

        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.submenu = makeAdvancedMenu()
        advancedItem.isEnabled = (activeDeviceID != 0)
        menu.addItem(advancedItem)
        
        menu.addItem(.separator())
        
        // Launch at Login
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit \(AppInfo.displayName)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        diagnosticsMenu = menu
        startDiagnosticsRefreshTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopDiagnosticsRefreshTimer()
        diagnosticsMenu = nil
    }

    private func addDiagnosticsItems(to menu: NSMenu, diagnostics: AudioEngineDiagnostics) {
        engineDiagnosticItem = disabledMenuItem(title: "")
        latencyDiagnosticItem = disabledMenuItem(title: "")
        bufferDiagnosticItem = disabledMenuItem(title: "")
        glitchesDiagnosticItem = disabledMenuItem(title: "")
        renderDiagnosticItem = disabledMenuItem(title: "")
        hardwareBufferDiagnosticItem = disabledMenuItem(title: "")
        formatDiagnosticItem = disabledMenuItem(title: "")
        effectDelayDiagnosticItem = disabledMenuItem(title: "")
        spatialDiagnosticItem = disabledMenuItem(title: "")
        bassFocusDiagnosticItem = disabledMenuItem(title: "")
        lowEndGuardDiagnosticItem = disabledMenuItem(title: "")
        finalSafetyDiagnosticItem = disabledMenuItem(title: "")
        uptimeDiagnosticItem = disabledMenuItem(title: "")

        [
            engineDiagnosticItem,
            latencyDiagnosticItem,
            bufferDiagnosticItem,
            glitchesDiagnosticItem,
            renderDiagnosticItem,
            hardwareBufferDiagnosticItem,
            formatDiagnosticItem,
            effectDelayDiagnosticItem,
            spatialDiagnosticItem,
            bassFocusDiagnosticItem,
            lowEndGuardDiagnosticItem,
            finalSafetyDiagnosticItem,
            uptimeDiagnosticItem
        ].compactMap { $0 }.forEach { menu.addItem($0) }

        updateDiagnosticsMenuItems(diagnostics: diagnostics)
    }

    private func updateDiagnosticsMenuItems(diagnostics: AudioEngineDiagnostics) {
        engineDiagnosticItem?.title = "Engine: \(diagnostics.engineRunning ? "Running" : "Stopped")"

        guard diagnostics.isActive else {
            latencyDiagnosticItem?.title = "Latency: --"
            bufferDiagnosticItem?.isHidden = true
            glitchesDiagnosticItem?.isHidden = true
            renderDiagnosticItem?.isHidden = true
            hardwareBufferDiagnosticItem?.isHidden = true
            formatDiagnosticItem?.isHidden = true
            effectDelayDiagnosticItem?.isHidden = true
            spatialDiagnosticItem?.isHidden = true
            bassFocusDiagnosticItem?.isHidden = true
            lowEndGuardDiagnosticItem?.isHidden = true
            finalSafetyDiagnosticItem?.isHidden = true
            uptimeDiagnosticItem?.isHidden = true
            return
        }

        bufferDiagnosticItem?.isHidden = false
        glitchesDiagnosticItem?.isHidden = false
        renderDiagnosticItem?.isHidden = false
        hardwareBufferDiagnosticItem?.isHidden = false
        formatDiagnosticItem?.isHidden = false
        effectDelayDiagnosticItem?.isHidden = diagnostics.effectDelayMs <= 0
        spatialDiagnosticItem?.isHidden = false
        bassFocusDiagnosticItem?.isHidden = false
        lowEndGuardDiagnosticItem?.isHidden = false
        finalSafetyDiagnosticItem?.isHidden = false
        uptimeDiagnosticItem?.isHidden = diagnostics.startedAt == nil

        latencyDiagnosticItem?.title = "Queue: \(formatMilliseconds(diagnostics.bufferedLatencyMs)) now, \(formatMilliseconds(diagnostics.queuedBeforeRenderMs)) callback / \(formatMilliseconds(diagnostics.targetLatencyMs)) config"
        bufferDiagnosticItem?.title = String(
            format: "Buffer: %d frames queued, %.0f%% full, %@ capacity",
            diagnostics.queuedFrames,
            diagnostics.bufferFillPercent,
            formatMilliseconds(diagnostics.bufferCapacityMs)
        )
        glitchesDiagnosticItem?.title = "Glitches: \(diagnostics.underruns) underruns, \(diagnostics.droppedFrames) dropped frames"
        renderDiagnosticItem?.title = "Render Quantum: \(diagnostics.lastRenderFrameCount) frames / \(formatMilliseconds(diagnostics.renderBudgetMs)), idle \(diagnostics.idleRenderCallbacks)"
        hardwareBufferDiagnosticItem?.title = "Hardware Buffer: \(diagnostics.outputBufferFrames) out, \(diagnostics.aggregateBufferFrames) aggregate, \(diagnostics.requestedBufferFrames) requested"
        formatDiagnosticItem?.title = "Format: \(formatSampleRate(diagnostics.sampleRate)), \(diagnostics.channels) ch, in \(diagnostics.lastInputFrameCount) / out \(diagnostics.lastRenderFrameCount)"
        effectDelayDiagnosticItem?.title = "Effect Delay: \(formatMilliseconds(diagnostics.effectDelayMs))"
        spatialDiagnosticItem?.title = String(
            format: "Spatial: %.0f cm, head %.0f cm, %.0f deg, %.0f%%, XTC %@",
            diagnostics.spatialListenerDistanceCm,
            diagnostics.spatialHeadHeightCm,
            diagnostics.spatialDisplayAngleDegrees,
            diagnostics.spatialStrengthPercent,
            formatMilliseconds(diagnostics.crossTalkDelayMs)
        )
        bassFocusDiagnosticItem?.title = String(
            format: "Bass Focus: %.0f%%, volume %.0f%%, high -%.1f dB",
            diagnostics.bassFocusAmountPercent,
            diagnostics.outputVolumePercent,
            diagnostics.bassFocusReductionDb
        )
        lowEndGuardDiagnosticItem?.title = String(
            format: "Low Guard: -%.1f dB now, avg -%.1f / max -%.1f, peak %.1f dB",
            diagnostics.lowEndGuardReductionDb,
            diagnostics.lowEndGuardAverageReductionDb,
            diagnostics.lowEndGuardMaxReductionDb,
            diagnostics.lowEndGuardPeakDb
        )
        finalSafetyDiagnosticItem?.title = String(format: "Final Safety: comp -%.1f dB + peak limiter", diagnostics.finalSafetyCompressionDb)

        if let startedAt = diagnostics.startedAt {
            uptimeDiagnosticItem?.title = "Uptime: \(formatDuration(Date().timeIntervalSince(startedAt)))"
        }
    }

    private func resetDiagnosticMenuItems() {
        engineDiagnosticItem = nil
        latencyDiagnosticItem = nil
        bufferDiagnosticItem = nil
        glitchesDiagnosticItem = nil
        renderDiagnosticItem = nil
        hardwareBufferDiagnosticItem = nil
        formatDiagnosticItem = nil
        effectDelayDiagnosticItem = nil
        spatialDiagnosticItem = nil
        bassFocusDiagnosticItem = nil
        lowEndGuardDiagnosticItem = nil
        finalSafetyDiagnosticItem = nil
        uptimeDiagnosticItem = nil
    }

    private func startDiagnosticsRefreshTimer() {
        diagnosticsRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.diagnosticsMenu != nil else { return }
                self.updateDiagnosticsMenuItems(diagnostics: self.audioEngine.diagnostics())
            }
        }
        diagnosticsRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateDiagnosticsMenuItems(diagnostics: audioEngine.diagnostics())
    }

    private func stopDiagnosticsRefreshTimer() {
        diagnosticsRefreshTimer?.invalidate()
        diagnosticsRefreshTimer = nil
    }

    private func startVolumeRefreshTimer() {
        volumeRefreshGeneration &+= 1
        scheduleVolumeRefreshTick(generation: volumeRefreshGeneration)
        writeDiagnosticsSnapshot()
    }

    private func scheduleVolumeRefreshTick(generation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor in
                guard let self, self.volumeRefreshGeneration == generation else { return }
                self.audioEngine.refreshOutputVolumeScalar()
                if !self.isAudioPausedByUser, self.audioEngine.updateAutoStandby() {
                    self.updateIcon()
                }
                // Only write the diagnostics snapshot while processing is
                // running; otherwise this would touch the disk forever.
                if self.audioEngine.isActive {
                    self.diagnosticsSnapshotTick += 1
                    if self.diagnosticsSnapshotTick >= 2 {
                        self.diagnosticsSnapshotTick = 0
                        self.writeDiagnosticsSnapshot()
                    }
                }
                self.scheduleVolumeRefreshTick(generation: generation)
            }
        }
    }

    private func writeDiagnosticsSnapshot() {
        let diagnostics = audioEngine.diagnostics()

        let directory = (expandedDiagnosticsSnapshotPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)

        let updatedAt = ISO8601DateFormatter().string(from: Date())
        let lines = [
            "MiraEQ diagnostics",
            "updated: \(updatedAt)",
            "",
            "active: \(diagnostics.isActive ? "true" : "false")",
            "silentSeconds: \(String(format: "%.1f", audioEngine.secondsSinceLastAudible()))",
            "lastAudiblePeak: \(String(format: "%.5f", audioEngine.lastAudiblePeak()))",
            "startCount: \(diagnostics.startCount)",
            "engine: \(diagnostics.engineRunning ? "running" : "stopped")",
            "device: \(diagnostics.activeDeviceName ?? "Unknown")",
            "sampleRate: \(Int(diagnostics.sampleRate.rounded()))",
            "channels: \(diagnostics.channels)",
            "targetLatencyMs: \(String(format: "%.2f", diagnostics.targetLatencyMs))",
            "queueMs: \(String(format: "%.2f", diagnostics.bufferedLatencyMs))",
            "callbackMs: \(String(format: "%.2f", diagnostics.queuedBeforeRenderMs))",
            "bufferCapacityMs: \(String(format: "%.2f", diagnostics.bufferCapacityMs))",
            "requestedBufferFrames: \(diagnostics.requestedBufferFrames)",
            "outputBufferFrames: \(diagnostics.outputBufferFrames)",
            "aggregateBufferFrames: \(diagnostics.aggregateBufferFrames)",
            "outputVolumePercent: \(String(format: "%.0f", diagnostics.outputVolumePercent))",
            "bassFocusAmountPercent: \(String(format: "%.0f", diagnostics.bassFocusAmountPercent))",
            "bassFocusReductionDb: \(String(format: "%.2f", diagnostics.bassFocusReductionDb))",
            "lowGuardReductionDb: \(String(format: "%.2f", diagnostics.lowEndGuardReductionDb))",
            "lowGuardAverageReductionDb: \(String(format: "%.2f", diagnostics.lowEndGuardAverageReductionDb))",
            "lowGuardMaxReductionDb: \(String(format: "%.2f", diagnostics.lowEndGuardMaxReductionDb))",
            "lowGuardPeakDb: \(String(format: "%.2f", diagnostics.lowEndGuardPeakDb))",
            "finalSafetyCompressionDb: \(String(format: "%.2f", diagnostics.finalSafetyCompressionDb))",
            "renderCallbacks: \(diagnostics.renderCallbacks)",
            "idleRenderCallbacks: \(diagnostics.idleRenderCallbacks)",
            "ioCallbacks: \(diagnostics.ioCallbacks)",
            "lastRenderFrames: \(diagnostics.lastRenderFrameCount)",
            "lastInputFrames: \(diagnostics.lastInputFrameCount)",
            "renderLastMs: \(String(format: "%.3f", diagnostics.lastRenderDurationMs))",
            "renderMaxMs: \(String(format: "%.3f", diagnostics.maxRenderDurationMs))",
            "renderBudgetMs: \(String(format: "%.3f", diagnostics.renderBudgetMs))",
            "underruns: \(diagnostics.underruns)",
            "underrunFrames: \(diagnostics.underrunFrames)",
            "lastUnderrunFrames: \(diagnostics.lastUnderrunFrames)",
            "droppedFrames: \(diagnostics.droppedFrames)"
        ]

        try? lines.joined(separator: "\n")
            .appending("\n")
            .write(toFile: expandedDiagnosticsSnapshotPath, atomically: true, encoding: .utf8)
    }

    private func disabledMenuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func formatMilliseconds(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f ms", value)
        }
        if value >= 10 {
            return String(format: "%.1f ms", value)
        }
        return String(format: "%.2f ms", value)
    }

    private func formatSampleRate(_ sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "--" }
        if sampleRate >= 1_000 {
            return String(format: "%.1f kHz", sampleRate / 1_000)
        }
        return String(format: "%.0f Hz", sampleRate)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
    
    private func makePresetMenu(directory: String, activePreset: String?) -> NSMenu {
        let presetMenu = NSMenu()

        let bypassItem = NSMenuItem(title: "None (Bypass This Device)", action: #selector(selectPresetItem(_:)), keyEquivalent: "")
        bypassItem.target = self
        bypassItem.representedObject = PresetSelection(presetFile: nil)
        bypassItem.state = (activePreset == nil) ? .on : .off
        presetMenu.addItem(bypassItem)
        presetMenu.addItem(.separator())

        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: directory) {
            let txtFiles = files.filter { $0.hasSuffix(".txt") && $0.lowercased() != "config.txt" }.sorted()
            for file in txtFiles {
                let displayName = presetDisplayName(for: file, in: directory)
                let item = NSMenuItem(title: displayName, action: #selector(selectPresetItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = PresetSelection(presetFile: file)
                item.state = (activePreset == file) ? .on : .off
                presetMenu.addItem(item)
            }
        }

        return presetMenu
    }

    private func presetDisplayName(for file: String, in directory: String) -> String {
        let presetPath = (directory as NSString).appendingPathComponent(file)
        if let content = try? String(contentsOfFile: presetPath, encoding: .utf8) {
            // Accept both the current and the legacy (pre-rename) title prefix.
            let titlePrefixes = ["# MiraEQ Preset:", "# MiraEq Preset:"]
            for titlePrefix in titlePrefixes {
                if let titleLine = content.components(separatedBy: .newlines)
                    .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(titlePrefix) }) {
                    let title = titleLine
                        .replacingOccurrences(of: titlePrefix, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        return title
                    }
                }
            }
        }

        let baseName = (file as NSString).deletingPathExtension
        let normalized = baseName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        return normalized
    }

    private func makeProcessingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledMenuItem(title: "Saved for: \(activeDeviceName)"))
        menu.addItem(disabledMenuItem(title: "Pipeline: 32-bit float, final compressor + peak limiter"))
        menu.addItem(.separator())

        let latencyItem = NSMenuItem(title: "Latency", action: nil, keyEquivalent: "")
        latencyItem.submenu = makeLatencyMenu()
        menu.addItem(latencyItem)

        let spatialItem = NSMenuItem(title: "Spatial", action: nil, keyEquivalent: "")
        spatialItem.submenu = makeSpatialMenu()
        menu.addItem(spatialItem)

        let harmonicsItem = NSMenuItem(title: "Bass Harmonics", action: nil, keyEquivalent: "")
        harmonicsItem.submenu = makeBassHarmonicsMenu()
        menu.addItem(harmonicsItem)

        let bassFocusItem = NSMenuItem(title: "Bass Focus", action: nil, keyEquivalent: "")
        bassFocusItem.submenu = makeBassFocusMenu()
        menu.addItem(bassFocusItem)

        let lowGuardItem = NSMenuItem(title: "Low Guard", action: nil, keyEquivalent: "")
        lowGuardItem.submenu = makeLowEndGuardMenu()
        menu.addItem(lowGuardItem)

        let bassPowerItem = NSMenuItem(title: "Bass Power", action: nil, keyEquivalent: "")
        bassPowerItem.submenu = makeBassPowerMenu()
        menu.addItem(bassPowerItem)

        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset Processing", action: #selector(selectProcessingTuningItem(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.representedObject = ProcessingTuningSelection(component: .reset, latencyMode: nil, boolValue: false, amountPercent: 0)
        menu.addItem(resetItem)

        return menu
    }

    private func makeLatencyMenu() -> NSMenu {
        let menu = NSMenu()
        addProcessingItem(to: menu, title: "Standard (12 ms)", component: .latency, latencyMode: .standard)
        addProcessingItem(to: menu, title: "Low (5 ms)", component: .latency, latencyMode: .low)
        addProcessingItem(to: menu, title: "Ultra (1 ms)", component: .latency, latencyMode: .ultra)
        return menu
    }

    private func makeSpatialMenu() -> NSMenu {
        let menu = NSMenu()
        addProcessingItem(to: menu, title: "On", component: .spatialEnabled, boolValue: true)
        addProcessingItem(to: menu, title: "Off", component: .spatialEnabled, boolValue: false)
        menu.addItem(.separator())

        let positionItem = NSMenuItem(title: "Position Model", action: nil, keyEquivalent: "")
        positionItem.submenu = makeSpatialTuningMenu()
        menu.addItem(positionItem)
        return menu
    }

    private func makeBassHarmonicsMenu() -> NSMenu {
        let menu = NSMenu()
        addProcessingItem(to: menu, title: "Off", component: .bassHarmonics, amountPercent: 0)
        addProcessingItem(to: menu, title: "Light (6%)", component: .bassHarmonics, amountPercent: 6)
        addProcessingItem(to: menu, title: "Normal (8%)", component: .bassHarmonics, amountPercent: 8)
        addProcessingItem(to: menu, title: "Strong (12%)", component: .bassHarmonics, amountPercent: 12)
        return menu
    }

    private func makeLowEndGuardMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledMenuItem(title: "Auto-strength near max system volume"))
        menu.addItem(.separator())
        addProcessingItem(to: menu, title: "Off", component: .lowEndGuard, amountPercent: 0)
        addProcessingItem(to: menu, title: "Light", component: .lowEndGuard, amountPercent: 30)
        addProcessingItem(to: menu, title: "Normal", component: .lowEndGuard, amountPercent: 45)
        addProcessingItem(to: menu, title: "Strong", component: .lowEndGuard, amountPercent: 65)
        return menu
    }

    private func makeBassPowerMenu() -> NSMenu {
        let menu = NSMenu()

        let bassCompItem = NSMenuItem(title: "BassComp", action: nil, keyEquivalent: "")
        let bassCompMenu = NSMenu()
        addProcessingItem(to: bassCompMenu, title: "Off", component: .bassCompAmount, amountPercent: 0)
        addProcessingItem(to: bassCompMenu, title: "Light (25%)", component: .bassCompAmount, amountPercent: 25)
        addProcessingItem(to: bassCompMenu, title: "Normal (50%)", component: .bassCompAmount, amountPercent: 50)
        addProcessingItem(to: bassCompMenu, title: "Strong (75%)", component: .bassCompAmount, amountPercent: 75)
        addProcessingItem(to: bassCompMenu, title: "Max (100%)", component: .bassCompAmount, amountPercent: 100)
        bassCompItem.submenu = bassCompMenu
        menu.addItem(bassCompItem)

        let softLimitItem = NSMenuItem(title: "SoftLimit", action: nil, keyEquivalent: "")
        let softLimitMenu = NSMenu()
        addProcessingItem(to: softLimitMenu, title: "Off", component: .softLimitDrive, amountPercent: 0)
        addProcessingItem(to: softLimitMenu, title: "Light (30%)", component: .softLimitDrive, amountPercent: 30)
        addProcessingItem(to: softLimitMenu, title: "Strong (60%)", component: .softLimitDrive, amountPercent: 60)
        softLimitItem.submenu = softLimitMenu
        menu.addItem(softLimitItem)

        return menu
    }

    private func addProcessingItem(
        to menu: NSMenu,
        title: String,
        component: ProcessingTuningComponent,
        latencyMode: LatencyMode? = nil,
        boolValue: Bool = false,
        amountPercent: Float = 0
    ) {
        let item = NSMenuItem(title: title, action: #selector(selectProcessingTuningItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ProcessingTuningSelection(
            component: component,
            latencyMode: latencyMode,
            boolValue: boolValue,
            amountPercent: amountPercent
        )

        switch component {
        case .latency:
            item.state = processingTuning.latencyMode == latencyMode ? .on : .off
        case .spatialEnabled:
            item.state = processingTuning.spatialEnabled == boolValue ? .on : .off
        case .bassHarmonics:
            item.state = abs(processingTuning.bassHarmonicsAmount - amountPercent) < 0.5 ? .on : .off
        case .lowEndGuard:
            item.state = abs(processingTuning.lowEndGuardAmount - amountPercent) < 0.5 ? .on : .off
        case .bassCompAmount:
            item.state = abs(bassPowerTuning.bassCompAmountPercent - amountPercent) < 0.5 ? .on : .off
        case .softLimitDrive:
            item.state = abs(bassPowerTuning.softLimitDrivePercent - amountPercent) < 0.5 ? .on : .off
        case .reset:
            item.state = .off
        }

        menu.addItem(item)
    }

    private func makeAdvancedMenu() -> NSMenu {
        let menu = NSMenu()
        let openConfig = NSMenuItem(title: "Open Routing Config", action: #selector(openConfigFile), keyEquivalent: "c")
        openConfig.target = self
        menu.addItem(openConfig)

        let reloadConfig = NSMenuItem(title: "Reload Config", action: #selector(manualReload), keyEquivalent: "r")
        reloadConfig.target = self
        menu.addItem(reloadConfig)

        return menu
    }

    private func makeSpatialTuningMenu() -> NSMenu {
        let menu = NSMenu()
        let summary = disabledMenuItem(
            title: String(
                format: "Distance: %.0f cm, Strength: %.0f%%",
                spatialTuning.listenerDistanceCm,
                spatialTuning.strengthPercent
            )
        )
        menu.addItem(summary)
        menu.addItem(.separator())

        addSpatialOptionMenu(
            to: menu,
            title: "Distance",
            component: .listenerDistance,
            currentValue: spatialTuning.listenerDistanceCm,
            options: [
                ("35 cm", 35),
                ("40 cm", 40),
                ("45 cm", 45),
                ("50 cm", 50)
            ]
        )
        addSpatialOptionMenu(
            to: menu,
            title: "Strength",
            component: .strength,
            currentValue: spatialTuning.strengthPercent,
            options: [
                ("Soft (80%)", 80),
                ("Normal (100%)", 100),
                ("Strong (120%)", 120)
            ]
        )

        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset Spatial Model", action: #selector(selectSpatialTuningItem(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.representedObject = SpatialTuningSelection(component: .reset, value: 0)
        menu.addItem(resetItem)

        return menu
    }

    private func addSpatialOptionMenu(
        to menu: NSMenu,
        title: String,
        component: SpatialTuningComponent,
        currentValue: Float,
        options: [(String, Float)]
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for option in options {
            let optionItem = NSMenuItem(title: option.0, action: #selector(selectSpatialTuningItem(_:)), keyEquivalent: "")
            optionItem.target = self
            optionItem.representedObject = SpatialTuningSelection(component: component, value: option.1)
            optionItem.state = abs(currentValue - option.1) < 0.5 ? .on : .off
            submenu.addItem(optionItem)
        }

        item.submenu = submenu
        menu.addItem(item)
    }

    private func makeBassFocusMenu() -> NSMenu {
        let menu = NSMenu()
        let summary = disabledMenuItem(title: String(format: "Amount: %.0f%%", bassFocusTuning.amountPercent))
        menu.addItem(summary)
        menu.addItem(.separator())

        let options: [(String, Float)] = [
            ("Off", 0),
            ("Light (30%)", 30),
            ("Normal (50%)", 50),
            ("Strong (70%)", 70)
        ]

        for option in options {
            let item = NSMenuItem(title: option.0, action: #selector(selectBassFocusItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = BassFocusSelection(amountPercent: option.1, shouldReset: false)
            item.state = abs(bassFocusTuning.amountPercent - option.1) < 0.5 ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset Bass Focus", action: #selector(selectBassFocusItem(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.representedObject = BassFocusSelection(amountPercent: 0, shouldReset: true)
        menu.addItem(resetItem)

        return menu
    }

    @objc func selectPresetItem(_ sender: NSMenuItem) {
        guard activeDeviceID != 0 else { return }
        let targetDevice = activeDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetDevice.isEmpty else { return }
        
        guard let selection = sender.representedObject as? PresetSelection else { return }
        var newMappings = self.mappings
        let currentDevicePatterns = Set(
            [targetDevice, activeDeviceUID]
                .map(normalizedRoutingPattern)
                .filter { !$0.isEmpty }
        )
        let existing = newMappings.first { currentDevicePatterns.contains(normalizedRoutingPattern($0.pattern)) }
        var devicePreset = existing?.devicePresetFile ?? activeDevicePresetName
        let addOnPreset = existing?.addOnPresetFile ?? hiddenAddOnPresetName(forDeviceName: targetDevice, uid: activeDeviceUID)
        
        // Remove existing exact-name or UID mapping for the active device.
        newMappings.removeAll { currentDevicePatterns.contains(normalizedRoutingPattern($0.pattern)) }

        devicePreset = selection.presetFile

        if devicePreset == nil {
            print(AppInfo.logPrefix("Setting full bypass for \(targetDevice)"))
        } else {
            print(AppInfo.logPrefix("Mapping \(targetDevice) -> Device: \(devicePreset ?? "None")"))
            let newMapping = DeviceMapping(pattern: targetDevice, devicePresetFile: devicePreset, addOnPresetFile: addOnPreset)
            newMappings.insert(newMapping, at: 0) // Prepend to evaluate first
        }
        
        let content = ConfigParser.writeRouting(mappings: newMappings)
        
        // Temporarily stop the file watcher to prevent it from intercepting our own atomic write
        fileWatcher.stop()
        
        do {
            if devicePreset != nil {
                try writeHiddenTuningPreset(named: addOnPreset)
            }
            try content.write(toFile: expandedConfigPath, atomically: true, encoding: .utf8)
            // Immediately reload routing config and re-evaluate
            loadConfig()
        } catch {
            print(AppInfo.logPrefix("Failed to write config file: \(error)"))
        }
        
        // Safely restart the file watcher now that the file write is completed
        fileWatcher.start()
    }

    private func normalizedRoutingPattern(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func currentDeviceRoutingPatterns() -> Set<String> {
        Set(
            [activeDeviceName, activeDeviceUID]
                .map(normalizedRoutingPattern)
                .filter { !$0.isEmpty }
        )
    }

    private func hiddenAddOnPresetName(forDeviceName deviceName: String, uid: String) -> String {
        let source = uid.isEmpty ? deviceName : uid
        var sanitized = source.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        if sanitized.isEmpty {
            sanitized = Array("Device")
        }
        let base = String(sanitized).split(separator: "_").joined(separator: "_")
        return ".MiraEQ_\(String(base.prefix(80)))_Processing.txt"
    }

    private func ensureActiveHiddenAddOnPreset() -> String? {
        guard activeDeviceID != 0, activeDevicePresetName != nil else { return nil }
        let targetDevice = activeDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetDevice.isEmpty else { return nil }

        let patterns = currentDeviceRoutingPatterns()
        if let index = mappings.firstIndex(where: { patterns.contains(normalizedRoutingPattern($0.pattern)) }) {
            if let addOnPreset = mappings[index].addOnPresetFile {
                activeAddOnPresetName = addOnPreset
                return addOnPreset
            }

            let addOnPreset = hiddenAddOnPresetName(forDeviceName: targetDevice, uid: activeDeviceUID)
            mappings[index].addOnPresetFile = addOnPreset
            activeAddOnPresetName = addOnPreset
            writeRoutingFile()
            return addOnPreset
        }

        let addOnPreset = hiddenAddOnPresetName(forDeviceName: targetDevice, uid: activeDeviceUID)
        mappings.insert(
            DeviceMapping(pattern: targetDevice, devicePresetFile: activeDevicePresetName, addOnPresetFile: addOnPreset),
            at: 0
        )
        activeAddOnPresetName = addOnPreset
        writeRoutingFile()
        return addOnPreset
    }

    private func writeRoutingFile() {
        let content = ConfigParser.writeRouting(mappings: mappings)
        fileWatcher.stop()
        do {
            try content.write(toFile: expandedConfigPath, atomically: true, encoding: .utf8)
        } catch {
            print(AppInfo.logPrefix("Failed to write config file: \(error)"))
        }
        fileWatcher.start()
    }

    private func persistActiveDeviceTuning() {
        guard let addOnPreset = ensureActiveHiddenAddOnPreset() else { return }
        do {
            try writeHiddenTuningPreset(named: addOnPreset)
        } catch {
            print(AppInfo.logPrefix("Failed to write hidden processing preset \(addOnPreset): \(error)"))
        }
    }

    private func writeHiddenTuningPreset(named presetName: String) throws {
        try FileManager.default.createDirectory(
            atPath: expandedAddOnPresetDirectoryPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let presetPath = (expandedAddOnPresetDirectoryPath as NSString).appendingPathComponent(presetName)
        let content = hiddenTuningPresetContent(
            processingTuning: processingTuning,
            spatialTuning: spatialTuning,
            bassFocusTuning: bassFocusTuning,
            bassPowerTuning: bassPowerTuning
        )
        try content.write(toFile: presetPath, atomically: true, encoding: .utf8)
    }
}

func hiddenTuningPresetContent(
    processingTuning: ProcessingTuning,
    spatialTuning: SpatialTuning,
    bassFocusTuning: BassFocusTuning,
    bassPowerTuning: BassPowerTuning
) -> String {
    let latencyMs = processingTuning.latencyMode.targetMs
    let spatialWidth: Float = processingTuning.spatialEnabled ? 30 : 0
    let spatialReverb: Float = processingTuning.spatialEnabled ? 7 : 0
    let spatialRear: Float = processingTuning.spatialEnabled ? 56 : 0
    let delayTime: Float = processingTuning.spatialEnabled ? 5 : 0
    let delayMix: Float = processingTuning.spatialEnabled ? 4 : 0
    let bassCompLine = bassPowerTuning.bassCompAmountIsSet
        ? "Effect: BassComp amount \(formatPresetNumber(bassPowerTuning.bassCompAmountPercent)) crossover \(formatPresetNumber(bassPowerTuning.bassCompCrossoverHz)) Hz\n"
        : ""
    let softLimitLine = bassPowerTuning.softLimitDriveIsSet
        ? "Effect: SoftLimit drive \(formatPresetNumber(bassPowerTuning.softLimitDrivePercent))\n"
        : ""

    return """
    # MiraEQ Hidden Processing Preset
    # This file stores per-device menu settings. It is managed by the app.
    Effect: Latency target \(formatPresetNumber(latencyMs)) ms
    Effect: Delay time \(formatPresetNumber(delayTime)) ms feedback 0 mix \(formatPresetNumber(delayMix))
    Effect: Surround width \(formatPresetNumber(spatialWidth)) reverb \(formatPresetNumber(spatialReverb)) rear \(formatPresetNumber(spatialRear)) reardelay 4.2 ms shadow 58 distance \(formatPresetNumber(spatialTuning.listenerDistanceCm)) strength \(formatPresetNumber(spatialTuning.strengthPercent))
    Effect: BassHarmonics amount \(formatPresetNumber(processingTuning.bassHarmonicsAmount)) cutoff \(formatPresetNumber(processingTuning.bassHarmonicsCutoffHz)) Hz speaker \(formatPresetNumber(processingTuning.bassHarmonicsSpeakerCutoffHz)) Hz
    Effect: LowEndGuard amount \(formatPresetNumber(processingTuning.lowEndGuardAmount)) threshold -18 cutoff 180 Hz ratio 4 maxreduction 4.5
    Effect: BassFocus amount \(formatPresetNumber(bassFocusTuning.amountPercent)) threshold -18 highcut 7
    \(bassCompLine)\(softLimitLine)
    """
}

func formatPresetNumber(_ value: Float) -> String {
    if abs(value.rounded() - value) < 0.001 {
        return String(format: "%.0f", value)
    }
    return String(format: "%.2f", value)
}

extension AppDelegate {

    @objc func selectSpatialTuningItem(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SpatialTuningSelection else { return }

        switch selection.component {
        case .listenerDistance:
            spatialTuning.listenerDistanceCm = selection.value
            spatialTuning.distanceIsSet = true
        case .strength:
            spatialTuning.strengthPercent = selection.value
            spatialTuning.strengthIsSet = true
        case .reset:
            spatialTuning = .default
        }

        persistActiveDeviceTuning()
        evaluateRouting(deviceID: activeDeviceID)
        updateDiagnosticsMenuItems(diagnostics: audioEngine.diagnostics())
    }

    @objc func selectProcessingTuningItem(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ProcessingTuningSelection else { return }

        switch selection.component {
        case .latency:
            if let latencyMode = selection.latencyMode {
                processingTuning.latencyMode = latencyMode
            }
        case .spatialEnabled:
            processingTuning.spatialEnabled = selection.boolValue
        case .bassHarmonics:
            processingTuning.bassHarmonicsAmount = selection.amountPercent
        case .lowEndGuard:
            processingTuning.lowEndGuardAmount = selection.amountPercent
        case .bassCompAmount:
            bassPowerTuning.bassCompAmountPercent = selection.amountPercent
            bassPowerTuning.bassCompAmountIsSet = true
        case .softLimitDrive:
            bassPowerTuning.softLimitDrivePercent = selection.amountPercent
            bassPowerTuning.softLimitDriveIsSet = true
        case .reset:
            processingTuning = .default
            bassFocusTuning = .default
            bassPowerTuning = .default
        }

        persistActiveDeviceTuning()
        evaluateRouting(deviceID: activeDeviceID)
        updateDiagnosticsMenuItems(diagnostics: audioEngine.diagnostics())
    }

    @objc func selectBassFocusItem(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? BassFocusSelection else { return }

        if selection.shouldReset {
            bassFocusTuning = .default
        } else {
            bassFocusTuning.amountPercent = selection.amountPercent
        }

        persistActiveDeviceTuning()
        evaluateRouting(deviceID: activeDeviceID)
        updateDiagnosticsMenuItems(diagnostics: audioEngine.diagnostics())
    }
    
    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            do {
                try service.unregister()
                print(AppInfo.logPrefix("Disabled launch at login"))
            } catch {
                print(AppInfo.logPrefix("Failed to unregister launch at login: \(error)"))
            }
        } else {
            do {
                try service.register()
                print(AppInfo.logPrefix("Enabled launch at login"))
            } catch {
                print(AppInfo.logPrefix("Failed to register launch at login: \(error)"))
            }
        }
    }
    
    @objc func openConfigFile() {
        let url = URL(fileURLWithPath: expandedConfigPath)
        NSWorkspace.shared.open(url)
    }
    
    @objc func manualReload() {
        loadConfig()
    }

    @objc func toggleSilenceStandby() {
        audioEngine.silenceStandbyEnabled.toggle()
        UserDefaults.standard.set(audioEngine.silenceStandbyEnabled, forKey: silenceStandbyDefaultsKey)
        // Turning silence standby off while already in silence-standby should
        // bring processing back.
        if !audioEngine.silenceStandbyEnabled, audioEngine.isInStandby {
            audioEngine.wakeFromStandbyNow()
        }
        print(AppInfo.logPrefix("Silence standby \(audioEngine.silenceStandbyEnabled ? "enabled" : "disabled")"))
    }

    @objc func wakeFromStandby() {
        audioEngine.wakeFromStandbyNow()
    }

    @objc func restartAudioProcessing() {
        guard audioEngine.canRestart else { return }
        print(AppInfo.logPrefix("Restarting audio processing"))
        Task { @MainActor in
            await self.audioEngine.restart()
            self.updateIcon()
        }
    }

    @objc func toggleAudioProcessingPaused() {
        if isAudioPausedByUser {
            isAudioPausedByUser = false
            print(AppInfo.logPrefix("Resuming audio processing"))
            evaluateRouting(deviceID: activeDeviceID)
        } else {
            isAudioPausedByUser = true
            print(AppInfo.logPrefix("Pausing audio processing"))
            audioEngine.stop()
            updateIcon()
        }
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
    
    private func updateIcon() {
        if let button = statusItem.button {
            button.title = ""
            if let image = NSImage(systemSymbolName: AppInfo.statusIconSymbolName, accessibilityDescription: AppInfo.displayName) {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
                button.image?.isTemplate = true
            }
            button.appearsDisabled = !audioEngine.isActive
        }
    }
}

@main
struct MiraEQ {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 4 && args[1] == "--print-effective-config" {
            let devicePreset = args[2]
            let hiddenPreset = args[3]
            do {
                try verifyRoundTrip(devicePresetName: devicePreset, addOnPresetName: hiddenPreset)
                let config = try effectiveConfig(devicePresetName: devicePreset, addOnPresetName: hiddenPreset)
                print("round-trip check: OK")
                printEffectiveConfig(config)
            } catch {
                print("Error: \(error)")
                exit(1)
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
