import Foundation

/// Owns an issued native attempt until its terminal callback or manager retirement.
/// The driver only assigns an application session ID after matching the native objects.
struct CoreBluetoothConnections<Manager: AnyObject, Peripheral: AnyObject> {
  struct Attempt {
    let session: UUID
    let manager: Manager
    let peripheral: Peripheral
    fileprivate(set) var closing = false
  }

  enum Cancellation: Equatable {
    case neverIssued
    case request
    case awaitingTerminal
  }

  private(set) var manager: Manager?
  private(set) var active: Attempt?
  private var discoveries: [UUID: Peripheral] = [:]

  @discardableResult
  mutating func installManager(_ manager: Manager) -> Bool {
    guard self.manager == nil else { return false }
    self.manager = manager
    return true
  }

  func isCurrent(_ manager: Manager) -> Bool { self.manager === manager }

  func canRemember(_ id: UUID) -> Bool {
    discoveries.count < 64 || discoveries[id] != nil
  }

  mutating func remember(_ peripheral: Peripheral, for id: UUID) {
    guard canRemember(id) else { return }
    discoveries[id] = peripheral
  }

  mutating func discardDiscoveries() { discoveries.removeAll() }

  mutating func begin(
    session: UUID, peripheralID: UUID, manager: Manager, retrieve: () -> Peripheral?
  ) -> Peripheral? {
    guard isCurrent(manager), active == nil,
      let peripheral = discoveries[peripheralID] ?? retrieve()
    else { return nil }
    discardDiscoveries()
    active = Attempt(session: session, manager: manager, peripheral: peripheral)
    return peripheral
  }

  mutating func requestCancellation(for session: UUID, canRequest: Bool) -> Cancellation {
    guard let active, active.session == session else { return .neverIssued }
    guard !active.closing else { return .awaitingTerminal }
    self.active?.closing = true
    return canRequest ? .request : .awaitingTerminal
  }

  mutating func consumeTerminal(manager: Manager, peripheral: Peripheral) -> UUID? {
    guard isCurrent(manager), let active, active.peripheral === peripheral else { return nil }
    self.active = nil
    return active.session
  }

  mutating func retireManagerWithAttempt(_ manager: Manager) -> UUID? {
    guard isCurrent(manager) else { return nil }
    discardDiscoveries()
    guard let active else { return nil }
    self.manager = nil
    self.active = nil
    return active.session
  }
}
