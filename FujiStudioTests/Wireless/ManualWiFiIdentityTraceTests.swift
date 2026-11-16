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
