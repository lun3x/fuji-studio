import Foundation
import Testing
@testable import FujiStudio

/// Phase A safety tests only: these do not claim conversion or seven-bank support.
struct XT5ConversionTests {
    @Test func readOnlyProbeNeverUploadsReadsProfileBaselineOrWritesSettings() async throws {
        let wire = ProbeWire()
        let report = try await XT5ProtocolProbe(transport: wire).readEvidence()
        #expect(report.model == "X-T5")
        #expect(report.firmware == "4.20")
        #expect(report.usbMode == 6)
        #expect(report.conversionValidated == false)
        let commands = await wire.commands
        #expect(commands.map(\.opcode) == [0x1001,0x1014,0x1015,0x1014,0x1014,0x1014])
        #expect(commands.filter { $0.opcode == 0x1015 }.map(\.parameters) == [[0xD16E]])
        #expect(commands.map(\.transactionID) == [1,2,3,4,5,6])
        #expect(await wire.outboundPayloadCount == 0)
    }
    @Test func sanitizedEvidenceContainsNoSerialNamesOrOpaqueProfileBytes() async throws {
        let report = try await XT5ProtocolProbe(transport: ProbeWire()).readEvidence()
        let json = String(decoding: try report.json(), as: UTF8.self)
        #expect(!json.contains("PRIVATE-SERIAL"))
        #expect(!json.contains("PRIVATE-BANK"))
        #expect(!json.contains("PRIVATE-PROFILE"))
        #expect(json.contains("4.20"))
        #expect(report.properties.first { $0.code == "0xD18D" }?.current == nil)
    }
    @Test func unsupportedBodyMakesNoVendorReads() async throws {
        let wire = ProbeWire(model: "X100VI")
        await #expect(throws: XT5ProtocolError.unsupportedCamera) { try await XT5ProtocolProbe(transport: wire).readEvidence() }
        #expect(await wire.commands.count == 1)
    }
    @Test func unadvertisedPropertiesAreNeverRequested() async throws {
        let wire = ProbeWire(properties: [])
        let report = try await XT5ProtocolProbe(transport: wire).readEvidence()
        #expect(report.usbMode == nil)
        #expect(report.properties.isEmpty)
        #expect(await wire.commands.count == 1)
    }
    @Test func rejectedDescriptorIsReportedWithoutAssumingAType() async throws {
        let wire = ProbeWire(rejectMode: true)
        let report = try await XT5ProtocolProbe(transport: wire).readEvidence()
        #expect(report.usbMode == nil)
        #expect(report.properties.first?.outcome == "PTP response 0x200A")
        #expect(await wire.commands.filter { $0.opcode == 0x1015 }.isEmpty)
    }
    @Test func sessionFailureStopsProbeWithoutRetryOrConversion() async throws {
        let wire = ProbeWire(failSession: true)
        await #expect(throws: PTPError.notConnected) { try await XT5ProtocolProbe(transport: wire).readEvidence() }
        #expect(await wire.commands.count == 2)
    }
    @Test func repeatedProbeUsesFreshLogicalTransactions() async throws {
        let wire = ProbeWire(properties: [])
        let probe = XT5ProtocolProbe(transport: wire)
        _ = try await probe.readEvidence(); _ = try await probe.readEvidence()
        #expect(await wire.commands.map(\.transactionID) == [1,2])
    }
}

private actor ProbeWire: PTPTransport {
    var commands: [PTPCommand] = []
    var outboundPayloadCount = 0
    let model: String
    let properties: [UInt16]
    let rejectMode: Bool
    let failSession: Bool
    init(model: String = "X-T5", properties: [UInt16] = [0xD16E,0xD185,0xD18C,0xD18D], rejectMode: Bool = false, failSession: Bool = false) {
        self.model = model; self.properties = properties; self.rejectMode = rejectMode; self.failSession = failSession
    }
    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
        commands.append(command)
        if data != nil { outboundPayloadCount += 1 }
        let payload: Data
        switch (command.opcode, command.parameters) {
        case (0x1001, []): payload = ProtocolProbeFixtures.deviceInfo(model: model, properties: properties)
        case (0x1014, [0xD16E]):
            if failSession { throw PTPError.notConnected }
            if rejectMode { throw PTPError.responseCode(0x200A) }
            payload = ProtocolProbeFixtures.modeDescriptor
        case (0x1015, [0xD16E]): payload = Data([6,0])
        case (0x1014, [0xD18C]): payload = ProtocolProbeFixtures.selectorDescriptor
        case (0x1014, [0xD18D]):
            payload = Data([0x8d,0xd1,0xff,0xff,1]) + ProtocolProbeFixtures.string("PRIVATE-BANK") + ProtocolProbeFixtures.string("PRIVATE-BANK") + Data([0])
        case (0x1014, [0xD185]):
            payload = Data([0x85,0xd1,0xff,0xff,1]) + ProtocolProbeFixtures.string("PRIVATE-PROFILE") + ProtocolProbeFixtures.string("PRIVATE-PROFILE") + Data([0])
        default: throw PTPError.invalidParameters
        }
        return PTPReply(opcode: command.opcode, parameters: [], logicalTransactionID: command.transactionID,
                        wireTransactionID: command.transactionID + 8, correlation: .imageCaptureCoreCallback(echoedCommand: command),
                        responseCode: 0x2001, rawResponse: Data([12,0,0,0,3,0,1,32,9,0,0,0]), data: payload)
    }
}

@MainActor struct XT5ProbeLaunchTests {
    @Test func ordinaryLaunchDoesNotRequestCameraOrCreateEvidence() async throws {
        let driver = ControlledCameraDriver()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = XT5ProbeLaunchRunner(transport: ImageCaptureTransport(driver: driver), directory: directory)
        await runner.runIfRequested(arguments: ["FujiStudio"])
        #expect(driver.startCount == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func explicitLaunchHonorsAuthorizationFailureAndWritesSanitizedOutcomeOnce() async throws {
        let driver = ControlledCameraDriver()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = XT5ProbeLaunchRunner(transport: ImageCaptureTransport(driver: driver), directory: directory)
        let task = Task { await runner.runIfRequested(arguments: ["FujiStudio", "--xt5-read-only-probe"]) }
        await driver.waitForStartCount(1)
        driver.emit(.failed(.authorizationDenied))
        await task.value
        let text = try String(contentsOf: directory.appendingPathComponent("xt5-protocol-status.txt"), encoding: .utf8)
        #expect(text.contains("authorization denied or restricted"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("camera-diagnostics.txt").path))
        await runner.runIfRequested(arguments: ["FujiStudio", "--xt5-read-only-probe"])
        #expect(driver.startCount == 1)
    }
}
