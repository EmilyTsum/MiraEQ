import AppKit
import Foundation
import CoreAudio
import Darwin

// MARK: - Menu Selection Payloads
//
// Small value types carried in NSMenuItem.representedObject so menu actions
// can stay decoupled from menu construction (see StatusMenu.swift).

struct PresetSelection {
    let presetFile: String?
}

struct BassFocusSelection {
    let amountPercent: Float
    let shouldReset: Bool
}

enum ProcessingTuningComponent {
    case latency
    case bassHarmonics
    case lowEndGuard
    case reset
}

struct ProcessingTuningSelection {
    let component: ProcessingTuningComponent
    let latencyMode: LatencyMode?
    let amountPercent: Float
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, DeviceMonitorDelegate {
    var statusItem: NSStatusItem!
    let audioEngine = AudioEngineManager()
    let deviceMonitor = DeviceMonitor()
    let routing = DeviceRoutingController()
    lazy var configurationMonitor = ConfigurationMonitor(store: routing.store) { [weak self] in
        self?.loadConfig()
    }

    var activeDeviceName: String { routing.device?.name ?? "Unknown" }
    var activeDeviceID: AudioObjectID { routing.device?.id ?? 0 }
    var activeDevicePresetName: String? { routing.activeMapping?.devicePresetFile }
    var currentEffects: EffectConfig { routing.effectiveConfig?.effects ?? EffectConfig() }

    var isAudioPausedByUser = false
    var diagnosticsRefreshTimer: Timer?
    var diagnosticsSnapshotTick = 0
    var volumeRefreshGeneration: UInt64 = 0
    var deviceChangeDebounceTask: Task<Void, Never>?
    let silenceStandbyDefaultsKey = "SilenceStandbyEnabled"
    private var latencyCriticalActivity: NSObjectProtocol?
    private var cachedStatusIcon: NSImage?
    weak var diagnosticsMenu: NSMenu?
    var engineDiagnosticItem: NSMenuItem?
    var latencyDiagnosticItem: NSMenuItem?
    var bufferDiagnosticItem: NSMenuItem?
    var glitchesDiagnosticItem: NSMenuItem?
    var renderDiagnosticItem: NSMenuItem?
    var hardwareBufferDiagnosticItem: NSMenuItem?
    var formatDiagnosticItem: NSMenuItem?
    var bassFocusDiagnosticItem: NSMenuItem?
    var lowEndGuardDiagnosticItem: NSMenuItem?
    var finalSafetyDiagnosticItem: NSMenuItem?
    var uptimeDiagnosticItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory so the app does not show in the dock
        NSApp.setActivationPolicy(.accessory)
        boostProcessPriority()
        do {
            try routing.store.prepareSupportFiles()
        } catch {
            print(AppInfo.logPrefix("Could not prepare configuration files: \(error)"))
        }

        // Set up Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        if UserDefaults.standard.object(forKey: silenceStandbyDefaultsKey) != nil {
            audioEngine.silenceStandbyEnabled = UserDefaults.standard.bool(forKey: silenceStandbyDefaultsKey)
        }

        configurationMonitor.start()
        loadConfig()
        startVolumeRefreshTimer()

        audioEngine.onStateChange = { [weak self] in
            guard let self else { return }
            if !self.audioEngine.isActive && !self.audioEngine.isInStandby {
                print(AppInfo.logPrefix("Audio engine is not active for \(self.activeDeviceName)"))
            }
            self.updateIcon()
            self.updateRealtimeAudioActivity()
            self.writeDiagnosticsSnapshot()
        }
        // The engine may already be active if routing started synchronously.
        updateRealtimeAudioActivity()

        // Initialize Device Monitor
        deviceMonitor.delegate = self
        deviceMonitor.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        deviceChangeDebounceTask?.cancel()
        configurationMonitor.stop()
        diagnosticsRefreshTimer?.invalidate()
        volumeRefreshGeneration &+= 1
        deviceMonitor.stopMonitoring()
        audioEngine.stop()
        endRealtimeAudioActivity()
    }

    /// Holds the latency-critical power assertion only while the engine is
    /// actually processing. Previously it was held for the whole app lifetime,
    /// which needlessly blocked idle sleep during bypass/standby pauses that
    /// can last for hours on a long-running install.
    func updateRealtimeAudioActivity() {
        if audioEngine.isActive {
            startRealtimeAudioActivity()
        } else {
            endRealtimeAudioActivity()
        }
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

    func updateIcon() {
        if let button = statusItem.button {
            button.title = ""
            // The symbol image never changes; build it once instead of on
            // every state refresh (which happens at least twice a second).
            if cachedStatusIcon == nil {
                if let image = NSImage(systemSymbolName: AppInfo.statusIconSymbolName, accessibilityDescription: AppInfo.displayName) {
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    cachedStatusIcon = image.withSymbolConfiguration(config)
                    cachedStatusIcon?.isTemplate = true
                }
            }
            button.image = cachedStatusIcon
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
