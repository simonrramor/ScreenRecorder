import Foundation
import AVFoundation
import Combine

struct ConnectedDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let platform: DevicePlatform
    var captureDevice: AVCaptureDevice?
    var adbSerial: String?
    var iosUDID: String?

    enum DevicePlatform: String, Codable {
        case iOS = "iOS"
        case android = "Android"

        var iconName: String {
            switch self {
            case .iOS: return "iphone"
            case .android: return "candybarphone"
            }
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ConnectedDevice, rhs: ConnectedDevice) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
class DeviceManager: ObservableObject {
    @Published var devices: [ConnectedDevice] = []
    @Published var adbPath: String?
    @Published var scrcpyPath: String?
    @Published var isInstalling = false
    @Published var statusMessage: String?

    private var deviceObservers: [NSObjectProtocol] = []
    private var scanTimer: Timer?

    var adbAvailable: Bool { adbPath != nil }
    var scrcpyAvailable: Bool { scrcpyPath != nil }
    var iosDevices: [ConnectedDevice] { devices.filter { $0.platform == .iOS } }
    var androidDevices: [ConnectedDevice] { devices.filter { $0.platform == .android } }

    init() {
        findTools()
    }

    func startMonitoring() {
        scanIOSDevices()

        if adbAvailable {
            scanAndroidDevices()
        }

        // Periodic rescan for both iOS and Android devices
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanIOSDevices()
                if self?.adbAvailable == true {
                    self?.scanAndroidDevices()
                }
            }
        }
    }

    func stopMonitoring() {
        deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
        deviceObservers.removeAll()
        scanTimer?.invalidate()
        scanTimer = nil
    }

    func findTools() {
        let adbPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ]
        adbPath = adbPaths.first { FileManager.default.fileExists(atPath: $0) }

        let scrcpyPaths = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy"
        ]
        scrcpyPath = scrcpyPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    func scanIOSDevices() {
        guard FileManager.default.fileExists(atPath: IOSDeviceMirror.ideviceIdPath) else { return }

        let ideviceIdPath = IOSDeviceMirror.ideviceIdPath
        Task.detached {
            let iosDevices = DeviceManager.scanIOSDevicesSync(ideviceIdPath: ideviceIdPath)

            await MainActor.run { [weak self] in
                let android = self?.devices.filter { $0.platform == .android } ?? []
                self?.devices = iosDevices + android
            }
        }
    }

    func refreshIOSDevicesNow() async -> [ConnectedDevice] {
        let ideviceIdPath = IOSDeviceMirror.ideviceIdPath
        guard FileManager.default.fileExists(atPath: ideviceIdPath) else { return [] }

        let iosDevices = await Task.detached {
            DeviceManager.scanIOSDevicesSync(ideviceIdPath: ideviceIdPath)
        }.value

        let android = devices.filter { $0.platform == .android }
        devices = iosDevices + android
        return iosDevices
    }

    func iosConnectionIssueMessage() async -> String {
        let defaultMessage = "iPhone is not visible to macOS. Replug the cable, unlock it, tap Trust, then try again."
        let xcrunPath = "/usr/bin/xcrun"
        guard FileManager.default.fileExists(atPath: xcrunPath) else {
            return defaultMessage
        }

        let output = await Task.detached {
            DeviceManager.runCommand(xcrunPath, arguments: ["devicectl", "list", "devices"])
        }.value

        let hasCoreDeviceIOSDevice = output
            .components(separatedBy: .newlines)
            .contains { line in
                let lowercased = line.lowercased()
                let isIOSDevice = lowercased.contains("iphone") || lowercased.contains("ipad") || lowercased.contains("ipod")
                let isReachable = lowercased.contains("connected") || lowercased.contains("available")
                return isIOSDevice && isReachable
            }

        if hasCoreDeviceIOSDevice {
            return "iPhone is paired in Xcode but not visible over USB. Use a data cable or direct Mac port, unlock it, and tap Trust."
        }

        return defaultMessage
    }

    nonisolated private static func scanIOSDevicesSync(ideviceIdPath: String) -> [ConnectedDevice] {
        guard FileManager.default.fileExists(atPath: ideviceIdPath) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ideviceIdPath)
        process.arguments = ["-l"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var devices: [ConnectedDevice] = []

        for line in output.components(separatedBy: "\n") {
            let udid = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else { continue }

            // Get device name
            let nameProcess = Process()
            nameProcess.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ideviceinfo")
            nameProcess.arguments = ["-u", udid, "-k", "DeviceName"]
            let namePipe = Pipe()
            nameProcess.standardOutput = namePipe
            nameProcess.standardError = Pipe()
            try? nameProcess.run()
            nameProcess.waitUntilExit()

            let name = String(data: namePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "iOS Device"

            devices.append(ConnectedDevice(
                id: udid,
                name: name.isEmpty ? "iOS Device" : name,
                platform: .iOS,
                iosUDID: udid
            ))
        }

        return devices
    }

    func scanAndroidDevices() {
        guard let adbPath = adbPath else { return }

        let path = adbPath
        Task.detached {
            let output = DeviceManager.runCommand(path, arguments: ["devices", "-l"])
            var androidDevices: [ConnectedDevice] = []

            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      !trimmed.starts(with: "List"),
                      !trimmed.starts(with: "*") else { continue }

                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard parts.count >= 2, parts[1] == "device" else { continue }

                let serial = parts[0]
                var name = "Android Device"

                if let modelPart = parts.first(where: { $0.starts(with: "model:") }) {
                    name = String(modelPart.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
                }

                androidDevices.append(ConnectedDevice(
                    id: serial,
                    name: name,
                    platform: .android,
                    adbSerial: serial
                ))
            }

            let scannedAndroidDevices = androidDevices

            await MainActor.run { [weak self] in
                let ios = self?.devices.filter { $0.platform == .iOS } ?? []
                self?.devices = ios + scannedAndroidDevices
            }
        }
    }

    func installAndroidTools() async {
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brewPath = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            statusMessage = "Homebrew is required. Install from https://brew.sh first."
            return
        }

        isInstalling = true
        statusMessage = "Installing scrcpy & ADB via Homebrew... This may take a few minutes."

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brewPath)
                process.arguments = ["install", "scrcpy"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
                continuation.resume()
            }
        }

        findTools()
        isInstalling = false

        if scrcpyAvailable && adbAvailable {
            statusMessage = "Installed successfully! Connect an Android device to get started."
            startMonitoring()
        } else if adbAvailable {
            statusMessage = "ADB installed but scrcpy failed. Try: brew install scrcpy"
        } else {
            statusMessage = "Installation failed. Try running: brew install scrcpy"
        }
    }

    nonisolated static func runCommand(_ path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
