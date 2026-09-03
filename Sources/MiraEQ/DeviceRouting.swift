import AppKit
import Foundation
import CoreAudio

// MARK: - Device Routing & Tuning Persistence
//
// Everything that maps the current output device to an EQ preset and keeps
// per-device tuning state on disk: routing-config loading, preset parsing,
// hidden per-device processing presets, and DeviceMonitorDelegate handling.

extension AppDelegate {
    // MARK: - Config Loading & Routing
    func ensureSupportFiles() {
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

        // Seed per-device processing presets (e.g. the tuned built-in speaker
        // setup) on fresh installs. Existing files are never overwritten, so
        // user edits always win.
        for sourceDirectory in bundledAddOnPresetDirectories() {
            guard let files = try? fm.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil) else {
                continue
            }

            for sourceURL in files where sourceURL.pathExtension.lowercased() == "txt" {
                let destinationURL = URL(fileURLWithPath: expandedAddOnPresetDirectoryPath)
                    .appendingPathComponent(sourceURL.lastPathComponent)

                guard !fm.fileExists(atPath: destinationURL.path) else { continue }

                do {
                    try fm.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    print(AppInfo.logPrefix("Failed to install processing preset \(sourceURL.lastPathComponent): \(error)"))
                }
            }
        }
    }

    func bundledPresetDirectories() -> [URL] {
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

    func bundledAddOnPresetDirectories() -> [URL] {
        var directories: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL.appendingPathComponent("presets/addons"))
        }

        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        directories.append(executableDirectory.appendingPathComponent("presets/addons"))
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        directories.append(workingDirectory.appendingPathComponent("presets/addons"))

        return directories
    }

    func migrateLegacyPresetsIfNeeded() {
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

    /// Debounces preset-directory change events (an editor save can emit
    /// several) into one config reload.
    func schedulePresetReload() {
        presetReloadDebounceTask?.cancel()
        presetReloadDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            print(AppInfo.logPrefix("Preset files changed; reloading"))
            self.loadConfig()
        }
    }

    func loadConfig() {
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

    func evaluateRouting(deviceID: AudioObjectID) {
        guard deviceID != 0 else {
            audioEngine.stop()
            self.activeDevicePresetName = nil
            self.activeAddOnPresetName = nil
            resetCurrentDeviceTuningToDefaults()
            self.updateIcon()
            self.updateRealtimeAudioActivity()
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
                    self.updateRealtimeAudioActivity()
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
                    self.updateRealtimeAudioActivity()
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
        self.updateRealtimeAudioActivity()
    }

    func loadPreset(_ presetName: String?, from directory: String, for deviceName: String) -> EQConfig? {
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

    func loadDeviceTuning(from addOnPresetName: String?, for deviceName: String) {
        guard let addOnConfig = loadPreset(addOnPresetName, from: expandedAddOnPresetDirectoryPath, for: deviceName) else {
            resetCurrentDeviceTuningToDefaults()
            return
        }

        processingTuning = ProcessingTuning(effects: addOnConfig.effects)
        spatialTuning = SpatialTuning(surround: addOnConfig.effects.surround)
        bassFocusTuning = BassFocusTuning(effects: addOnConfig.effects)
        bassPowerTuning = BassPowerTuning(effects: addOnConfig.effects)
    }

    func resetCurrentDeviceTuningToDefaults() {
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
    func scheduleDeviceChange(deviceID: AudioObjectID, isBuiltInSpeakers: Bool, name: String, uid: String) {
        deviceChangeDebounceTask?.cancel()
        deviceChangeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.handleDeviceChange(deviceID: deviceID, isBuiltInSpeakers: isBuiltInSpeakers, name: name, uid: uid)
        }
    }

    func handleDeviceChange(deviceID: AudioObjectID, isBuiltInSpeakers: Bool, name: String, uid: String) {
        self.activeDeviceID = deviceID
        self.isBuiltInSpeakers = isBuiltInSpeakers
        self.activeDeviceName = name
        self.activeDeviceUID = deviceID == 0 ? "" : uid

        print(AppInfo.logPrefix("Default device changed: \(name)"))
        evaluateRouting(deviceID: deviceID)
    }

    // MARK: - Preset Selection & Hidden Tuning Presets
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

    func normalizedRoutingPattern(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func currentDeviceRoutingPatterns() -> Set<String> {
        Set(
            [activeDeviceName, activeDeviceUID]
                .map(normalizedRoutingPattern)
                .filter { !$0.isEmpty }
        )
    }

    func hiddenAddOnPresetName(forDeviceName deviceName: String, uid: String) -> String {
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

    func ensureActiveHiddenAddOnPreset() -> String? {
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

    func writeRoutingFile() {
        let content = ConfigParser.writeRouting(mappings: mappings)
        fileWatcher.stop()
        do {
            try content.write(toFile: expandedConfigPath, atomically: true, encoding: .utf8)
        } catch {
            print(AppInfo.logPrefix("Failed to write config file: \(error)"))
        }
        fileWatcher.start()
    }

    func persistActiveDeviceTuning() {
        guard let addOnPreset = ensureActiveHiddenAddOnPreset() else { return }
        do {
            try writeHiddenTuningPreset(named: addOnPreset)
        } catch {
            print(AppInfo.logPrefix("Failed to write hidden processing preset \(addOnPreset): \(error)"))
        }
    }

    func writeHiddenTuningPreset(named presetName: String) throws {
        // Our own write must not bounce back through the add-on directory
        // watcher as a reload.
        addOnPresetWatcher?.stop()
        defer { addOnPresetWatcher?.start() }
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
