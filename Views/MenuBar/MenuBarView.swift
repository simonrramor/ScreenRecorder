import SwiftUI
import ScreenCaptureKit
import Sparkle

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.captureEngine.state.isActive {
                recordingActiveSection
            } else {
                recordingSection
            }
            // Screenshots and text capture keep working during a recording —
            // SCScreenshotManager captures are independent of the stream.
            Divider().padding(.vertical, 4)
            screenshotSection
            Divider().padding(.vertical, 4)
            textCaptureSection

            Divider().padding(.vertical, 4)
            deviceSection
            Divider().padding(.vertical, 4)
            settingsSection
            Divider().padding(.vertical, 4)
            bottomSection
        }
        .padding(8)
        .frame(width: 260)
    }

    // MARK: - Recording Active

    private var recordingActiveSection: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)

                Text("Recording")
                    .font(.headline)

                Spacer()

                Text(DurationFormatter.format(appState.captureEngine.recordingDuration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await appState.stopRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    Task { await appState.cancelRecording() }
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(4)
    }

    // MARK: - Recording Options

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Record")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            MenuBarButton(icon: "rectangle.inset.filled", title: "Full Screen") {
                Task { await appState.startRecording(mode: .fullScreen) }
            }

            MenuBarButton(icon: "macwindow", title: "Window") {
                Task { await appState.startRecording(mode: .window) }
            }

            MenuBarButton(icon: "rectangle.dashed", title: "Selected Area") {
                Task { await appState.startRecording(mode: .area) }
            }
        }
    }

    // MARK: - Screenshot Options

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Screenshot")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            MenuBarButton(icon: "camera.fill", title: "Full Screen") {
                Task { await appState.takeFullScreenScreenshot() }
            }

            MenuBarButton(icon: "macwindow", title: "Window") {
                Task { await appState.takeScreenshot(mode: .window) }
            }

            MenuBarButton(icon: "rectangle.dashed", title: "Selected Area") {
                Task { await appState.takeScreenshot(mode: .area) }
            }
        }
    }

    // MARK: - Text Capture

    private var textCaptureSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Text Capture")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            MenuBarButton(icon: "text.viewfinder", title: "Capture Text from Area") {
                Task { await appState.startTextCapture() }
            }

            MenuBarButton(icon: "character.book.closed", title: "Translate Text to English") {
                Task { await appState.startTranslateCapture() }
            }
        }
    }

    // MARK: - Device Mirror

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Device Mirror")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            if appState.deviceManager.devices.isEmpty {
                HStack {
                    Image(systemName: "iphone.slash")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text("No devices connected")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                ForEach(appState.deviceManager.devices) { device in
                    MenuBarButton(icon: device.platform.iconName, title: device.name) {
                        Task {
                            await appState.startDeviceMirroring(device: device)
                        }
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }

            if appState.iosDeviceMirror.isMirroring || appState.androidDeviceMirror?.isMirroring == true {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Mirror active")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Quick Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { appState.configuration.captureSystemAudio },
                set: { appState.configuration.captureSystemAudio = $0 }
            )) {
                Label("System Audio", systemImage: "speaker.wave.2")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 4)

            Toggle(isOn: Binding(
                get: { appState.configuration.captureMicrophone },
                set: { appState.configuration.captureMicrophone = $0 }
            )) {
                Label("Microphone", systemImage: "mic")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 4)

            Toggle(isOn: Binding(
                get: { appState.configuration.showCursor },
                set: { appState.configuration.showCursor = $0 }
            )) {
                Label("Show Cursor", systemImage: "cursorarrow")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 6) {
                Label("iOS Mirror Mode", systemImage: "iphone")
                    .font(.system(size: 13))
                    .padding(.horizontal, 4)

                Picker(selection: Binding(
                    get: { appState.useFastIOSMirroring },
                    set: { appState.setFastIOSMirroring($0) }
                )) {
                    Text("Stable").tag(false)
                    Text("Fast").tag(true)
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: 4) {
            MenuBarButton(icon: "folder", title: "Open Recordings Folder") {
                NSWorkspace.shared.open(MediaLibraryManager.recordingsDirectory)
            }

            MenuBarButton(icon: "photo.on.rectangle", title: "Open Screenshots Folder") {
                NSWorkspace.shared.open(MediaLibraryManager.screenshotsDirectory)
            }

            Button {
                checkForUpdatesViewModel.checkForUpdates()
            } label: {
                HStack(spacing: 8) {
                    if checkForUpdatesViewModel.canCheckForUpdates {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 16)
                            .foregroundColor(.secondary)
                        Text("Check for Updates…")
                            .font(.system(size: 13))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16)
                        Text("Checking for updates…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .cornerRadius(4)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)

            MenuBarButton(icon: "power", title: "Quit") {
                NSApp.terminate(nil)
            }
        }
    }
}

struct MenuBarButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .cornerRadius(4)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
