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

enum SpatialTuningComponent {
    case listenerDistance
    case strength
    case reset
}

struct SpatialTuningSelection {
    let component: SpatialTuningComponent
    let value: Float
}

struct BassFocusSelection {
    let amountPercent: Float
    let shouldReset: Bool
}

enum ProcessingTuningComponent {
    case latency
    case spatialEnabled
    case bassHarmonics
    case lowEndGuard
    case bassCompAmount
    case softLimitDrive
    case reset
}

struct ProcessingTuningSelection {
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
    var devicePresetWatcher: FileWatcher?
    var addOnPresetWatcher: FileWatcher?
    var presetReloadDebounceTask: Task<Void, Never>?

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
    var isAudioPausedByUser = false
    var lastConfigLoadError: Error? = nil
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
    var effectDelayDiagnosticItem: NSMenuItem?
    var spatialDiagnosticItem: NSMenuItem?
    var bassFocusDiagnosticItem: NSMenuItem?
    var lowEndGuardDiagnosticItem: NSMenuItem?
    var finalSafetyDiagnosticItem: NSMenuItem?
    var uptimeDiagnosticItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory so the app does not show in the dock
        NSApp.setActivationPolicy(.accessory)
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

        // Watch the preset directories too, so editing a preset file directly
        // (atomic saves show up as directory entry changes) hot-reloads the
        // active configuration just like editing config.txt does.
        devicePresetWatcher = FileWatcher(path: expandedDevicePresetDirectoryPath, watchesDirectory: true) { [weak self] in
            self?.schedulePresetReload()
        }
        devicePresetWatcher?.start()
        addOnPresetWatcher = FileWatcher(path: expandedAddOnPresetDirectoryPath, watchesDirectory: true) { [weak self] in
            self?.schedulePresetReload()
        }
        addOnPresetWatcher?.start()

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
            self.updateRealtimeAudioActivity()
        }
        // The engine may already be active if routing started synchronously.
        updateRealtimeAudioActivity()

        // Initialize Device Monitor
        deviceMonitor.delegate = self
        deviceMonitor.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        deviceChangeDebounceTask?.cancel()
        presetReloadDebounceTask?.cancel()
        devicePresetWatcher?.stop()
        addOnPresetWatcher?.stop()
        diagnosticsRefreshTimer?.invalidate()
        volumeRefreshGeneration &+= 1
        deviceMonitor.stopMonitoring()
        fileWatcher.stop()
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
