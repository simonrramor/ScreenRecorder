import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            screenshotBar
                .padding(8)
                .fixedSize()
                .background(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
                .cornerRadius(12)
                .preferredColorScheme(.dark)

            if appState.showNotification {
                VStack {
                    Spacer()
                    NotificationBanner(message: appState.notificationMessage, isError: appState.notificationIsError)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.3), value: appState.showNotification)
            }
        }
    }

    private var screenshotBar: some View {
        HStack(spacing: 12) {
            // Capture type toggle
            HStack(spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isVideoMode = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11))
                        Text("Screenshot")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(!appState.isVideoMode ? .white : .secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(!appState.isVideoMode ? Color(nsColor: NSColor(white: 0.30, alpha: 1.0)) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isVideoMode = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 11))
                        Text("Record")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(appState.isVideoMode ? .white : .secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(appState.isVideoMode ? Color(nsColor: NSColor(white: 0.30, alpha: 1.0)) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: NSColor(white: 0.16, alpha: 1.0)))
            )

            // Mode picker
            HStack(spacing: 2) {
                ForEach([CaptureMode.fullScreen, .window, .area], id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            appState.screenshotMode = mode
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 11))
                            Text(mode.rawValue)
                                .font(.system(size: 12))
                        }
                        .foregroundColor(appState.screenshotMode == mode ? .white : .secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(appState.screenshotMode == mode ? Color(nsColor: NSColor(white: 0.30, alpha: 1.0)) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: NSColor(white: 0.16, alpha: 1.0)))
            )

            // Capture / Record button
            if appState.isVideoMode {
                if appState.captureEngine.state.isActive {
                    Button {
                        Task { await appState.stopRecording() }
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white)
                                .frame(width: 10, height: 10)
                            Text("Stop \(formatDuration(appState.captureEngine.recordingDuration))")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await appState.startRecording(mode: appState.screenshotMode) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Text("Start Recording")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                        )
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    Task { await appState.captureScreenshot() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11))
                        Text("Take Screenshot")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
            }

            iosMirrorModeControl

            HStack(spacing: 6) {
                Button {
                    Task { await appState.startFirstAvailableIOSMirroring() }
                } label: {
                    HStack(spacing: 6) {
                        if appState.isStartingIOSMirror {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "iphone")
                                .font(.system(size: 11))
                        }
                        Text(appState.isStartingIOSMirror ? "Connecting…" : "iOS")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: NSColor(white: 0.20, alpha: 1.0)))
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.isStartingIOSMirror)
                .help("Live stream a connected iPhone or iPad")

                Button {
                    Task { await appState.startFirstAvailableAndroidMirroring() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "candybarphone")
                            .font(.system(size: 11))
                        Text("Android")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: NSColor(white: 0.20, alpha: 1.0)))
                    )
                }
                .buttonStyle(.plain)
                .help("Live stream a connected Android device")
            }

            // Settings gear
            Button {
                appState.showSettingsPopover = true
            } label: {
                Image("SettingsIcon")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $appState.showSettingsPopover) {
                SettingsPopup()
                    .environmentObject(appState)
            }

            // Grab handle
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color(nsColor: NSColor(white: 0.35, alpha: 1.0)))
                        .frame(width: 4, height: 1)
                }
            }
            .frame(width: 12, height: 16)
            .padding(.leading, 4)
        }
    }

    private var iosMirrorModeControl: some View {
        HStack(spacing: 2) {
            iosMirrorModeButton(
                title: "Stable",
                isSelected: !appState.useFastIOSMirroring,
                help: "Use stable iOS mirroring. Slower, but avoids the macOS native capture crash."
            ) {
                appState.setFastIOSMirroring(false)
            }

            iosMirrorModeButton(
                title: "Fast",
                isSelected: appState.useFastIOSMirroring,
                isEnabled: appState.canUseFastIOSMirroring,
                help: appState.canUseFastIOSMirroring
                    ? "Use fast iOS mirroring. Lower latency, but may be less stable on some macOS/iPhone states."
                    : "Fast iOS mirroring is disabled in this build because macOS native iPhone capture is crashing."
            ) {
                appState.setFastIOSMirroring(true)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: NSColor(white: 0.16, alpha: 1.0)))
        )
        .help("iOS mirror mode")
    }

    private func iosMirrorModeButton(
        title: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                action()
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 50)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color(nsColor: NSColor(white: 0.30, alpha: 1.0)) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .help(help)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Settings Popup

struct SettingsPopup: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                Section("Recording") {
                    Toggle(isOn: Binding(
                        get: { appState.configuration.captureSystemAudio },
                        set: { appState.configuration.captureSystemAudio = $0 }
                    )) {
                        Label("System Audio", systemImage: "speaker.wave.2")
                    }

                    Toggle(isOn: Binding(
                        get: { appState.configuration.captureMicrophone },
                        set: { appState.configuration.captureMicrophone = $0 }
                    )) {
                        Label("Microphone", systemImage: "mic")
                    }

                    Toggle(isOn: Binding(
                        get: { appState.configuration.showCursor },
                        set: { appState.configuration.showCursor = $0 }
                    )) {
                        Label("Show Cursor", systemImage: "cursorarrow")
                    }

