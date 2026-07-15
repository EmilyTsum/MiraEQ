import Foundation

enum AppInfo {
    static let displayName = "MiraEq"
    static let configDirectoryName = "MiraEq"
    static let logSubsystem = "com.noxlume03.miraeq"
    static let tapName = "MiraEq-Tap"
    static let aggregateDeviceName = "MiraEq-Aggregate"
    static let statusIconSymbolName = "waveform.path"

    static var configPath: String {
        "~/.config/\(configDirectoryName)/config.txt"
    }

    static var configDirectoryPath: String {
        "~/.config/\(configDirectoryName)"
    }

    static var presetDirectoryPath: String {
        "\(configDirectoryPath)/presets"
    }

    static var devicePresetDirectoryPath: String {
        "\(presetDirectoryPath)/device"
    }

    static var addOnPresetDirectoryPath: String {
        "\(presetDirectoryPath)/addons"
    }

    static func logPrefix(_ message: String) -> String {
        "\(displayName): \(message)"
    }
}
