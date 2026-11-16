#if DEBUG
import Foundation
import FujiCameraCore
import Synchronization

/// One boot's manual identity attempts. Network and protocol callbacks record synchronously in
/// memory so the trace preserves the order of the observations before resuming continuations.
final class ManualWiFiIdentityTrace: Sendable {
  typealias Trace = WirelessIdentityTrace

  struct Entry: Encodable {
    let sequence: Int
    let elapsedMilliseconds: Int
    let event: Trace.Event
  }

  enum Kind: String, Encodable { case connection, gallery }

  struct Attempt: Encodable {
    let kind: Kind
    let ordinal: Int
    let startedAt: Date
    fileprivate let start: ContinuousClock.Instant
    private(set) var events: [Entry] = []
    private(set) var droppedEvents = 0
    private(set) var galleryCards: [String: Trace.GalleryCardSummary] = [:]
    private(set) var protocolFailure: Entry?
    private(set) var emptyDeviceInfo: Entry?
    private(set) var cleanupFailure: Entry?
    private(set) var timerElapsed: Entry?
    private(set) var deadline: Entry?
    private(set) var protocolStageAtDeadline: Trace.Stage?
    private(set) var cleanupStageAtDeadline: Trace.Stage?

    private(set) var pendingProtocol: Trace.Stage?
    private(set) var lastProtocolStage: Trace.Stage?
    private(set) var pendingCloseSession: Trace.Stage?
    private(set) var pendingSocket: Trace.Stage?
    private(set) var pendingSessionCleanup: Trace.Stage?

    enum CodingKeys: String, CodingKey {
      case kind, ordinal, startedAt, events, droppedEvents, protocolFailure, cleanupFailure, emptyDeviceInfo, galleryCards
      case timerElapsed, deadline, protocolStageAtDeadline, cleanupStageAtDeadline, pendingProtocol, lastProtocolStage
      case pendingCloseSession, pendingSocket, pendingSessionCleanup
    }

    fileprivate mutating func append(_ event: Trace.Event, sequence: Int, now: ContinuousClock.Instant) {
      let event = if event.stage == .socketRead, let stage = pendingProtocol ?? pendingCloseSession {
        Trace.Event(stage, event.action, bytes: event.bytes, failure: event.failure, responseCode: event.responseCode)
      } else { event }
      let elapsed = start.duration(to: now).components
      let entry = Entry(
        sequence: sequence, elapsedMilliseconds: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
        event: event)
      let stage = event.stage
      switch stage {
      case .identityTimerElapsed:
        timerElapsed = entry
        protocolStageAtDeadline = pendingProtocol
        cleanupStageAtDeadline = pendingSocket ?? pendingCloseSession ?? pendingSessionCleanup
      case .identityDeadline: deadline = entry
      case .deviceInfoValidation where event.action == .noData && event.bytes == 0: emptyDeviceInfo = entry
      case .galleryCardSummary:
        if let card = event.galleryCard, (1...2).contains(card.slot) {
          galleryCards[String(card.slot)] = card
        }
      case .identityResult, .identityCancellation: break
      case .socketClose: Self.updatePending(event, slot: &pendingSocket)
      case .sessionCleanup: Self.updatePending(event, slot: &pendingSessionCleanup)
      case .closeSessionWrite, .closeSessionHeader, .closeSessionData, .closeSessionFinalHeader, .closeSessionResponseBody:
        Self.updatePending(event, slot: &pendingCloseSession)
      default:
        if event.action == .waiting { lastProtocolStage = stage }
        Self.updatePending(event, slot: &pendingProtocol)
      }
      if event.action == .failed {
        switch stage {
        case .identityTimerElapsed, .identityDeadline, .identityResult, .identityCancellation: break
        case .socketClose, .sessionCleanup, .closeSessionWrite, .closeSessionHeader, .closeSessionData,
             .closeSessionFinalHeader, .closeSessionResponseBody:
          cleanupFailure = entry
        case .galleryOpen where event.responseCode == 0x2013: break
        case .attempt where protocolFailure != nil || deadline != nil: break
        default: protocolFailure = entry
        }
      }
      events.append(entry)
      if events.count > 160 {
        // Retain the start, with separate slots for empty DeviceInfo, failures and the deadline.
        events.remove(at: 1)
        droppedEvents += 1
      }
    }

    private static func updatePending(_ event: Trace.Event, slot: inout Trace.Stage?) {
      if event.action == .waiting {
        slot = event.stage
      } else if (event.action == .completed || event.action == .failed), slot == event.stage {
        slot = nil
      }
    }
  }

  private struct State {
    var attempts: [Attempt] = []
    var ordinal = 0
    var sequence = 0
    var revision = 0
    var writtenRevision = -1
    var delayedWrite = false
    var urgentWrite = false
  }

  private let state = Mutex(State())
  private let writer = DispatchQueue(label: "com.lun3x.FujiStudio.manual-identity-trace", qos: .utility)
  private let url: URL?

  init(url: URL?) {
    self.url = url
    scheduleWrite(urgent: true)
  }

  static func live() -> ManualWiFiIdentityTrace {
    let documents = try? FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return ManualWiFiIdentityTrace(url: documents?.appending(path: "ManualWiFiIdentityTrace.json"))
  }

  /// The returned observer permanently belongs to this identity invocation, including late cleanup.
  func begin(kind: Kind = .connection) -> Trace.Observer {
    let ordinal = state.withLock { state in
      state.ordinal += 1
      let ordinal = state.ordinal
      state.attempts.append(.init(kind: kind, ordinal: ordinal, startedAt: Date(), start: .now))
      if state.attempts.count > 6 { state.attempts.removeFirst() }
      return ordinal
    }
    append(.init(.attempt, .waiting), ordinal: ordinal)
    return { [self] in append($0, ordinal: ordinal) }
  }

  private func append(_ event: Trace.Event, ordinal: Int) {
    let recorded = state.withLock { state in
      guard let index = state.attempts.firstIndex(where: { $0.ordinal == ordinal }) else { return false }
      state.sequence += 1
      state.revision += 1
      state.attempts[index].append(event, sequence: state.sequence, now: .now)
      return true
    }
    if recorded {
      scheduleWrite(urgent: event.action == .failed || event.stage == .attempt
        || event.stage == .socketClose || event.stage == .identityTimerElapsed)
    }
  }

  private func scheduleWrite(urgent: Bool) {
    guard url != nil else { return }
    let schedule = state.withLock { state in
      if urgent {
        guard !state.urgentWrite else { return false }
        state.urgentWrite = true
      } else {
        guard !state.delayedWrite && !state.urgentWrite else { return false }
        state.delayedWrite = true
      }
      return true
    }
    guard schedule else { return }
    if urgent {
      writer.async { self.write(urgent: true) }
    } else {
      writer.asyncAfter(deadline: .now() + .milliseconds(150)) { self.write(urgent: false) }
    }
  }

  private func write(urgent: Bool) {
    guard let url else { return }
    let snapshot = state.withLock { state -> (Int, [Attempt])? in
      if urgent { state.urgentWrite = false } else { state.delayedWrite = false }
      guard state.revision != state.writtenRevision else { return nil }
      return (state.revision, state.attempts)
    }
    guard let (revision, attempts) = snapshot else { return }
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(attempts).write(to: url, options: [.atomic, .completeFileProtection])
      state.withLock { $0.writtenRevision = revision }
    } catch {
      // File I/O is best effort; never surface paths or errors in the probe.
    }
  }
}
#endif
