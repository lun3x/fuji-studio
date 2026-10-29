@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct PTPCodecTests {
    private let command = PTPCommand(opcode: 0x1001, parameters: [], transactionID: 7)
    private let ok = Data([12, 0, 0, 0, 3, 0, 1, 32, 7, 0, 0, 0])

    @Test func commandUsesLittleEndianContainer() throws {
        let value = PTPCommand(opcode: 0x1015, parameters: [0xD185], transactionID: 7)
        #expect(try PTPCodec.encode(value) == Data([16,0,0,0,1,0,21,16,7,0,0,0,133,209,0,0]))
    }
    @Test func validReplyKeepsRawPayloadSeparateFromResponseContainer() throws {
        let payload = Data([0xff, 0xd8, 0xff, 0xd9])
        let reply = try PTPCodec.decode(response: ok, data: payload, for: command, maximumDataBytes: 4)
        #expect(reply.data == payload)
        #expect(reply.opcode == 0x1001)
        #expect(reply.logicalTransactionID == 7)
        #expect(reply.wireTransactionID == 7)
        #expect(reply.rawResponse == ok)
        #expect(reply.correlation == .directWireTransaction)
        #expect(reply.responseCode == 0x2001)
    }
    @Test func truncatedContainerFails() {
        #expect(throws: PTPError.truncatedContainer) {
            try PTPCodec.decode(response: Data(ok.prefix(11)), data: Data(), for: command)
        }
    }
    @Test func oversizedContainerFailsBeforeParsing() {
        #expect(throws: PTPError.oversizedContainer) {
            try PTPCodec.decode(response: Data(repeating: 0, count: 36), data: Data(), for: command)
        }
    }
    @Test func lengthMismatchAndUnalignedParametersFail() {
        var mismatch = ok; mismatch[0] = 16
        #expect(throws: PTPError.invalidContainerLength) {
            try PTPCodec.decode(response: mismatch, data: Data(), for: command)
        }
        var unaligned = ok; unaligned[0] = 13; unaligned.append(0)
        #expect(throws: PTPError.invalidContainerLength) {
            try PTPCodec.decode(response: unaligned, data: Data(), for: command)
        }
    }
    @Test func dataContainerCannotMasqueradeAsSuccessfulReply() {
        var dataContainer = ok; dataContainer[4] = 2
        #expect(throws: PTPError.unexpectedContainerType(2)) {
            try PTPCodec.decode(response: dataContainer, data: Data(), for: command)
        }
    }
    @Test func cameraFailureWithJPEGBytesStillFails() {
        var failure = ok; failure[6] = 2
        #expect(throws: PTPError.responseCode(0x2002)) {
            try PTPCodec.decode(response: failure, data: Data([0xff,0xd8]), for: command)
        }
    }
    @Test func wrongTransactionFails() {
        var stale = ok; stale[8] = 6
        #expect(throws: PTPError.wrongTransaction(expected: 7, actual: 6)) {
            try PTPCodec.decode(response: stale, data: Data(), for: command)
        }
    }
    @Test func oversizedPayloadFails() {
        #expect(throws: PTPError.payloadTooLarge) {
            try PTPCodec.decode(response: ok, data: Data([1,2]), for: command, maximumDataBytes: 1)
        }
    }
    @Test func invalidCommandNeverEncodes() {
        #expect(throws: PTPError.invalidParameters) {
            try PTPCodec.encode(PTPCommand(opcode: 0x1001, parameters: [1,2,3,4,5,6], transactionID: 1))
        }
        #expect(throws: PTPError.invalidOpcode(0)) {
            try PTPCodec.encode(PTPCommand(opcode: 0, parameters: [], transactionID: 1))
        }
    }

    @Test func directWireMismatchStaysStrictWhileFrameworkReplyPreservesBothIdentities() throws {
        let logical = PTPCommand(opcode: 0x1001, parameters: [], transactionID: 1)
        let raw = Data([12,0,0,0,3,0,1,32,9,0,0,0])
        #expect(throws: PTPError.wrongTransaction(expected: 1, actual: 9)) {
            try PTPCodec.decode(response: raw, data: Data([42]), for: logical)
        }
        let managed = try PTPCodec.decodeFrameworkManaged(response: raw, data: Data([42]), for: logical, echoedCommand: logical)
        #expect(managed.logicalTransactionID == 1)
        #expect(managed.wireTransactionID == 9)
        #expect(managed.rawResponse == raw)
        #expect(managed.correlation == .imageCaptureCoreCallback(echoedCommand: logical))
    }

    @Test func frameworkResponseStillRequiresLogicalEchoAndBoundedData() {
        let logical = PTPCommand(opcode: 0x1001, parameters: [], transactionID: 1)
        let changed = PTPCommand(opcode: 0x1001, parameters: [], transactionID: 2)
        let raw = Data([12,0,0,0,3,0,1,32,9,0,0,0])
        #expect(throws: PTPError.wrongTransaction(expected: 1, actual: 2)) {
            try PTPCodec.decodeFrameworkManaged(response: raw, data: Data(), for: logical, echoedCommand: changed)
        }
        #expect(throws: PTPError.payloadTooLarge) {
            try PTPCodec.decodeFrameworkManaged(response: raw, data: Data([1,2]), for: logical, echoedCommand: logical, maximumDataBytes: 1)
        }
    }

    @MainActor @Test func timeoutQuarantinesWireUntilCloseCompletes() async throws {
        let driver = ControlledCameraDriver(); let clock = ControlledCameraTimeouts()
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        try await open(transport, driver)
        let operation = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(1)
        clock.fireAll()
        await #expect(throws: PTPError.timeout) { try await operation.value }
        await #expect(throws: PTPError.sessionClosing) { try await transport.connect() }
        await #expect(throws: PTPError.notConnected) { try await transport.execute(command, data: nil) }
        driver.finishClose()
        try await open(transport, driver)
        let fresh = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(2)
        driver.reply(at: 0, response: ok, data: Data([99])) // late callback from timed-out wire
        driver.reply(at: 1, response: ok, data: Data([42]))
        #expect(try await fresh.value.data == Data([42]))
        await transport.disconnect(); driver.finishClose()
    }

    @MainActor @Test func disconnectedGenerationRejectsLateReply() async throws {
        let driver = ControlledCameraDriver(); let clock = ControlledCameraTimeouts()
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        try await open(transport, driver)
        let old = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(1)
        await transport.disconnect()
        await #expect(throws: PTPError.notConnected) { try await old.value }
        driver.finishClose()
        try await open(transport, driver)
        let fresh = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(2)
        driver.reply(at: 0, response: ok, data: Data([99]))
        driver.reply(at: 1, response: ok, data: Data([42]))
        #expect(try await fresh.value.data == Data([42]))
        await transport.disconnect(); driver.finishClose()
    }

    @MainActor @Test func concurrentWireCommandIsRejectedWhileFirstIsSuspended() async throws {
        let driver = ControlledCameraDriver(); let clock = ControlledCameraTimeouts()
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        try await open(transport, driver)
        let first = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(1)
        await #expect(throws: PTPError.busy) { try await transport.execute(command, data: nil) }
        driver.reply(at: 0, response: ok, data: Data())
        _ = try await first.value
        await transport.disconnect(); driver.finishClose()
    }

    @MainActor @Test func cancellationInvalidatesSessionInsteadOfFreeingActiveWire() async throws {
        let driver = ControlledCameraDriver(); let clock = ControlledCameraTimeouts()
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        try await open(transport, driver)
        let first = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: PTPError.sessionClosing) { try await transport.connect() }
        driver.finishClose()
    }

    @MainActor @Test func sessionOpenDoesNotClaimConversionReadyAndAuthorizationFailureIsDistinct() async throws {
        let driver = ControlledCameraDriver(); let transport = ImageCaptureTransport(driver: driver, timeouts: ControlledCameraTimeouts())
        let states = await transport.states()
        var iterator = states.makeAsyncIterator()
        #expect(await iterator.next() == .disconnected)
        try await open(transport, driver)
        #expect(await iterator.next() == .discovering)
        guard case .sessionOpen = await iterator.next() else { Issue.record("Opening PTP must not claim conversion ready"); return }
        await transport.disconnect(); driver.finishClose()
        let denied = Task { try await transport.connect() }
        await driver.waitForStartCount(2)
        driver.emit(.failed(.authorizationDenied))
        await #expect(throws: PTPError.authorizationDenied) { try await denied.value }
        driver.finishClose()
    }

    @MainActor @Test func staleCloseCallbackCannotReleaseFreshQuarantine() async throws {
        let driver = ControlledCameraDriver(); let clock = ControlledCameraTimeouts()
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        try await open(transport, driver)
        await transport.disconnect(); driver.finishClose(at: 0)
        try await open(transport, driver)
        let pending = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(1)
        clock.fireAll()
        await #expect(throws: PTPError.timeout) { try await pending.value }
        driver.finishClose(at: 0) // duplicate completion from old generation
        clock.automaticallyFire = true // a wrongly admitted connect deterministically fails rather than hanging
        await #expect(throws: PTPError.sessionClosing) { try await transport.connect() }
        driver.finishClose(at: 1)
    }

    @MainActor @Test func connectionTimeoutRejectsLateOpenAndRequiresConfirmedClose() async throws {
        let driver = ControlledCameraDriver(); let clock = ControlledCameraTimeouts()
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        let pending = Task { try await transport.connect() }
        await driver.waitForStartCount(1)
        driver.emit(.discoveryStarted) // Repeated progress cannot extend/reset the current USB deadline.
        #expect(clock.scheduledCount == 1)
        clock.fireAll()
        await #expect(throws: PTPError.timeout) { try await pending.value }
        driver.emit(.opened(CameraConnection(name: "late", usbVendorID: 0x04cb, usbProductID: 1)))
        await #expect(throws: PTPError.notConnected) { try await transport.execute(command, data: nil) }
        await #expect(throws: PTPError.sessionClosing) { try await transport.connect() }
        driver.finishClose()
    }

    @MainActor @Test func malformedReplyInvalidatesSessionButCameraRejectionCanContinue() async throws {
        let driver = ControlledCameraDriver(); let clock = ControlledCameraTimeouts()
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        try await open(transport, driver)
        let rejected = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(1)
        var failure = ok; failure[6] = 2
        driver.reply(at: 0, response: failure, data: Data([0xff,0xd8]))
        await #expect(throws: PTPError.responseCode(0x2002)) { try await rejected.value }
        let malformed = Task { try await transport.execute(command, data: nil) }
        await driver.waitForCommandCount(2)
        driver.reply(at: 1, response: Data(), data: Data([0xff,0xd8]))
        await #expect(throws: PTPError.truncatedContainer) { try await malformed.value }
        await #expect(throws: PTPError.sessionClosing) { try await transport.connect() }
        driver.finishClose()
    }

    @MainActor private func open(_ transport: ImageCaptureTransport, _ driver: ControlledCameraDriver) async throws {
        let count = driver.startCount
        let task = Task { try await transport.connect() }
        await driver.waitForStartCount(count + 1)
        driver.emit(.opened(CameraConnection(name: "X-T5 fixture", usbVendorID: 0x04cb, usbProductID: 1)))
        try await task.value
    }
}
