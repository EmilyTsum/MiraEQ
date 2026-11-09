import Foundation

/// Disk access and first-install setup. No menu, engine, or watcher behavior.
struct ConfigurationStore {
    let directory: URL
    var routingURL: URL { directory.appendingPathComponent("config.txt") }
    var presetDirectory: URL { directory.appendingPathComponent("presets", isDirectory: true) }
    var devicePresetDirectory: URL { presetDirectory.appendingPathComponent("device", isDirectory: true) }
    var addOnPresetDirectory: URL { presetDirectory.appendingPathComponent("addons", isDirectory: true) }
    var diagnosticsURL: URL { directory.appendingPathComponent("diagnostics.txt") }

    init(directory: URL = URL(fileURLWithPath: (AppInfo.configDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)) {
        self.directory = directory
    }

    func prepareSupportFiles(bundledPresetRoots: [URL]? = nil) throws {
        let fm = FileManager.default
        for directory in [devicePresetDirectory, addOnPresetDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Keep the old flat preset layout readable without moving user files.
        try installPresets(from: presetDirectory, to: devicePresetDirectory)
        let roots = bundledPresetRoots ?? [
            Bundle.main.resourceURL,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
            URL(fileURLWithPath: fm.currentDirectoryPath)
        ].compactMap { $0 }.map { $0.appendingPathComponent("presets", isDirectory: true) }
        for root in roots {
            try installPresets(from: root.appendingPathComponent("device"), to: devicePresetDirectory)
            try installPresets(from: root.appendingPathComponent("addons"), to: addOnPresetDirectory)
        }
        if !fm.fileExists(atPath: routingURL.path) { try writeRouting([]) }
    }

    private func installPresets(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        for url in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey])
        where url.pathExtension.lowercased() == "txt" && url.lastPathComponent.lowercased() != "config.txt" {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let target = destination.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
        }
    }

    func loadRouting() throws -> [DeviceMapping] {
        ConfigParser.parseRouting(content: try String(contentsOf: routingURL, encoding: .utf8))
    }

    func writeRouting(_ mappings: [DeviceMapping]) throws {
        try ConfigParser.writeRouting(mappings: mappings).write(to: routingURL, atomically: true, encoding: .utf8)
    }

    func loadDevicePreset(named name: String) throws -> EQConfig {
        let result = ConfigParser.parse(content: try devicePresetContent(named: name))
        logWarnings(result.warnings, preset: name)
        return result.config
    }

    func loadTuning(named name: String?) throws -> DeviceTuning {
        guard let name else { return DeviceTuning() }
        let url = addOnPresetDirectory.appendingPathComponent(name)
        // A route may reference a hidden file before any setting has been
        // changed. Absence means inherit; unreadable existing files are errors.
        guard FileManager.default.fileExists(atPath: url.path) else { return DeviceTuning() }
        let result = ConfigParser.parseTuning(content: try tuningContent(named: name))
        logWarnings(result.warnings, preset: name)
        return result.tuning
    }

    func writeTuning(_ tuning: DeviceTuning, named name: String) throws {
        try tuning.presetContent.write(to: addOnPresetDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func devicePresetContent(named name: String) throws -> String {
        try String(contentsOf: devicePresetDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    func tuningContent(named name: String) throws -> String {
        try String(contentsOf: addOnPresetDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    func availableDevicePresets() -> [(file: String, title: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: devicePresetDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "txt" && $0.lastPathComponent.lowercased() != "config.txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, presetTitle(at: $0)) }
    }

    private func presetTitle(at url: URL) -> String {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let prefix = "# MiraEQ Preset:"
                if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                    let title = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { return title }
                }
            }
        }
        return url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func logWarnings(_ warnings: [String], preset: String) {
        for warning in warnings { print(AppInfo.logPrefix("Preset \(preset) warning: \(warning)")) }
    }
}
