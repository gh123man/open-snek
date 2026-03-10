import XCTest
import OpenSnekCore

final class IssueReportFormatterTests: XCTestCase {
    func testIssueReportFormatterIncludesDeviceSummariesAndDumps() {
        let payload = IssueReportFormatter.format(
            appVersion: "1.2.3",
            build: "45",
            logLevel: "Info",
            logPath: "/tmp/open-snek.log",
            selectedDevice: "Basilisk V3 35K [USB]",
            warning: "Telemetry delayed",
            error: nil,
            generatedAt: Date(timeIntervalSince1970: 0),
            devices: [
                IssueReportDeviceEntry(
                    title: "Basilisk V3 35K [USB]",
                    summary: "Basilisk V3 35K (USB, 0x1532:0x00CB, profile basilisk_v3_35k)",
                    diagnostics: "Open Snek Device Diagnostics\nGenerated: 1970-01-01T00:00:00.000Z"
                )
            ]
        )

        XCTAssertTrue(payload.contains("## Open Snek Diagnostics"))
        XCTAssertTrue(payload.contains("- App version: 1.2.3"))
        XCTAssertTrue(payload.contains("- Selected device: Basilisk V3 35K [USB]"))
        XCTAssertTrue(payload.contains("### Connected Devices"))
        XCTAssertTrue(payload.contains("- Basilisk V3 35K (USB, 0x1532:0x00CB, profile basilisk_v3_35k)"))
        XCTAssertTrue(payload.contains("### Device Dump: Basilisk V3 35K [USB]"))
        XCTAssertTrue(payload.contains("```text"))
    }

    func testIssueReportFormatterHandlesNoConnectedDevices() {
        let payload = IssueReportFormatter.format(
            appVersion: "1.2.3",
            build: "45",
            logLevel: "Warning",
            logPath: "/tmp/open-snek.log",
            selectedDevice: nil,
            warning: nil,
            error: "No supported device found",
            generatedAt: Date(timeIntervalSince1970: 0),
            devices: []
        )

        XCTAssertTrue(payload.contains("- Selected device: None"))
        XCTAssertTrue(payload.contains("- Current error: No supported device found"))
        XCTAssertTrue(payload.contains("_No devices were connected when this payload was generated._"))
    }
}
