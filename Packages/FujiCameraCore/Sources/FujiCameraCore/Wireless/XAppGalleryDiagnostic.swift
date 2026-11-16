#if DEBUG
import Foundation

/// The manual gallery test returns an in-memory sample with no transferable object identifiers.
public struct XAppGalleryDiagnosticResult: Sendable, Equatable {
  public static let sampleLimitPerCard = 32
  public let wifiIdentityAvailable: Bool
  public let cards: [Card]

  public init(wifiIdentityAvailable: Bool, cards: [Card]) {
    self.wifiIdentityAvailable = wifiIdentityAvailable
    self.cards = cards
  }

  public struct Card: Sendable, Equatable {
    public let summary: WirelessIdentityTrace.GalleryCardSummary
    public let samples: [Sample]

    public init(slot: UInt32, totalHandles: Int?, samples: [Sample]) {
      self.samples = samples
      summary = .init(slot: slot, totalHandles: totalHandles,
        sampledJPEG: samples.count(where: { $0.format == .jpeg }),
        sampledRAF: samples.count(where: { $0.format == .raf }),
        sampledOther: samples.count(where: { if case .other = $0.format { true } else { false } }))
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

public protocol XAppGalleryDiagnostic: XAppConnectionDiagnostic {
  func listCameraPhotos() async throws -> XAppGalleryDiagnosticResult
  /// Close native I/O immediately, including if graceful session cleanup is in progress.
  func abortGallery() async
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
