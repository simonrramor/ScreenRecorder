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

    enum DevicePlatform: String, Codable, Sendable {
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

private struct ScannedDevice: Sendable {
    let id: String
    let name: String
    let platform: ConnectedDevice.DevicePlatform
}

@MainActor
class DeviceManager: ObservableObject {
    private enum CommandTimeout {
        static let deviceScan: TimeInterval = 3
        static let deviceDiagnostics: TimeInterval = 5
        static let toolInstallation: TimeInterval = 300
    }

    @Published var devices: [ConnectedDevice] = []
    @Published var adbPath: String?
    @Published var isInstalling = false
    @Published var statusMessage: String?

    private var monitorTask: Task<Void, Never>?
    private var iosScanTask: Task<Void, Never>?
    private var androidScanTask: Task<Void, Never>?

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
        guard monitorTask == nil else { return }

        scanIOSDevices()
        if adbAvailable {
            scanAndroidDevices()
        }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }

                guard let self else { break }
                self.scanIOSDevices()
                if self.adbAvailable {
                    self.scanAndroidDevices()
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        iosScanTask?.cancel()
        iosScanTask = nil
        androidScanTask?.cancel()
        androidScanTask = nil
    }

    func findTools() {
        adbPath = ToolLocator.adb
    }

    func scanIOSDevices() {
        guard iosScanTask == nil,
              let ideviceIdPath = ToolLocator.ideviceId else { return }

        let ideviceInfoPath = ToolLocator.ideviceInfo
        let knownNames = iosDeviceNameCache
        iosScanTask = Task { [weak self] in
            let result = await Self.performIOSScan(
                ideviceIdPath: ideviceIdPath,
                ideviceInfoPath: ideviceInfoPath,
                knownNames: knownNames
            )

            guard let self else { return }
            defer { self.iosScanTask = nil }
            guard !Task.isCancelled else { return }
            self.applyIOSScanResult(result)
        }
    }

    func refreshIOSDevicesNow() async -> [ConnectedDevice] {
        scanIOSDevices()
        if let task = iosScanTask {
            await task.value
        }
        return iosDevices
    }

    private func applyIOSScanResult(_ scannedDevices: [ScannedDevice]) {
        let iosDevices = scannedDevices.map { scanned -> ConnectedDevice in
            iosDeviceNameCache[scanned.id] = scanned.name
            return ConnectedDevice(
                id: scanned.id,
                name: scanned.name,
                platform: .iOS,
                iosUDID: scanned.id
            )
        }
        let android = devices.filter { $0.platform == .android }
        devices = iosDevices + android
    }

    func iosConnectionIssueMessage() async -> String {
        let defaultMessage = "iPhone is not visible to macOS. Replug the cable, unlock it, tap Trust, then try again."
        let xcrunPath = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrunPath) else {
            return defaultMessage
        }

        guard let result = try? await ProcessRunner.run(
            xcrunPath,
            arguments: ["devicectl", "list", "devices"],
            timeout: CommandTimeout.deviceDiagnostics
        ) else {
            return defaultMessage
        }

        let hasCoreDeviceIOSDevice = result.standardOutput
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

    @concurrent
    private static func performIOSScan(
        ideviceIdPath: String,
        ideviceInfoPath: String?,
        knownNames: [String: String]
    ) async -> [ScannedDevice] {
        guard let result = try? await ProcessRunner.run(
            ideviceIdPath,
            arguments: ["-l"],
            timeout: CommandTimeout.deviceScan
        ), result.succeeded else {
            return []
        }

        var devices: [ScannedDevice] = []
        for line in result.standardOutput.components(separatedBy: .newlines) {
            guard !Task.isCancelled else { return [] }
            let udid = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else { continue }

            let name: String
            if let cached = knownNames[udid] {
                name = cached
            } else if let ideviceInfoPath,
                      let nameResult = try? await ProcessRunner.run(
                        ideviceInfoPath,
                        arguments: ["-u", udid, "-k", "DeviceName"],
                        timeout: CommandTimeout.deviceScan
                      ), nameResult.succeeded {
                let rawName = nameResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                name = rawName.isEmpty ? "iOS Device" : rawName
            } else {
                name = "iOS Device"
            }

            devices.append(ScannedDevice(id: udid, name: name, platform: .iOS))
        }
        return devices
    }

    func scanAndroidDevices() {
        guard androidScanTask == nil,
              let adbPath else { return }

        androidScanTask = Task { [weak self] in
            let result = await Self.performAndroidScan(adbPath: adbPath)
            guard let self else { return }
            defer { self.androidScanTask = nil }
            guard !Task.isCancelled else { return }

            let androidDevices = result.map {
                ConnectedDevice(
                    id: $0.id,
                    name: $0.name,
                    platform: .android,
                    adbSerial: $0.id
                )
            }
            let ios = self.devices.filter { $0.platform == .iOS }
            self.devices = ios + androidDevices
        }
    }

    func refreshAndroidDevicesNow() async -> [ConnectedDevice] {
        scanAndroidDevices()
        if let task = androidScanTask {
            await task.value
        }
        return androidDevices
    }

    @concurrent
    private static func performAndroidScan(adbPath: String) async -> [ScannedDevice] {
        guard let result = try? await ProcessRunner.run(
            adbPath,
            arguments: ["devices", "-l"],
            timeout: CommandTimeout.deviceScan
        ), result.succeeded else {
            return []
        }

        return result.standardOutput.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.starts(with: "List"),
                  !trimmed.starts(with: "*") else { return nil }

            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2, parts[1] == "device" else { return nil }

            let serial = parts[0]
            let name: String
            if let modelPart = parts.first(where: { $0.starts(with: "model:") }) {
                name = String(modelPart.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
            } else {
                name = "Android Device"
            }
            return ScannedDevice(id: serial, name: name, platform: .android)
        }
    }

    func installAndroidTools() async {
        guard !isInstalling else { return }
        guard let brewPath = ToolLocator.brew else {
            statusMessage = "Homebrew is required. Install from https://brew.sh first."
            return
        }

        isInstalling = true
        statusMessage = "Installing ADB via Homebrew... This may take a few minutes."
        defer { isInstalling = false }

        do {
            let result = try await ProcessRunner.run(
                brewPath,
                arguments: ["install", "android-platform-tools"],
                timeout: CommandTimeout.toolInstallation
            )
            findTools()

            if result.succeeded, adbAvailable {
                statusMessage = "Installed successfully! Connect an Android device to get started."
                startMonitoring()
                scanAndroidDevices()
            } else {
                let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                statusMessage = detail.isEmpty
                    ? "Installation failed. Try running: brew install android-platform-tools"
                    : "Installation failed: \(detail)"
            }
        } catch {
            statusMessage = "Installation failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func runCommand(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval = CommandTimeout.deviceScan
    ) -> String {
        guard let result = ProcessRunner.runSynchronously(path, arguments: arguments, timeout: timeout),
              result.succeeded else {
            return ""
        }
        return result.standardOutput
    }
}
