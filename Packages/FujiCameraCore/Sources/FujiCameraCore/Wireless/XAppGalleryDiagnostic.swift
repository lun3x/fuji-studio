#if DEBUG
import Foundation

/// Safe-to-display summary of the full metadata scan, with bounded rows per card.
public struct XAppGalleryDiagnosticResult: Sendable, Equatable {
  public static let sampleLimitPerCard = 32
  public let wifiIdentityAvailable: Bool
  public let cards: [Card]

  public init(wifiIdentityAvailable: Bool, cards: [Card]) {
    self.wifiIdentityAvailable = wifiIdentityAvailable
    self.cards = cards
  }

  public struct Card: Sendable, Equatable {
    public private(set) var summary: WirelessIdentityTrace.GalleryCardSummary
    public private(set) var samples: [Sample]

    public init(slot: UInt32, totalHandles: Int?, samples: [Sample]) {
      self.samples = Array(samples.prefix(XAppGalleryDiagnosticResult.sampleLimitPerCard))
      summary = .init(slot: slot, totalHandles: totalHandles,
        jpegCount: samples.count(where: { $0.format == .jpeg }),
        rafCount: samples.count(where: { $0.format == .raf }),
        otherCount: samples.count(where: { if case .other = $0.format { true } else { false } }))
    }

    mutating func record(_ object: WirelessObjectDescriptor) {
      summary.record(object.format)
      if samples.count < XAppGalleryDiagnosticResult.sampleLimitPerCard {
        samples.append(.init(filename: object.filename, format: object.format, byteLength: object.byteLength))
      }
    }
  }

  public struct Sample: Sendable, Equatable {
    public let filename: String
    public let format: WirelessObjectFormat
    public let byteLength: UInt64

    public init(filename: String, format: WirelessObjectFormat, byteLength: UInt64) {
      self.filename = filename
      self.format = format
      self.byteLength = byteLength
    }
  }
}

enum GalleryOriginalRestoration {
  case setting(WirelessIdentityTrace.GalleryOriginalMode, slot: UInt32)
  case owed(WirelessIdentityTrace.GalleryOriginalMode, slot: UInt32)
  case refused(UInt16)
  case unconfirmed
}

public typealias XAppOriginalControlObservation = WirelessIdentityTrace.OriginalControl

public protocol XAppGalleryDiagnostic: XAppConnectionDiagnostic {
  func listCameraPhotos() async throws -> XAppGalleryDiagnosticResult
  func scannedPairCandidates() async throws -> [WirelessObjectDescriptor]
  func downloadGalleryCandidate(
    _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> XAppOriginalControlObservation
  /// Close native I/O immediately, including if graceful session cleanup is in progress.
  func abortGallery() async
}

extension CameraHostedTransferSession {
  func listCameraPhotos() async throws -> XAppGalleryDiagnosticResult {
    guard galleryObjects == nil else { throw WirelessFailure.unsupportedProtocol }
    try begin()
    defer { busy = false }
    let connection = try await openGallery()
    let slots = try await configureXAppGalleryMode()
    var cards: [XAppGalleryDiagnosticResult.Card] = []
    var objects: [UInt32: [UInt32: WirelessObjectDescriptor]] = [:]
    for slot in slots {
      transport.observeIdentity(.init(.galleryCardBegin, .completed, gallerySlot: slot))
      let handles = try await configureXAppCard(slot)
      var card = XAppGalleryDiagnosticResult.Card(slot: slot, totalHandles: handles?.count, samples: [])
      transport.observeIdentity(.init(.galleryCardSummary, .waiting, galleryCard: card.summary))
      if let handles {
        try await prepareGalleryOriginalMode(slot: slot)
        for handle in handles {
          let info = try await objectInfo(handle: handle, storage: slot)
          card.record(info)
          if info.format == .raf || info.format == .jpeg {
            objects[slot, default: [:]][handle] = info
          }
          transport.observeIdentity(.init(.galleryCardSummary, .waiting, galleryCard: card.summary))
        }
      }
      transport.observeIdentity(.init(.galleryCardSummary, .completed, galleryCard: card.summary))
      cards.append(card)
    }
    galleryObjects = objects
    return .init(wifiIdentityAvailable: connection != .respondingWithoutDeviceInfo, cards: cards)
  }

  func scannedPairCandidates() throws -> [WirelessObjectDescriptor] {
    try checkOpenOperation()
    guard !busy, let galleryObjects else { throw WirelessFailure.objectChanged }
    return galleryObjects.values.flatMap { $0.values }
  }

