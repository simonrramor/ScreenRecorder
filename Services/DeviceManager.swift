import Foundation
import AVFoundation
import Combine
import Darwin

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
    private enum CommandTimeout {
        static let deviceScan: TimeInterval = 3
        static let deviceDiagnostics: TimeInterval = 5
        static let terminationGrace: TimeInterval = 0.5
    }

    @Published var devices: [ConnectedDevice] = []
    @Published var adbPath: String?
    @Published var isInstalling = false
    @Published var statusMessage: String?

    private var deviceObservers: [NSObjectProtocol] = []
    private var scanTimer: Timer?

    /// Device names cost one `ideviceinfo` launch each, so remember them per
    /// UDID and only query devices we haven't seen before.
    private var iosDeviceNameCache: [String: String] = [:]

    var adbAvailable: Bool { adbPath != nil }
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
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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
        adbPath = ToolLocator.adb
    }

    func scanIOSDevices() {
        guard let ideviceIdPath = ToolLocator.ideviceId else { return }

        let ideviceInfoPath = ToolLocator.ideviceInfo
        let knownNames = iosDeviceNameCache
        Task.detached {
            let iosDevices = DeviceManager.scanIOSDevicesSync(
                ideviceIdPath: ideviceIdPath,
                ideviceInfoPath: ideviceInfoPath,
                knownNames: knownNames
            )

            await MainActor.run { [weak self] in
                self?.applyIOSScanResult(iosDevices)
            }
        }
    }

    func refreshIOSDevicesNow() async -> [ConnectedDevice] {
        guard let ideviceIdPath = ToolLocator.ideviceId else { return [] }

        let ideviceInfoPath = ToolLocator.ideviceInfo
        let knownNames = iosDeviceNameCache
        let iosDevices = await Task.detached {
            DeviceManager.scanIOSDevicesSync(
                ideviceIdPath: ideviceIdPath,
                ideviceInfoPath: ideviceInfoPath,
                knownNames: knownNames
            )
        }.value

        applyIOSScanResult(iosDevices)
        return iosDevices
    }

    private func applyIOSScanResult(_ iosDevices: [ConnectedDevice]) {
        for device in iosDevices {
            iosDeviceNameCache[device.id] = device.name
        }
        let android = devices.filter { $0.platform == .android }
        devices = iosDevices + android
    }

    func iosConnectionIssueMessage() async -> String {
        let defaultMessage = "iPhone is not visible to macOS. Replug the cable, unlock it, tap Trust, then try again."
        let xcrunPath = "/usr/bin/xcrun"
        guard FileManager.default.fileExists(atPath: xcrunPath) else {
            return defaultMessage
        }

        let output = await Task.detached {
            DeviceManager.runCommand(
                xcrunPath,
                arguments: ["devicectl", "list", "devices"],
                timeout: CommandTimeout.deviceDiagnostics
            )
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

    nonisolated private static func scanIOSDevicesSync(
        ideviceIdPath: String,
        ideviceInfoPath: String?,
        knownNames: [String: String]
    ) -> [ConnectedDevice] {
        let output = runCommand(ideviceIdPath, arguments: ["-l"], timeout: CommandTimeout.deviceScan)
        var devices: [ConnectedDevice] = []

        for line in output.components(separatedBy: "\n") {
            let udid = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else { continue }

            let name: String
            if let cached = knownNames[udid] {
                name = cached
            } else if let ideviceInfoPath {
                let raw = runCommand(
                    ideviceInfoPath,
                    arguments: ["-u", udid, "-k", "DeviceName"],
                    timeout: CommandTimeout.deviceScan
                )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                name = raw.isEmpty ? "iOS Device" : raw
            } else {
                name = "iOS Device"
            }

            devices.append(ConnectedDevice(
                id: udid,
                name: name,
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
            let output = DeviceManager.runCommand(
                path,
                arguments: ["devices", "-l"],
                timeout: CommandTimeout.deviceScan
            )
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
        guard let brewPath = ToolLocator.brew else {
            statusMessage = "Homebrew is required. Install from https://brew.sh first."
            return
        }

        isInstalling = true
        statusMessage = "Installing ADB via Homebrew... This may take a few minutes."

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brewPath)
                process.arguments = ["install", "android-platform-tools"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
                continuation.resume()
            }
        }

        findTools()
        isInstalling = false

        if adbAvailable {
            statusMessage = "Installed successfully! Connect an Android device to get started."
            startMonitoring()
        } else {
            statusMessage = "Installation failed. Try running: brew install android-platform-tools"
        }
    }

    nonisolated static func runCommand(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval = CommandTimeout.deviceScan
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return ""
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()

            if finished.wait(timeout: .now() + CommandTimeout.terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + CommandTimeout.terminationGrace)
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
