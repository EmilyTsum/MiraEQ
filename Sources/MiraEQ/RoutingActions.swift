import AppKit
import CoreAudio

/// AppKit bindings only. Configuration decisions live in DeviceRoutingController.
extension AppDelegate {
    func loadConfig() {
        routing.reload()
        applyCurrentRoute()
    }

    func applyCurrentRoute() {
        configurationMonitor.watchPresets(
            devicePreset: routing.activeMapping?.devicePresetFile,
            addOnPreset: routing.activeMapping?.addOnPresetFile
        )
        if !isAudioPausedByUser, let device = routing.device, let config = routing.effectiveConfig {
            audioEngine.applyConfiguration(outputDeviceID: device.id, config: config)
        } else {
            audioEngine.stop()
        }
        updateIcon()
        updateRealtimeAudioActivity()
        writeDiagnosticsSnapshot()
    }

    nonisolated func defaultOutputDeviceDidChange(to deviceID: AudioObjectID, isBuiltInSpeakers: Bool, name: String, uid: String) {
        Task { @MainActor [self] in
            self.deviceChangeDebounceTask?.cancel()
            self.deviceChangeDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                self.routing.selectDevice(deviceID == 0 ? nil : OutputDevice(id: deviceID, name: name, uid: uid))
                self.applyCurrentRoute()
            }
        }
    }

    @objc func selectPresetItem(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? PresetSelection else { return }
        do {
            try routing.selectPreset(selection.presetFile)
            applyCurrentRoute()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func updateDeviceTuning(_ edit: (inout DeviceTuning) -> Void) {
        do {
            try routing.updateTuning(edit)
            applyCurrentRoute()
            updateDiagnosticsMenuItems(diagnostics: audioEngine.diagnostics())
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
