import AppKit
import Foundation
import CoreAudio
import ServiceManagement

// Menu construction and AppKit actions. Values reflect the effective route.

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

        if let error = routing.lastError {
            menu.addItem(disabledMenuItem(title: "Config: \(error.localizedDescription)"))
        }
        addDiagnosticsItems(to: menu, diagnostics: diagnostics)

        menu.addItem(.separator())

        if audioEngine.isInStandby {
            let wakeItem = NSMenuItem(title: "Wake from Standby", action: #selector(wakeFromStandby), keyEquivalent: "")
            wakeItem.target = self
            menu.addItem(wakeItem)
        }

        let restartItem = NSMenuItem(title: "Restart Audio Processing", action: #selector(restartAudioProcessing), keyEquivalent: "")
        restartItem.target = self
        restartItem.isEnabled = routing.effectiveConfig != nil && !isAudioPausedByUser
        menu.addItem(restartItem)

        let pauseTitle = isAudioPausedByUser ? "Resume Audio Processing" : "Pause Audio Processing"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(toggleAudioProcessingPaused), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isEnabled = routing.effectiveConfig != nil || isAudioPausedByUser
        menu.addItem(pauseItem)

        // Mute / zero volume always stops capture; this only controls the
        // silence-based trigger.
        let standbyToggle = NSMenuItem(
            title: "Auto-Standby After Playback Stops (2 min)",
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
        presetItem.submenu = makePresetMenu(activePreset: activeDevicePresetName)
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
        finalSafetyDiagnosticItem?.title = "Final Safety: Peak Limiter"

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

    private func makePresetMenu(activePreset: String?) -> NSMenu {
        let presetMenu = NSMenu()

        let bypassItem = NSMenuItem(title: "None (Bypass This Device)", action: #selector(selectPresetItem(_:)), keyEquivalent: "")
        bypassItem.target = self
        bypassItem.representedObject = PresetSelection(presetFile: nil)
        bypassItem.state = (activePreset == nil) ? .on : .off
        presetMenu.addItem(bypassItem)
        presetMenu.addItem(.separator())

        for preset in routing.store.availableDevicePresets() {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPresetItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = PresetSelection(presetFile: preset.file)
            item.state = activePreset == preset.file ? .on : .off
            presetMenu.addItem(item)
        }
        return presetMenu
    }

    private func makeProcessingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledMenuItem(title: "Saved for: \(activeDeviceName)"))
        menu.addItem(.separator())

        let latencyItem = NSMenuItem(title: "Latency", action: nil, keyEquivalent: "")
        latencyItem.submenu = makeLatencyMenu()
        menu.addItem(latencyItem)

        let harmonicsItem = NSMenuItem(title: "Bass Harmonics", action: nil, keyEquivalent: "")
        harmonicsItem.submenu = makeBassHarmonicsMenu()
        menu.addItem(harmonicsItem)

        let bassFocusItem = NSMenuItem(title: "Bass Focus", action: nil, keyEquivalent: "")
        bassFocusItem.submenu = makeBassFocusMenu()
        menu.addItem(bassFocusItem)

        let lowGuardItem = NSMenuItem(title: "Low Guard", action: nil, keyEquivalent: "")
        lowGuardItem.submenu = makeLowEndGuardMenu()
        menu.addItem(lowGuardItem)

        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset Processing to Preset", action: #selector(selectProcessingTuningItem(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.representedObject = ProcessingTuningSelection(component: .reset, latencyMode: nil, amountPercent: 0)
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



    private func addProcessingItem(
        to menu: NSMenu,
        title: String,
        component: ProcessingTuningComponent,
        latencyMode: LatencyMode? = nil,
        amountPercent: Float = 0
    ) {
        let item = NSMenuItem(title: title, action: #selector(selectProcessingTuningItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ProcessingTuningSelection(
            component: component,
            latencyMode: latencyMode,
            amountPercent: amountPercent
        )

        switch component {
        case .latency:
            item.state = latencyMode.map { abs(currentEffects.latency.targetMs - $0.targetMs) < 0.01 } == true ? .on : .off
        case .bassHarmonics:
            item.state = abs(currentEffects.bassHarmonics.amount - amountPercent) < 0.5 ? .on : .off
        case .lowEndGuard:
            item.state = abs(currentEffects.lowEndGuard.amountPercent - amountPercent) < 0.5 ? .on : .off
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





    private func makeBassFocusMenu() -> NSMenu {
        let menu = NSMenu()
        let summary = disabledMenuItem(title: String(format: "Amount: %.0f%%", currentEffects.bassFocus.amountPercent))
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
            item.state = abs(currentEffects.bassFocus.amountPercent - option.1) < 0.5 ? .on : .off
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



    @objc func selectProcessingTuningItem(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ProcessingTuningSelection else { return }
        updateDeviceTuning { tuning in
            switch selection.component {
            case .latency: tuning.latencyTargetMs = selection.latencyMode?.targetMs
            case .bassHarmonics: tuning.bassHarmonicsAmount = selection.amountPercent
            case .lowEndGuard: tuning.lowEndGuardAmount = selection.amountPercent
            case .reset: tuning = DeviceTuning()
            }
        }
    }

    @objc func selectBassFocusItem(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? BassFocusSelection else { return }
        updateDeviceTuning { tuning in
            tuning.bassFocusAmount = selection.shouldReset ? nil : selection.amountPercent
        }
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
        NSWorkspace.shared.open(routing.store.routingURL)
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
        guard routing.effectiveConfig != nil, !isAudioPausedByUser else { return }
        audioEngine.stop()
        applyCurrentRoute()
    }

    @objc func toggleAudioProcessingPaused() {
        if isAudioPausedByUser {
            isAudioPausedByUser = false
            print(AppInfo.logPrefix("Resuming audio processing"))
            applyCurrentRoute()
        } else {
            isAudioPausedByUser = true
            print(AppInfo.logPrefix("Pausing audio processing"))
            audioEngine.stop()
            updateIcon()
            updateRealtimeAudioActivity()
            writeDiagnosticsSnapshot()
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
