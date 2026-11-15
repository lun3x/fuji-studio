import Darwin
import Foundation

/// The child owns synchronous CoreWLAN work. A caller resumes only after the child is reaped.
@MainActor
final class ProbeWiFiWorkerProcess {
  nonisolated static let maximumBytes = 2_048

  private var process: Process?
  private var operationID: UUID?
  private var continuation: CheckedContinuation<Data, any Error>?
  private var output: FileHandle?
  private var deadline: Task<Void, Never>?
  private var interruption: (any Error)?

  func run(
    executable: URL, arguments: [String], input: Data, timeout: Duration, discardOutput: Bool = false
  ) async throws -> Data {
    guard process == nil, input.count <= Self.maximumBytes else {
      throw ProbeWiFiWorkerFailure.invalidWorkerRequest
    }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        start(id: id, executable: executable, arguments: arguments, input: input,
          timeout: timeout, discardOutput: discardOutput, continuation: continuation)
      }
    } onCancel: {
      Task { @MainActor in self.interrupt(id, CancellationError()) }
    }
  }

  private func start(
    id: UUID, executable: URL, arguments: [String], input: Data, timeout: Duration, discardOutput: Bool,
    continuation: CheckedContinuation<Data, any Error>
  ) {
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let child = Process()
    child.executableURL = executable
    child.arguments = arguments
    child.environment = [:]
    child.standardInput = inputPipe
    child.standardOutput = discardOutput ? FileHandle.nullDevice : outputPipe
    child.standardError = FileHandle.nullDevice
    child.terminationHandler = { [weak self] process in
      let status = process.terminationStatus
      Task { @MainActor in self?.receiveExit(id, status: status) }
    }

    // Fill the bounded anonymous pipe before spawning. Its unread end is still open,
    // avoiding SIGPIPE if a child immediately refuses to start.
    do {
      try inputPipe.fileHandleForWriting.write(contentsOf: input)
      try inputPipe.fileHandleForWriting.close()
      try child.run()
    } catch {
      continuation.resume(throwing: ProbeWiFiWorkerFailure.workerUnavailable)
      return
    }

    process = child
    operationID = id
    self.continuation = continuation
    output = discardOutput ? nil : outputPipe.fileHandleForReading
    try? inputPipe.fileHandleForReading.close()
    try? outputPipe.fileHandleForWriting.close()
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      self?.interrupt(id, ProbeWiFiWorkerFailure.workerTimedOut)
    }
  }

  private func interrupt(_ id: UUID, _ failure: any Error) {
    guard operationID == id, let process, interruption == nil else { return }
    interruption = failure
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
  }

  private func receiveExit(_ id: UUID, status: Int32) {
    guard operationID == id, let continuation else { return }
    defer {
      try? output?.close()
      self.continuation = nil
      self.output = nil
      deadline?.cancel()
      deadline = nil
      process = nil
      operationID = nil
      interruption = nil
    }
    if let interruption {
      continuation.resume(throwing: interruption)
    } else if status == 0 {
      if let output {
        do { continuation.resume(returning: try Self.readBounded(from: output)) }
        catch { continuation.resume(throwing: ProbeWiFiWorkerFailure.invalidWorkerResponse) }
      } else {
        continuation.resume(returning: Data())
      }
    } else {
      continuation.resume(throwing: ProbeWiFiWorkerFailure.invalidWorkerResponse)
    }
  }

  nonisolated static func readBounded(from handle: FileHandle) throws -> Data {
    var data = Data()
    while let chunk = try handle.read(upToCount: maximumBytes + 1 - data.count), !chunk.isEmpty {
      data.append(chunk)
      guard data.count <= maximumBytes else { throw ProbeWiFiWorkerFailure.invalidWorkerResponse }
    }
    return data
  }
}
