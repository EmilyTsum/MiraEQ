import Foundation

/// Coalesces config, preset catalog, and active-preset changes into one reload.
/// Watching active files as well as directories catches in-place editor saves.
@MainActor
final class ConfigurationMonitor {
    private let store: ConfigurationStore
    private let onChange: @MainActor () -> Void
    private var watchers: [FileWatcher] = []
    private var presetWatchers: [FileWatcher] = []
    private var activePresetURLs: [URL] = []
    private var reloadTask: Task<Void, Never>?
    private var isRunning = false

    init(store: ConfigurationStore, onChange: @escaping @MainActor () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    func start() {
        stop()
        isRunning = true
        watchers = [store.routingURL, store.devicePresetDirectory, store.addOnPresetDirectory].map(makeWatcher)
        watchers.forEach { $0.start() }
        presetWatchers.forEach { $0.start() }
    }

    func stop() {
        isRunning = false
        reloadTask?.cancel()
        reloadTask = nil
        (watchers + presetWatchers).forEach { $0.stop() }
        watchers = []
    }

    func watchPresets(devicePreset: String?, addOnPreset: String?) {
        let urls = [
            devicePreset.map { store.devicePresetDirectory.appendingPathComponent($0) },
            addOnPreset.map { store.addOnPresetDirectory.appendingPathComponent($0) }
        ].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard urls != activePresetURLs else { return }
        presetWatchers.forEach { $0.stop() }
        activePresetURLs = urls
        presetWatchers = urls.map(makeWatcher)
        if isRunning { presetWatchers.forEach { $0.start() } }
    }

    private func makeWatcher(_ url: URL) -> FileWatcher {
        FileWatcher(url: url) { [weak self] in self?.scheduleReload() }
    }

    private func scheduleReload() {
        guard isRunning else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.onChange()
        }
    }

    deinit { reloadTask?.cancel() }
}
