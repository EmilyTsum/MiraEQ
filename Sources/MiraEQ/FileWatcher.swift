import Foundation

@MainActor
public class FileWatcher {
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let path: String
    private let watchesDirectory: Bool
    private let onChange: @MainActor () -> Void

    public init(path: String, watchesDirectory: Bool = false, onChange: @escaping @MainActor () -> Void) {
        self.path = (path as NSString).expandingTildeInPath
        self.watchesDirectory = watchesDirectory
        self.onChange = onChange
    }

    public func start() {
        stop()

        let fm = FileManager.default

        if watchesDirectory {
            if !fm.fileExists(atPath: path) {
                try? fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            } else {
                // A regular file may exist where we expect a directory
                // (legacy bug created a file at the directory path).
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    try? fm.removeItem(atPath: path)
                    try? fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
                }
            }
        } else {
            let dir = (path as NSString).deletingLastPathComponent

            // Ensure directory and file exist
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
            }
            if !fm.fileExists(atPath: path) {
                let template = """
                # \(AppInfo.displayName) Device Routing Configuration
                # Format: DeviceNameOrUIDPattern = DevicePresetFile | HiddenProcessingPresetFile
                # Use None as the device preset to bypass processing for that device.
                # Example:
                # MacBook Air Speakers = MacBook_Air_13_Balanced.txt | .MiraEQ_MacBook_Air_Speakers_Processing.txt
                """
                fm.createFile(atPath: path, contents: template.data(using: .utf8), attributes: nil)
            }
        }

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            print("Error: FileWatcher failed to open file at path: \(path)")
            return
        }
        fileDescriptor = descriptor

        // Run the source on the main queue to align with MainActor isolation
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )

        newSource.setEventHandler { [weak self] in
            guard let self = self, self.fileDescriptor == descriptor, let source = self.source else { return }
            let flags = source.data
            
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.start()
                    self.onChange()
                }
                return
            }
            
            self.onChange()
        }

        newSource.setCancelHandler { [weak self] in
            close(descriptor)
            guard let self = self else { return }
            if self.fileDescriptor == descriptor {
                self.fileDescriptor = -1
            }
        }

        self.source = newSource
        newSource.resume()
    }

    public func stop() {
        // The file descriptor is closed in the source's cancel handler.
        // Do not reset fileDescriptor here: the pending cancel handler
        // needs the old value to avoid clearing a newer descriptor
        // installed by a subsequent start().
        source?.cancel()
        source = nil
    }
}