  func downloadGalleryCandidate(
    _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> XAppOriginalControlObservation {
    guard galleryObjects?[object.storageID]?[object.handle] == object else {
      throw WirelessFailure.objectChanged
    }
    let length = try originalLength(object)
    try begin()
    defer { busy = false }
    try await selectStorage(for: object.storageID)
    let role: WirelessIdentityTrace.PairRole = object.format == .raf ? .raf : .jpeg
    let expected = object.byteLength
    transport.observeIdentity(.init(.pairControlRead, .waiting, pairFile: .init(role: role, expectedBytes: expected)))
    let observation: XAppOriginalControlObservation
    do {
      try await prepareGalleryOriginalMode(slot: object.storageID)
      observation = .reported(2)
    } catch {
      let response: UInt16?
      if case PTPError.responseCode(let code) = error { response = code } else { response = nil }
      transport.observeIdentity(.init(.pairControlRead, .failed, failure: .init(error), responseCode: response,
        pairFile: .init(role: role, expectedBytes: expected)))
      throw error
    }
    transport.observeIdentity(.init(.pairControlRead, .completed,
      pairFile: .init(role: role, expectedBytes: expected, originalControl: observation)))
    try await streamMatchingObject(object, length: length, to: sink)
    return observation
  }

  private func prepareGalleryOriginalMode(slot: UInt32) async throws {
    guard selectedStorage == slot else { throw WirelessFailure.unavailableStorage }
    if case .refused(let code) = galleryOriginalRestoration { throw PTPError.responseCode(code) }
    if case .unconfirmed = galleryOriginalRestoration { throw WirelessFailure.originalSizeUnavailable }
    if galleryOriginalModePrepared {
      try await requireGalleryOriginalMode()
      return
    }

    let prior = try await readGalleryOriginalMode(stage: .galleryOriginalModeRead)
    if prior != .original {
      let stage = WirelessIdentityTrace.Stage.galleryOriginalModeWrite
      transport.observeIdentity(.init(stage, .waiting, gallerySlot: slot, galleryOriginalMode: .original))
      galleryOriginalRestoration = .setting(prior, slot: slot)
      do {
        try await setProperty(0xd226, WirelessIdentityTrace.GalleryOriginalMode.original.rawValue, width: 2) {
          if case .setting = galleryOriginalRestoration {
            galleryOriginalRestoration = .owed(prior, slot: slot)
          }
        }
        transport.observeIdentity(.init(stage, .completed, gallerySlot: slot, galleryOriginalMode: .original))
      } catch let PTPError.responseCode(code) {
        if case .setting = galleryOriginalRestoration { galleryOriginalRestoration = nil }
        transport.observeIdentity(.init(stage, .failed, failure: .rejected, responseCode: code, gallerySlot: slot))
        throw PTPError.responseCode(code)
      } catch {
        transport.observeIdentity(.init(stage, .failed, failure: .init(error), gallerySlot: slot))
        if case .setting = galleryOriginalRestoration {
          markGalleryRestorationUnconfirmed(.init(error))
        }
        throw error
      }
      try await requireGalleryOriginalMode()
    }
    galleryOriginalModePrepared = true
  }

  private func requireGalleryOriginalMode() async throws {
    _ = try await readGalleryOriginalMode(stage: .galleryOriginalModeConfirmation, requireOriginal: true)
  }

  private func readGalleryOriginalMode(
    stage: WirelessIdentityTrace.Stage, requireOriginal: Bool = false
  ) async throws -> WirelessIdentityTrace.GalleryOriginalMode {
    let slot = selectedStorage
    transport.observeIdentity(.init(stage, .waiting, gallerySlot: slot))
    do {
      let value = try await readScalar(0xd226, widths: [2, 4])
      guard let mode = WirelessIdentityTrace.GalleryOriginalMode(rawValue: value),
        !requireOriginal || mode == .original
      else { throw WirelessFailure.originalSizeUnavailable }
      transport.observeIdentity(.init(stage, .completed, gallerySlot: slot, galleryOriginalMode: mode))
      return mode
    } catch {
      let response: UInt16?
      if case PTPError.responseCode(let code) = error { response = code } else { response = nil }
      transport.observeIdentity(.init(stage, .failed, failure: .init(error), responseCode: response, gallerySlot: slot))
      if response == 0x200a { throw WirelessFailure.originalSizeUnavailable }
      throw error
    }
  }

  // Restore before D244 changes the slot. D226 has no verified cross-card scope.
  func restoreGalleryOriginalMode(canRestore: Bool, whileClosing: Bool) async throws {
    guard let restoration = galleryOriginalRestoration else { return }
    if case .refused(let code) = restoration { throw PTPError.responseCode(code) }
    guard canRestore, case .owed(let prior, let slot) = restoration, selectedStorage == slot else {
      markGalleryRestorationUnconfirmed(canRestore ? .connectionLost : .cancelled)
      throw WirelessFailure.originalSizeUnavailable
    }
    let stage = WirelessIdentityTrace.Stage.galleryOriginalModeRestore
    transport.observeIdentity(.init(stage, .waiting, gallerySlot: slot, galleryOriginalMode: prior))
    do {
      try await setProperty(0xd226, prior.rawValue, width: 2, whileClosing: whileClosing) {
        galleryOriginalRestoration = nil
        transport.observeIdentity(.init(stage, .completed, gallerySlot: slot, galleryOriginalMode: prior))
      }
    } catch let PTPError.responseCode(code) {
      galleryOriginalRestoration = .refused(code)
      transport.observeIdentity(.init(stage, .failed, failure: .rejected, responseCode: code,
        gallerySlot: slot, galleryOriginalMode: prior))
      throw PTPError.responseCode(code)
    } catch {
      markGalleryRestorationUnconfirmed(.init(error))
      throw error
    }
  }

  func markGalleryRestorationUnconfirmed(_ failure: WirelessIdentityTrace.Failure) {
    let prior: WirelessIdentityTrace.GalleryOriginalMode
    let slot: UInt32
    switch galleryOriginalRestoration {
    case .setting(let mode, let changedSlot), .owed(let mode, let changedSlot):
      prior = mode
      slot = changedSlot
    case .refused, .unconfirmed, nil: return
    }
    galleryOriginalRestoration = .unconfirmed
    transport.observeIdentity(.init(.galleryOriginalModeRestoreUnconfirmed, .failed,
      failure: failure, gallerySlot: slot, galleryOriginalMode: prior))
  }

}

extension XAppTransferAdapter {
  public static func makeGalleryDiagnostic(
    transport: WirelessPTPTransport, expectedIdentity: WirelessIdentity, clientGUID: Data,
    clientName: String
  ) -> any XAppGalleryDiagnostic {
    CameraHostedTransferSession(
      transport: transport, expectedIdentity: expectedIdentity, mode: .xApp,
      clientGUID: clientGUID, clientName: clientName)
  }
}
#endif
