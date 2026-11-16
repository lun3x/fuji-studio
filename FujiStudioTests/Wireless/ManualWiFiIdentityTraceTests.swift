#if DEBUG
import Foundation
import FujiCameraCore
import Testing

@testable import FujiStudio

struct ManualWiFiIdentityTraceTests {
  @Test func deadlinePreservesPendingStageAndLateCleanupOnTheOriginalAttempt() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let trace = ManualWiFiIdentityTrace(url: file)
    let first = trace.begin()
    first(.init(.getDeviceInfoData, .waiting))
    first(.init(.getDeviceInfoData, .readRequested, bytes: 65_536))
    first(.init(.identityTimerElapsed, .completed))
    first(.init(.identityDeadline, .failed, failure: .outerDeadline))
    first(.init(.getDeviceInfoData, .failed, failure: .cancelled))
    first(.init(.socketClose, .waiting))
    let second = trace.begin()
    second(.init(.sessionCleanup, .waiting))
    second(.init(.closeSessionHeader, .waiting))
    second(.init(.identityTimerElapsed, .completed))
    first(.init(.socketClose, .completed))
    second(.init(.identityResult, .failed, failure: .peerMismatch))
    second(.init(.attempt, .failed, failure: .peerMismatch))
    let third = trace.begin()
    third(.init(.identityTimerElapsed, .completed))
    third(.init(.identityCancellation, .failed, failure: .cancelled))
    third(.init(.identityResult, .failed, failure: .cancelled))
    third(.init(.attempt, .failed, failure: .cancelled))

