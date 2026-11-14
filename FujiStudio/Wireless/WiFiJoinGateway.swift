import Foundation

protocol WiFiJoinGateway: Sendable {
  func join(_ network: CameraNetwork) async throws -> JoinedCameraNetwork
  func leave(_ network: JoinedCameraNetwork) async
  func verify(_ network: JoinedCameraNetwork) async throws
  /// Wait until a timed-out or cancelled system apply can no longer install a configuration.
  func drainPendingJoin() async
}

struct JoinedCameraNetwork: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let ssid: String
  let ownsTemporaryConfiguration: Bool

  init(id: UUID = UUID(), ssid: String, ownsTemporaryConfiguration: Bool) {
    self.id = id
    self.ssid = ssid
    self.ownsTemporaryConfiguration = ownsTemporaryConfiguration
  }

  var description: String { "[redacted camera network]" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

/// Task 8 provides the real USB arbitration implementation.
protocol WirelessCameraOwnershipGateway: Sendable {
  func acquireWireless() async throws -> CameraUseLease
  func releaseWireless(_ lease: CameraUseLease) async
}

struct CameraUseLease: Equatable, Sendable {
  let owner: UUID
  let generation: UUID

  init(owner: UUID = UUID(), generation: UUID = UUID()) {
    self.owner = owner
    self.generation = generation
  }
}
