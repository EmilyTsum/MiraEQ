import Foundation

enum AppInfo {
    static let displayName = "MiraEQ"
    static let configDirectoryName = "MiraEQ"
    static let logSubsystem = "com.noxlume03.miraeq"
    static let tapName = "MiraEQ-Tap"
    static let aggregateDeviceName = "MiraEQ-Aggregate"
    static let statusIconSymbolName = "waveform.path"

    static var configDirectoryPath: String {
        "~/.config/\(configDirectoryName)"
    }

    static func logPrefix(_ message: String) -> String {
        "\(displayName): \(message)"
    }
}
