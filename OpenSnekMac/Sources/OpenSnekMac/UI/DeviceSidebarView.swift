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
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0xA8F46A))
                    Text("OpenSnek")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
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

                Text("Devices")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .textCase(.uppercase)

                List(selection: $appState.selectedDeviceID) {
                    ForEach(appState.devices) { device in
                        DeviceRow(device: device)
                            .tag(device.id)
                            .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .padding(12)
        }
    }
}

struct DeviceRow: View {
    let device: MouseDevice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
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
        .padding(.vertical, 2)
    }
}
