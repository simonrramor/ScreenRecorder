import SwiftUI

struct DeviceMirrorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.deviceManager.devices.isEmpty {
                deviceListView
            } else {
                emptyDevicesView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isDeviceMirroring(_ device: ConnectedDevice) -> Bool {
        if device.platform == .iOS && appState.iosDeviceMirror.isMirroring {
            return true
        }
        if device.platform == .android, let mirror = appState.androidDeviceMirror, mirror.isMirroring {
            return true
        }
        return false
    }

    private func disconnectDevice(_ device: ConnectedDevice) {
        if device.platform == .iOS {
            appState.iosDeviceMirror.stopMirroring()
            appState.iosMirrorWindow.closeWindow()
        } else if device.platform == .android {
            appState.androidDeviceMirror?.stopMirroring()
            appState.androidMirrorWindow.closeWindow()
        }
    }

    private func openMirrorWindow(for device: ConnectedDevice) {
        if device.platform == .iOS {
            appState.iosMirrorWindow.openIOSMirrorWindow(mirror: appState.iosDeviceMirror, deviceName: device.name, appState: appState)
        } else if device.platform == .android, let mirror = appState.androidDeviceMirror {
            appState.androidMirrorWindow.openAndroidMirrorWindow(mirror: mirror, appState: appState)
        }
    }

    // MARK: - Empty State

    private var emptyDevicesView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 56, weight: .thin))
                .foregroundColor(.secondary)

            Text("Connect a Device")
                .font(.title2.weight(.medium))

            VStack(alignment: .leading, spacing: 16) {
                instructionRow(
                    icon: "iphone",
                    title: "iOS Device",
                    steps: [
                        "Connect your iPhone or iPad via USB cable",
                        "Tap \"Trust This Computer\" on your device",
                        "The device will appear here automatically"
                    ]
                )

                Divider()

                instructionRow(
                    icon: "candybarphone",
                    title: "Android Device",
                    steps: [
                        "Enable USB Debugging in Developer Options",
                        "Connect your device via USB cable",
                        "Allow USB Debugging when prompted on device"
                    ]
                )

                if !appState.deviceManager.adbAvailable {
                    Divider()
                    androidToolsSetup
                }
            }
            .frame(maxWidth: 500)
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )

            Spacer()
        }
        .padding()
    }

    private func instructionRow(icon: String, title: String, steps: [String]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.accentColor)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)

                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(step)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var androidToolsSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundColor(.orange)
                Text("Android Tools Required")
                    .font(.subheadline.weight(.medium))
            }

            Text("ADB is needed for Android mirroring. Install it via Homebrew.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let message = appState.deviceManager.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            Button {
                Task { await appState.deviceManager.installAndroidTools() }
            } label: {
                HStack {
                    if appState.deviceManager.isInstalling {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    Text(appState.deviceManager.isInstalling ? "Installing..." : "Install via Homebrew")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(appState.deviceManager.isInstalling)
        }
    }

    // MARK: - Device List

    private var deviceListView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Connected Devices")
                    .font(.title2.weight(.medium))
                    .padding(.top, 24)

                LazyVGrid(columns: [
                    GridItem(.fixed(280), spacing: 16),
                    GridItem(.fixed(280), spacing: 16)
                ], spacing: 16) {
                    ForEach(appState.deviceManager.devices) { device in
                        DeviceCard(
                            device: device,
                            isMirroring: isDeviceMirroring(device),
                            onMirror: {
                                Task { await appState.startDeviceMirroring(device: device) }
                            },
                            onMirrorRecord: {
                                Task { await appState.startDeviceMirroringWithRecording(device: device) }
                            },
                            onScreenshot: {
                                Task { await appState.takeDeviceScreenshot(device: device) }
                            },
                            onViewMirror: {
                                openMirrorWindow(for: device)
                            },
                            onDisconnect: {
                                disconnectDevice(device)
                            }
                        )
                    }
                }

                if !appState.deviceManager.adbAvailable && !appState.deviceManager.androidDevices.isEmpty {
                    androidToolsSetup
                        .padding()
                }
            }
            .padding()
        }
    }

}

// MARK: - Device Card

struct DeviceCard: View {
    let device: ConnectedDevice
    let isMirroring: Bool
    let onMirror: () -> Void
    let onMirrorRecord: () -> Void
    let onScreenshot: () -> Void
    let onViewMirror: () -> Void
    let onDisconnect: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: device.platform.iconName)
                    .font(.system(size: 28))
                    .foregroundColor(device.platform == .iOS ? .blue : .green)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(device.platform == .iOS ? Color.blue.opacity(0.1) : Color.green.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    Text(device.platform.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let serial = device.adbSerial {
                        Text(serial)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isMirroring {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .modifier(PulseAnimation())
                        Text("Mirroring")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.green)
                    }
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                }
            }

            Divider()

            if isMirroring {
                HStack(spacing: 8) {
                    Button(action: onViewMirror) {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.inset.filled")
                                .font(.system(size: 10))
                            Text("View Mirror")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDisconnect) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                            Text("Disconnect")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 8) {
                    Button(action: onMirror) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Mirror")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: onMirrorRecord) {
                        HStack(spacing: 4) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 10))
                            Text("Record")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: onScreenshot) {
                        Image(systemName: "camera")
                            .font(.system(size: 11))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.gray.opacity(0.15))
                            .foregroundColor(.primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isMirroring ? Color.accentColor.opacity(0.06) : (isHovering ? Color.gray.opacity(0.08) : Color.gray.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isMirroring ? Color.accentColor.opacity(0.4) : (isHovering ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15)), lineWidth: 1.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