    let attempts = try await read(file) {
      $0.count == 3 && self.events($0[0]).count == 8 && self.events($0[1]).count == 6
        && self.events($0[2]).count == 5
    }
    #expect(attempts[0]["protocolStageAtDeadline"] as? String == "getDeviceInfoData")
    #expect(attempts[0]["cleanupStageAtDeadline"] == nil)
    #expect(attempts[0]["lastProtocolStage"] as? String == "getDeviceInfoData")
    #expect(attempts[0]["pendingSocket"] == nil)
    #expect(attempts[0]["deadline"] != nil)
    #expect(attempts[1]["cleanupStageAtDeadline"] as? String == "closeSessionHeader")
    #expect(attempts[1]["timerElapsed"] != nil)
    #expect(attempts[1]["deadline"] == nil)
    #expect(failure(attempts[1]) == "peerMismatch")
    #expect(attempts[2]["deadline"] == nil)
    #expect(failure(attempts[2]) == "cancelled")
    #expect(attempts[1]["ordinal"] as? Int == 2)
    let firstEvents = events(attempts[0])
    let secondEvents = events(attempts[1])
    let lateCleanup = try #require(firstEvents.last?["sequence"] as? Int)
    let nextStart = try #require(secondEvents.first?["sequence"] as? Int)
    #expect(lateCleanup > nextStart)
    let elapsed = firstEvents.compactMap { $0["elapsedMilliseconds"] as? Int }
    #expect(elapsed == elapsed.sorted())
  }

  @Test func reportBoundsReadsKeepsFailureAndResetsWithoutSecrets() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let trace = ManualWiFiIdentityTrace(url: file)
    for _ in 0..<7 { _ = trace.begin() }
    let last = trace.begin()
    last(.init(.initializationBody, .waiting))
    last(.init(.initializationBody, .failed, failure: .init(PTPError.sessionFailure("private-guid"))))
    last(.init(.deviceInfoValidation, .noData, bytes: 0))
    last(.init(.xAppEventsRead, .waiting))
    for _ in 0..<240 { last(.init(.xAppEventsRead, .readRequested, bytes: .max)) }
    last(.init(.identityDeadline, .failed, failure: .outerDeadline))
    let attempts = try await read(file) { $0.last?["deadline"] != nil }
    let latest = try #require(attempts.last)
    #expect(attempts.count == 6)
    #expect(latest["ordinal"] as? Int == 8)
    #expect(events(latest).count == 160)
    #expect(latest["droppedEvents"] as? Int == 86)
    #expect(latest["protocolFailure"] != nil)
    let observation = try #require(latest["emptyDeviceInfo"] as? [String: Any])
    let event = try #require(observation["event"] as? [String: Any])
    #expect(event["stage"] as? String == "deviceInfoValidation")
    #expect(event["action"] as? String == "noData")
    #expect(event["bytes"] as? Int == 0)
    let json = try String(contentsOf: file, encoding: .utf8)
    #expect(json.contains("malformedData"))
    #expect(json.contains("\"bytes\":65536"))
    #expect(!json.contains("private-guid"))
    _ = ManualWiFiIdentityTrace(url: file)
    _ = try await read(file) { $0.isEmpty }
  }

  @Test func galleryCardSummariesAndRejectionCodeSurviveOverflowWithoutFilenames() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let trace = ManualWiFiIdentityTrace(url: file)
    let observer = trace.begin(kind: .gallery)
    let unavailable = XAppGalleryDiagnosticResult.Card(slot: 1, totalHandles: nil, samples: [])
    observer(.init(.galleryModeWrite, .completed))
    observer(.init(.galleryCardBegin, .completed, gallerySlot: 1))
    observer(.init(.galleryOpen, .failed, failure: .rejected, responseCode: 0x2013))
    observer(.init(.galleryCardSummary, .completed, galleryCard: unavailable.summary))
    observer(.init(.galleryCardBegin, .completed, gallerySlot: 2))
    observer(.init(.galleryStorageWrite, .completed))
    observer(.init(.galleryJPEGRAWFilter, .failed, failure: .rejected, responseCode: 0x2002))
    for _ in 0..<200 { observer(.init(.galleryObjectInfo, .completed)) }
    let sample = XAppGalleryDiagnosticResult.Card(slot: 2, totalHandles: 40,
      samples: [.init(filename: "PRIVATE.RAF", format: .raf, byteLength: 4_294_967)])
    observer(.init(.galleryCardSummary, .completed, galleryCard: sample.summary))
    observer(.init(.attempt, .completed))
    let attempts = try await read(file) { self.events($0[0]).last?["sequence"] as? Int == 210 }
    let attempt = try #require(attempts.first)
    #expect(attempt["kind"] as? String == "gallery")
    #expect(events(attempt).count == 160)
    let setup = try #require(attempt["gallerySetup"] as? [[String: Any]])
    let milestones = setup.compactMap { $0["event"] as? [String: Any] }
    try #require(milestones.count == 8)

    #expect(milestones.compactMap { $0["stage"] as? String } == [
      "galleryModeWrite", "galleryCardBegin", "galleryOpen", "galleryCardSummary",
      "galleryCardBegin", "galleryStorageWrite", "galleryJPEGRAWFilter", "galleryCardSummary"
    ])
    #expect(milestones[1]["gallerySlot"] as? Int == 1)
    #expect(milestones[2]["responseCode"] as? Int == 0x2013)
    #expect((milestones[3]["galleryCard"] as? [String: Any])?["slot"] as? Int == 1)
    #expect(milestones[4]["gallerySlot"] as? Int == 2)
    #expect((milestones[7]["galleryCard"] as? [String: Any])?["slot"] as? Int == 2)
    let cards = try #require(attempt["galleryCards"] as? [String: [String: Any]])
    #expect(cards.count == 2)
    #expect(cards["2"]?["totalHandles"] as? Int == 40)
    #expect(cards["2"]?["scannedCount"] as? Int == 1)
    #expect(cards["2"]?["rafCount"] as? Int == 1)
    #expect(cards["1"]?["status"] as? String == "unavailable")
    let failure = try #require(attempt["protocolFailure"] as? [String: Any])
    let event = try #require(failure["event"] as? [String: Any])
    #expect(event["responseCode"] as? Int == 0x2002)
    let json = try String(contentsOf: file, encoding: .utf8)
    #expect(!json.contains("PRIVATE.RAF"))
    #expect(!json.contains("4294967"))
  }

  @Test func pairStagesAndLastFileCountsSurviveTraceOverflow() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let trace = ManualWiFiIdentityTrace(url: file)
    let observer = trace.begin(kind: .pair)
    observer(.init(.pairSelection, .completed))
    observer(.init(.pairControlRead, .completed,
      pairFile: .init(role: .raf, expectedBytes: 400_000, originalControl: .reported(2))))
    observer(.init(.pairFileValidation, .completed,
      pairFile: .init(role: .raf, expectedBytes: 400_000, receivedBytes: 400_000)))
    observer(.init(.pairFileTransfer, .waiting,
      pairFile: .init(role: .jpeg, expectedBytes: 200_000, receivedBytes: 120_000)))
    observer(.init(.pairFileTransfer, .failed, failure: .connectionLost,
      pairFile: .init(role: .jpeg, expectedBytes: 200_000)))
    for _ in 0..<200 { observer(.init(.socketRead, .readCompleted, bytes: 16)) }
    observer(.init(.attempt, .failed, failure: .connectionLost))
    let attempts = try await read(file) { self.events($0[0]).last?["sequence"] as? Int == 207 }
    let attempt = try #require(attempts.first)
    #expect(events(attempt).count == 160)
    let pair = try #require(attempt["pairMilestones"] as? [String: [String: Any]])
    let transfer = pair["jpeg.pairFileTransfer.waiting"]?["event"] as? [String: Any]
    let progress = transfer?["pairFile"] as? [String: Any]
    #expect(progress?["receivedBytes"] as? Int == 120_000)
    #expect(pair["raf.pairControlRead.completed"] != nil)
    #expect(pair["raf.pairFileValidation.completed"] != nil)
    #expect(pair["jpeg.pairFileTransfer.failed"] != nil)
  }

  @Test func firstValidatedInventoryMilestonesSurviveReselectionAndOverflow() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let trace = ManualWiFiIdentityTrace(url: file)
    let observer = trace.begin(kind: .gallery)
    observer(.init(.galleryVersionValidation, .completed, galleryVersion: .version3))
    observer(.init(.galleryInitialInventory, .completed, gallerySlot: 2, galleryHandleCount: 1_227))
    observer(.init(.galleryFilteredInventory, .completed, gallerySlot: 2, galleryHandleCount: 1_155))
    observer(.init(.galleryInitialInventory, .completed, gallerySlot: 1, galleryHandleCount: .max))
    observer(.init(.galleryFilteredInventory, .completed, gallerySlot: 3, galleryHandleCount: 5))
    for _ in 0..<200 {
      observer(.init(.galleryInitialInventory, .completed, gallerySlot: 2, galleryHandleCount: 1_155))
      observer(.init(.galleryFilteredInventory, .completed, gallerySlot: 2, galleryHandleCount: 1_154))
    }
    observer(.init(.attempt, .completed))
    let attempts = try await read(file) { self.events($0[0]).last?["sequence"] as? Int == 407 }
    let milestones = try #require(attempts[0]["galleryInventoryMilestones"] as? [String: [String: Any]])
    #expect(milestones.count == 3)
    let version = milestones["galleryVersionValidation"]?["event"] as? [String: Any]
    #expect(version?["galleryVersion"] as? Int == 3)
    let initial = milestones["galleryInitialInventory.2"]?["event"] as? [String: Any]
    #expect(initial?["gallerySlot"] as? Int == 2)
    #expect(initial?["galleryHandleCount"] as? Int == 1_227)
    let filtered = milestones["galleryFilteredInventory.2"]?["event"] as? [String: Any]
    #expect(filtered?["galleryHandleCount"] as? Int == 1_155)
    #expect(filtered?["bytes"] == nil)
  }

  private func events(_ attempt: [String: Any]) -> [[String: Any]] {
    attempt["events"] as? [[String: Any]] ?? []
  }

  private func failure(_ attempt: [String: Any]) -> String? {
    let record = attempt["protocolFailure"] as? [String: Any]
    return (record?["event"] as? [String: Any])?["failure"] as? String
  }

  private func read(
    _ url: URL, matching: ([[String: Any]]) -> Bool
  ) async throws -> [[String: Any]] {
    let end = ContinuousClock.now + .seconds(3)
    repeat {
      if let data = try? Data(contentsOf: url),
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        matching(entries)
      {
        return entries
      }
      try await Task.sleep(for: .milliseconds(20))
    } while ContinuousClock.now < end
    throw CocoaError(.fileReadUnknown)
  }
}
#endif
