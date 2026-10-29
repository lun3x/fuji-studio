import Foundation
import FujiCameraCore
import ImageCaptureCore
import Testing

@testable import FujiCameraLaptop

@MainActor struct MacDriverCallbackTests {
  @Test func lateNativeCallbackCannotAliasNewGeneration() throws {
    let browser = MacTestBrowser()
    let camera = MacTestCamera()
    let callbacks = MacCallbackQueue()
    browser.items = [camera]
    let driver = MacImageCaptureDriver(
      makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
    var connections: [CameraConnection] = []
    driver.start { if case .opened(let c) = $0 { connections.append(c) } }
    camera.completeOpen()
    callbacks.drain()
    let first = try #require(connections.first?.attachmentIdentity)
    let old = Data([12, 0, 0, 0, 1, 0, 1, 0x10, 1, 0, 0, 0])
    driver.send(command: old, data: nil) { _ in Issue.record("Retired command must never complete")
    }
    let retired = try #require(camera.context)
    driver.close {}
    callbacks.drain()
    #expect(driver.confirmedClosed)
    driver.start { if case .opened(let c) = $0 { connections.append(c) } }
    camera.completeOpen()
    callbacks.drain()
    #expect(connections.last?.attachmentIdentity == first)
    var result: Result<PTPWireReply, PTPError>?
    let current = Data([12, 0, 0, 0, 1, 0, 1, 0x10, 2, 0, 0, 0])
    driver.send(command: current, data: nil) { result = $0 }
    driver.didSendPTPCommand(
      old, inData: Data(), response: Data([12, 0, 0, 0, 3, 0, 1, 0x20, 9, 0, 0, 0]), error: nil,
      contextInfo: UnsafeMutableRawPointer(bitPattern: retired))
    callbacks.drain()
    #expect(result == nil)
    driver.didSendPTPCommand(
      current, inData: Data([42]), response: Data([12, 0, 0, 0, 3, 0, 1, 0x20, 10, 0, 0, 0]),
      error: nil, contextInfo: UnsafeMutableRawPointer(bitPattern: try #require(camera.context)))
    callbacks.drain()
    #expect(try #require(result).get().data == Data([42]))
    driver.close {}
    callbacks.drain()
    #expect(driver.confirmedClosed)
  }
}
private final class MacTestBrowser: ICDeviceBrowser {
  var items: [ICDevice] = []
  private var browsingNow = false
  override var devices: [ICDevice]? { items }
  override var isBrowsing: Bool { browsingNow }
  override func start() { browsingNow = true }
  override func stop() { browsingNow = false }
}
private final class MacTestCamera: ICCameraDevice {
  var context: UInt?
  private var sessionOpen = false
  private var opened: (@Sendable ((any Error)?) -> Void)?
  override var name: String? { "X-E3" }
  override var usbVendorID: Int32 { 0x04cb }
  override var usbProductID: Int32 { 0x02d6 }
  override var transportType: String? { ICDeviceTransport.transportTypeUSB.rawValue }
  override var capabilities: [String] {
    [ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue]
  }
  override var hasOpenSession: Bool { sessionOpen }
  override func requestOpenSession(
    options: [ICSessionOptions: Any]?, completion: @escaping @Sendable ((any Error)?) -> Void
  ) { opened = completion }
  func completeOpen() {
    sessionOpen = true
    opened?(nil)
  }
  override func requestCloseSession(
    options: [ICSessionOptions: Any]?, completion: @escaping @Sendable ((any Error)?) -> Void
  ) {
    sessionOpen = false
    completion(nil)
  }
  override func requestSendPTPCommand(
    _ command: Data, outData: Data?, sendCommandDelegate: Any, didSendCommand selector: Selector,
    contextInfo: UnsafeMutableRawPointer?
  ) { context = contextInfo.map { UInt(bitPattern: $0) } }
}
private final class MacCallbackQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [@MainActor @Sendable () -> Void] = []
  func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) {
    lock.withLock { pending.append(action) }
  }
  @MainActor func drain() {
    while true {
      let batch = lock.withLock {
        let batch = pending
        pending = []
        return batch
      }
      if batch.isEmpty { return }
      for action in batch { action() }
    }
  }
}
