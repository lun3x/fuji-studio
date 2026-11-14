import Foundation

/// Owns an issued native attempt until its object-identified terminal callback.
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

  private(set) var active: Attempt?
  private var discoveries: [UUID: Peripheral] = [:]

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
    guard active == nil, let peripheral = discoveries[peripheralID] ?? retrieve() else { return nil }
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
    guard let active, active.manager === manager, active.peripheral === peripheral else { return nil }
    self.active = nil
    return active.session
  }

  mutating func invalidate(manager: Manager) -> UUID? {
    discardDiscoveries()
    guard let active, active.manager === manager else { return nil }
    self.active = nil
    return active.session
  }
}
