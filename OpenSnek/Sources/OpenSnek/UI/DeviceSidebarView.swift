import SwiftUI
import OpenSnekCore

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
                    Text("Open Snek")
                        .font(.system(size: 19, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Button {
                            Task { await appState.refreshDevices() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.bordered)
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
    private let transportPillWidth: CGFloat = 46

    var body: some View {
        let backgroundFill = isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.04)
        let borderStroke = isSelected ? Color.white.opacity(0.30) : Color.white.opacity(0.10)

        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(device.product_name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transportPill
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(borderStroke, lineWidth: 1)
                )
        )
    }

    private var transportPill: some View {
        Text(device.transport.shortLabel)
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(device.transport == .bluetooth ? Color(hex: 0x7DE4FF) : Color(hex: 0xB8FF73))
            .frame(width: transportPillWidth)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.30))
                    .overlay(
                        Capsule()
                            .stroke((device.transport == .bluetooth ? Color(hex: 0x66D9FF) : Color(hex: 0x9BEA5D)).opacity(0.70), lineWidth: 1)
                    )
            )
    }
}
