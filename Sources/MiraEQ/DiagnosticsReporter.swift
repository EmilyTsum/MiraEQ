import AppKit
import Foundation

// MARK: - Diagnostics Reporting
//
// Background health telemetry: the menu-open diagnostics refresh timer, the
// always-on volume/standby poll, and the diagnostics snapshot file. None of
// this touches audio; the snapshot write runs off the main thread.

extension AppDelegate {
    func startDiagnosticsRefreshTimer() {
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

    func stopDiagnosticsRefreshTimer() {
        diagnosticsRefreshTimer?.invalidate()
        diagnosticsRefreshTimer = nil
    }

    func startVolumeRefreshTimer() {
        volumeRefreshGeneration &+= 1
        scheduleVolumeRefreshTick(generation: volumeRefreshGeneration)
        writeDiagnosticsSnapshot()
    }

    func scheduleVolumeRefreshTick(generation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor in
                guard let self, self.volumeRefreshGeneration == generation else { return }
                self.audioEngine.refreshOutputVolumeScalar()
                if !self.isAudioPausedByUser, self.audioEngine.updateAutoStandby() {
                    self.updateIcon()
                    // updateAutoStandby stops the engine without going through
                    // onStateChange, so sync the power assertion here.
                    self.updateRealtimeAudioActivity()
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

    func writeDiagnosticsSnapshot() {
        let diagnostics = audioEngine.diagnostics()
        let silentSeconds = audioEngine.secondsSinceLastAudible()
        let lastPeak = audioEngine.lastAudiblePeak()
        let seamless = audioEngine.seamlessStartActive
        let snapshotPath = routing.store.diagnosticsURL.path

        // Formatter creation is expensive; reuse a shared instance.
        // Called on MainActor, written off-thread to avoid blocking UI.
        let updatedAt = Self.diagnosticsDateFormatter.string(from: Date())
        let lines = [
            "MiraEQ diagnostics",
            "updated: \(updatedAt)",
            "",
            "active: \(diagnostics.isActive ? "true" : "false")",
            "silentSeconds: \(String(format: "%.1f", silentSeconds))",
            "lastAudiblePeak: \(String(format: "%.5f", lastPeak))",
            "startCount: \(diagnostics.startCount)",
            "seamlessStart: \(seamless ? "true" : "false")",
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

        let content = lines.joined(separator: "\n").appending("\n")
        DispatchQueue.global(qos: .utility).async {
            let directory = (snapshotPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
            try? content.write(toFile: snapshotPath, atomically: true, encoding: .utf8)
        }
    }

    private static let diagnosticsDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}
