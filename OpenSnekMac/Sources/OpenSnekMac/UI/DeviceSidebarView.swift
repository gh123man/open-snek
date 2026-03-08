import SwiftUI
import AppKit

struct DeviceSidebarView: View {
    @Bindable var appState: AppState

    var body: some View {
        ZStack {
            AngularGradient(
                gradient: Gradient(colors: [Color(hex: 0x102532), Color(hex: 0x223319), Color(hex: 0x332114), Color(hex: 0x102532)]),
                center: .topLeading
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: 0xA8F46A))
                        Text("Open Snek")
                            .font(.system(size: 19, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Button {
                            Task { await appState.refreshDevices() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: 0x9BEA5D))
                        .controlSize(.small)

                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: AppLog.path))
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open runtime log file")
                    }
                }

                Text("Devices")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .textCase(.uppercase)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        if appState.devices.isEmpty {
                            Text("No supported device found")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }

                        ForEach(appState.devices) { device in
                            Button {
                                appState.selectedDeviceID = device.id
                            } label: {
                                DeviceRow(
                                    device: device,
                                    isSelected: appState.selectedDeviceID == device.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
        }
    }
}

struct DeviceRow: View {
    let device: MouseDevice
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.product_name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(device.connectionLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Text(device.transport == "bluetooth" ? "BT" : "USB")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(Color(hex: 0x101010))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(device.transport == "bluetooth" ? Color(hex: 0x66D9FF) : Color(hex: 0x9BEA5D), in: Capsule())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.white.opacity(0.30) : Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }
}
