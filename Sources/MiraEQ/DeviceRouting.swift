import CoreAudio
import Foundation

struct OutputDevice: Equatable {
    let id: AudioObjectID
    let name: String
    let uid: String

    var routingKey: String { uid.isEmpty ? name : uid }

    func matches(_ mapping: DeviceMapping) -> Bool {
        let pattern = Self.normalized(mapping.pattern)
        return !pattern.isEmpty && [name, uid].map(Self.normalized).contains(pattern)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var hiddenTuningPresetName: String {
        let sanitized = routingKey.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let base = String(sanitized).split(separator: "_").joined(separator: "_")
        return ".MiraEQ_\(base.isEmpty ? "Device" : String(base.prefix(80)))_Processing.txt"
    }
}

/// Owns the selected route and its sparse overrides. State changes only after
/// reads/writes succeed, so the menu and engine consume the same configuration.
@MainActor
final class DeviceRoutingController {
    let store: ConfigurationStore
    private(set) var device: OutputDevice?
    private(set) var mappings: [DeviceMapping] = []
    private(set) var activeMapping: DeviceMapping?
    private(set) var baseConfig: EQConfig?
    private(set) var tuning = DeviceTuning()
    private(set) var lastError: Error?

    var effectiveConfig: EQConfig? { baseConfig.map { SpeakerEngineProfile.prepare(tuning.applying(to: $0)) } }

    init(store: ConfigurationStore = ConfigurationStore()) {
        self.store = store
    }

    func reload() {
        do {
            let updated = try store.loadRouting()
            let route = try resolve(mappings: updated)
            mappings = updated
            apply(route)
            lastError = nil
        } catch {
            // An editor can briefly remove a file during a save. Preserve the
            // last complete configuration until the replacement is readable.
            lastError = error
            print(AppInfo.logPrefix("Could not reload configuration; keeping the previous route: \(error)"))
        }
    }

    func selectDevice(_ device: OutputDevice?) {
        self.device = device
        activeMapping = nil
        baseConfig = nil
        tuning = DeviceTuning()
        do {
            apply(try resolve(mappings: mappings))
            lastError = nil
        } catch {
            // Never carry the previous device's EQ across a failed switch.
            activeMapping = device.flatMap { device in mappings.first(where: device.matches) }
            lastError = error
            print(AppInfo.logPrefix("Could not load device configuration: \(error)"))
        }
    }

    func selectPreset(_ preset: String?) throws {
        guard let device else { return }
        var updated = mappings.filter { !device.matches($0) }
        let mapping = DeviceMapping(
            pattern: device.routingKey,
            devicePresetFile: preset,
            addOnPresetFile: activeMapping?.addOnPresetFile ?? device.hiddenTuningPresetName
        )
        // Keep an explicit bypass rule and the tuning reference, so choosing
        // None and then re-enabling a device preserves its settings.
        updated.insert(mapping, at: 0)
        let route = try resolve(mappings: updated)
        try store.writeRouting(updated)
        mappings = updated
        apply(route)
        lastError = nil
    }

    func updateTuning(_ edit: (inout DeviceTuning) -> Void) throws {
        guard let device, baseConfig != nil,
              let index = mappings.firstIndex(where: device.matches) else { return }
        var updatedTuning = tuning
        edit(&updatedTuning)
        let name = mappings[index].addOnPresetFile ?? device.hiddenTuningPresetName
        var updatedMappings = mappings
        updatedMappings[index].addOnPresetFile = name
        // Write settings before publishing a routing reference to them.
        try store.writeTuning(updatedTuning, named: name)
        if updatedMappings != mappings { try store.writeRouting(updatedMappings) }
        mappings = updatedMappings
        activeMapping = updatedMappings[index]
        tuning = updatedTuning
        lastError = nil
    }

    private typealias Route = (mapping: DeviceMapping?, base: EQConfig?, tuning: DeviceTuning)

    private func resolve(mappings: [DeviceMapping]) throws -> Route {
        guard let device, let mapping = mappings.first(where: device.matches) else {
            return (nil, nil, DeviceTuning())
        }
        guard let preset = mapping.devicePresetFile else { return (mapping, nil, DeviceTuning()) }
        return (mapping, try store.loadDevicePreset(named: preset), try store.loadTuning(named: mapping.addOnPresetFile))
    }

    private func apply(_ route: Route) {
        activeMapping = route.mapping
        baseConfig = route.base
        tuning = route.tuning
    }
}