                    Picker(selection: Binding(
                        get: { appState.configuration.frameRate },
                        set: { appState.configuration.frameRate = $0 }
                    )) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    } label: {
                        Label("Frame Rate", systemImage: "speedometer")
                    }
                }

                Section("Device Mirroring") {
                    if appState.canUseFastIOSMirroring {
                        Picker(selection: Binding(
                            get: { appState.useFastIOSMirroring },
                            set: { appState.setFastIOSMirroring($0) }
                        )) {
                            Text("Stable").tag(false)
                            Text("Fast").tag(true)
                        } label: {
                            Label("iOS Mirror Mode", systemImage: "iphone")
                        }
                        .pickerStyle(.segmented)
                    } else {
                        HStack {
                            Label("iOS Mirror Mode", systemImage: "iphone")
                            Spacer()
                            Text("Stable")
                                .font(.caption.weight(.semibold))
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.14))
                                )
                        }
                    }

                    Text(appState.canUseFastIOSMirroring
                        ? (appState.useFastIOSMirroring
                            ? "Lower latency using macOS native iPhone capture. Switch off if it crashes after wake or disconnect."
                            : "Stable mode avoids the macOS iPhone capture crash, but updates more slowly.")
                        : "Fast mode is disabled in this build because macOS native iPhone capture is crashing. Stable mode is still available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Shortcuts") {
                    ForEach(ShortcutAction.allCases) { action in
                        ShortcutRow(
                            action: action,
                            shortcutSettings: appState.shortcutSettings
                        )
                    }
                }

                Section("Translation") {
                    TranslationSettingsSection(settings: appState.translationSettings)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 380, height: 560)
    }
}

// MARK: - Translation Settings

struct TranslationSettingsSection: View {
    @ObservedObject var settings: TranslationSettings
    @State private var apiKeyDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(selection: $settings.engine) {
                ForEach(TranslationEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            } label: {
                Label("Engine", systemImage: "character.bubble")
            }

            Text(settings.engine.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.engine == .claude {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Label("Anthropic API Key", systemImage: "key.fill")
                        .font(.system(size: 12))

                    // Saved on submit/close rather than per keystroke so we
                    // don't hit the Keychain for every character typed.
                    SecureField("sk-ant-...", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { settings.setClaudeAPIKey(apiKeyDraft) }

                    HStack(spacing: 4) {
                        Image(systemName: settings.hasClaudeAPIKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(settings.hasClaudeAPIKey ? .green : .orange)
                        Text(settings.hasClaudeAPIKey ? "Key saved to Keychain" : "Key required for Claude engine")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                            .font(.system(size: 11))
                    }
                }

                Picker(selection: $settings.claudeModel) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text("\(model.displayName) — \(model.costHint)").tag(model)
                    }
                } label: {
                    Label("Model", systemImage: "cpu")
                }
            }
        }
        .onAppear {
            apiKeyDraft = settings.claudeAPIKey ?? ""
        }
        .onDisappear {
            settings.setClaudeAPIKey(apiKeyDraft)
        }
    }
}

// MARK: - Shortcut Row

struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var shortcutSettings: ShortcutSettings
    @EnvironmentObject var appState: AppState
    @State private var isRecording = false
    @State private var conflictMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(action.rawValue, systemImage: action.iconName)
                .font(.system(size: 12))

            ShortcutRecorderButton(
                combo: shortcutSettings.binding(for: action),
                isRecording: $isRecording,
                onRecord: { combo in
                    if let existing = shortcutSettings.conflictingAction(for: combo, excluding: action) {
                        shortcutSettings.setBinding(.empty, for: existing)
                        conflictMessage = "Removed from \(existing.rawValue)"
                        dismissConflictMessage()
                    }
                    shortcutSettings.setBinding(combo, for: action)
                    appState.isRecordingShortcut = false
                    appState.reregisterShortcuts()
                },
                onClear: {
                    shortcutSettings.setBinding(.empty, for: action)
                    appState.reregisterShortcuts()
                },
                onStartRecording: {
                    appState.isRecordingShortcut = true
                    appState.unregisterShortcutsTemporarily()
                },
                onStopRecording: {
                    appState.isRecordingShortcut = false
                    appState.reregisterShortcuts()
                }
            )

            if let message = conflictMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.2), value: conflictMessage)
    }

    private func dismissConflictMessage() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { conflictMessage = nil }
        }
    }
}

struct ShortcutRecorderButton: View {
    let combo: KeyCombo
    @Binding var isRecording: Bool
    let onRecord: (KeyCombo) -> Void
    let onClear: () -> Void
    var onStartRecording: () -> Void = {}
    var onStopRecording: () -> Void = {}

    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isRecording {
                    stopListening()
                } else {
                    startListening()
                }
            } label: {
                HStack(spacing: 4) {
                    if isRecording {
                        Text("Press shortcut...")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    } else {
                        Text(combo.displayString)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(combo.isEmpty ? .secondary : .primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isRecording ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if !combo.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear {
            stopListening()
        }
    }

    private func startListening() {
        isRecording = true
        onStartRecording()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 {
                stopListening()
                return nil
            }

            guard !modifiers.isEmpty else { return nil }

            let combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers.rawValue)
            onRecord(combo)
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
        onStopRecording()
    }
}

// MARK: - Pulse Animation

struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.4 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Notification Banner

struct NotificationBanner: View {
    let message: String
    var isError: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .orange : .green)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 400)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 10)
    }
}
