import Foundation
import AppKit

// Persistent frame grabber using pymobiledevice3 streaming script
class IOSFrameGrabber: @unchecked Sendable {
    private let pythonPath: String
    private let scriptPath: String
    private let udid: String
    private let lock = NSLock()
    private var _process: Process?
    private var _isRunning = false

    private var isRunning: Bool {
        get { lock.withLock { _isRunning } }
        set { lock.withLock { _isRunning = newValue } }
    }

    // Delivers raw PNG data; image creation must happen on the main thread
    var onFrameData: ((Data) -> Void)?

    init(pythonPath: String, scriptPath: String, udid: String) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.udid = udid
    }

    func start() {
        isRunning = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.runStreamingProcess()
        }
    }

    func stop() {
        lock.lock()
        _isRunning = false
        let proc = _process
        _process = nil
        lock.unlock()
        proc?.terminate()
    }

    private func runStreamingProcess() {
        while isRunning {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonPath)
            proc.arguments = [scriptPath, udid]

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            do {
                try proc.run()
            } catch {
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            lock.withLock { _process = proc }
            let fileHandle = pipe.fileHandleForReading

            // Read length-prefixed PNG frames: [4 bytes big-endian length][PNG data]
            while isRunning && proc.isRunning {
                guard let lengthData = readExactly(from: fileHandle, count: 4) else { break }

                let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                guard length > 0 && length < 50_000_000 else { break }

                guard let pngData = readExactly(from: fileHandle, count: Int(length)) else { break }

                onFrameData?(pngData)
            }

            proc.terminate()
            proc.waitUntilExit()
            lock.withLock { _process = nil }

            if isRunning {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func readExactly(from handle: FileHandle, count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = handle.readData(ofLength: count - data.count)
            if chunk.isEmpty { return nil }
            data.append(chunk)
        }
        return data
    }
}

@MainActor
class IOSDeviceMirror: ObservableObject {
    @Published var isMirroring = false
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var deviceResolution: CGSize = .zero
    @Published var mirroringDeviceName: String = ""
    @Published var currentFrame: NSImage?

    private var frameGrabber: IOSFrameGrabber?
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var mirroringDeviceUDID: String?

    // Paths
    static let pythonPath = "\(NSHomeDirectory())/.pymobiledevice3-venv/bin/python3.13"
    static let pymobiledevicePath = "\(NSHomeDirectory())/.pymobiledevice3-venv/bin/pymobiledevice3"
    static let ideviceIdPath = "/opt/homebrew/bin/idevice_id"

    // Path to streaming script (bundled in app or in source tree)
    static var streamScriptPath: String {
        if let bundled = Bundle.main.path(forResource: "ios_stream", ofType: "py") {
            return bundled
        }
        return "\(NSHomeDirectory())/ScreenRecorder/Resources/ios_stream.py"
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: pythonPath) &&
        FileManager.default.fileExists(atPath: ideviceIdPath)
    }

    func startMirroring(udid: String, deviceName: String) {
        guard !isMirroring else { return }
        errorMessage = nil
        mirroringDeviceName = deviceName
        mirroringDeviceUDID = udid

        // Ensure tunneld is running (needed for iOS 17+)
        ensureTunneld()

        let grabber = IOSFrameGrabber(pythonPath: Self.pythonPath, scriptPath: Self.streamScriptPath, udid: udid)
        grabber.onFrameData = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self = self, self.isMirroring else { return }
                if let image = NSImage(data: data) {
                    self.currentFrame = image
                    if self.deviceResolution == .zero {
                        self.deviceResolution = image.size
                    }
                }
            }
        }
        grabber.start()
        frameGrabber = grabber
        isMirroring = true
    }

    func stopMirroring() {
        frameGrabber?.stop()
        frameGrabber = nil

        if isRecording {
            isRecording = false
            stopDurationTimer()
        }

        isMirroring = false
        currentFrame = nil
        mirroringDeviceName = ""
        mirroringDeviceUDID = nil
        deviceResolution = .zero
    }

    func takeScreenshot() -> NSImage? {
        return currentFrame
    }

    func startRecording() {
        guard isMirroring, !isRecording else { return }
        errorMessage = "iOS device recording is not supported yet. Use screenshots to capture individual frames."
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        stopDurationTimer()
        return nil
    }

    // MARK: - Tunneld Management

    private func ensureTunneld() {
        // Check if tunneld is already running
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkProcess.arguments = ["-f", "pymobiledevice3 remote tunneld"]
        let pipe = Pipe()
        checkProcess.standardOutput = pipe
        checkProcess.standardError = Pipe()
        try? checkProcess.run()
        checkProcess.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return // tunneld already running
        }

        // Start tunneld via osascript with admin privileges
        let script = "do shell script \"\(Self.pymobiledevicePath.replacingOccurrences(of: "\"", with: "\\\"")) remote tunneld -d\" with administrator privileges"
        let osaProcess = Process()
        osaProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osaProcess.arguments = ["-e", script]
        osaProcess.standardOutput = Pipe()
        osaProcess.standardError = Pipe()
        try? osaProcess.run()
        osaProcess.waitUntilExit()

        // Give tunneld a moment to start
        Thread.sleep(forTimeInterval: 2.0)
    }

    // MARK: - Device Discovery

    static func listDevices() -> [(udid: String, name: String)] {
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
        var devices: [(udid: String, name: String)] = []

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

            devices.append((udid: udid, name: name.isEmpty ? "iOS Device" : name))
        }

        return devices
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingDuration = 0
        recordingStartDate = nil
    }
}
