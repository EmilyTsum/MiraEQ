import AppKit
import Foundation
import CoreAudio
import ServiceManagement

// MARK: - Status Menu
//
// Menu-bar presentation only: menu construction, diagnostics rows, preset /
// processing submenus, and menu actions. Behavior is unchanged from the
// former monolithic MiraEQ.swift; the code was moved verbatim into this
// extension, except that pausing now also releases the power assertion
// (see updateRealtimeAudioActivity).

extension AppDelegate {
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

    // Internal because DiagnosticsReporter drives it from the refresh timer.
    func updateDiagnosticsMenuItems(diagnostics: AudioEngineDiagnostics) {
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
            updateRealtimeAudioActivity()
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
