import Foundation

/// Central lookup for the external command-line tools Captr shells out to.
/// Homebrew installs under /opt/homebrew on Apple Silicon and /usr/local on
/// Intel, so every tool is probed in both prefixes instead of hardcoding one.
enum ToolLocator {
    private static let brewPrefixes = ["/opt/homebrew", "/usr/local"]

    static func find(_ tool: String, extraPaths: [String] = []) -> String? {
        let candidates = brewPrefixes.map { "\($0)/bin/\(tool)" } + extraPaths
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static var adb: String? {
        find("adb", extraPaths: ["\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"])
    }

    static var scrcpy: String? { find("scrcpy") }
    static var brew: String? { find("brew") }
    static var ideviceId: String? { find("idevice_id") }
    static var ideviceInfo: String? { find("ideviceinfo") }

    private static let pymobiledeviceVenvBin = "\(NSHomeDirectory())/.pymobiledevice3-venv/bin"

    /// Python interpreter inside the pymobiledevice3 venv. Prefers the
    /// version-independent `python3` symlink so a venv rebuilt with a newer
    /// Python keeps working, falling back to any `python3.x` binary present.
    static var pymobiledevicePython: String? {
        let symlink = "\(pymobiledeviceVenvBin)/python3"
        if FileManager.default.fileExists(atPath: symlink) { return symlink }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: pymobiledeviceVenvBin) else {
            return nil
        }
        return entries
            .filter { $0.hasPrefix("python3") }
            .sorted()
            .last
            .map { "\(pymobiledeviceVenvBin)/\($0)" }
    }

    static var pymobiledevice3: String? {
        let path = "\(pymobiledeviceVenvBin)/pymobiledevice3"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
