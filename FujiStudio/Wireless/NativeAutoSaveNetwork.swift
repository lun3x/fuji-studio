import Darwin
import Foundation
import FujiCameraCore
import Network
import os

/// Apple recommends BSD sockets for UDP broadcast. The worker owns the IPv4
/// sockets and binds them to the selected LAN interface.
enum NativeAutoSaveNetwork {
  struct Datagram {
    let data: Data
    let source: String
  }

  /// The search reached its deadline after a candidate failed. Preserve that
  /// cause even if the gateway's overall deadline raced the socket worker.
  struct SearchExhausted: Error {
    let lastFailure: WirelessFailure
  }

  private static let queue = DispatchQueue(label: "com.lun3x.FujiStudio.autosave")
  private static let pathQueue = DispatchQueue(label: "com.lun3x.FujiStudio.autosave.path")

  static func exchange(
    _ phase: AutoSaveCodec.Phase, _ importer: String, _ expectedName: String?,
    _ deadline: ContinuousClock.Instant
  ) async throws -> AutoSaveHandshake {
    let wifi = try await wifiInterface()
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let attempt = Exchange(
      phase: phase, interface: wifi, deadline: deadline, cancelled: cancelled)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        queue.async {
          continuation.resume(with: Result {
            try attempt.run(importer: importer, expectedName: expectedName)
          })
        }
      }
    } onCancel: {
      cancelled.withLock { $0 = true }
    }
  }

  private static func wifiInterface() async throws -> NWInterface {
    #if targetEnvironment(simulator)
    let monitor = NWPathMonitor()
    #else
    let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    #endif
    let (paths, handle) = AsyncStream<NWPath>.makeStream(bufferingPolicy: .bufferingNewest(1))
    monitor.pathUpdateHandler = { handle.yield($0) }
    monitor.start(queue: pathQueue)
    defer {
      monitor.cancel()
      handle.finish()
    }
    var iterator = paths.makeAsyncIterator()
    let path = await iterator.next()
    try Task.checkCancellation()
    if path?.status == .unsatisfied, path?.unsatisfiedReason == .localNetworkDenied {
      throw WirelessFailure.permissionDenied(.localNetwork)
    }
    guard let path, path.status == .satisfied else { throw WirelessFailure.routeUnavailable }
    if let wifi = path.availableInterfaces.first(where: { $0.type == .wifi }) { return wifi }
    #if targetEnvironment(simulator)
    if let ethernet = path.availableInterfaces.first(where: { $0.type == .wiredEthernet }) { return ethernet }
    #endif
    throw WirelessFailure.routeUnavailable
  }

  static func socketFailure(_ code: Int32, discoveredPeer: Bool) -> WirelessFailure {
    switch code {
    case EACCES, EPERM: return .permissionDenied(.localNetwork)
    case EADDRINUSE: return .cameraBusy
    case ENETDOWN, ENODEV, EADDRNOTAVAIL, EMFILE, ENFILE, ENOBUFS, ENOMEM: return .routeUnavailable
    case ENETUNREACH, EHOSTUNREACH, EHOSTDOWN, ECONNREFUSED, ETIMEDOUT:
      return discoveredPeer ? .autoSavePeerUnreachable : .routeUnavailable
    default: return .connectionLost
    }
  }

  static func findInvitation(
    phase: AutoSaveCodec.Phase, importer: String,
    receive: () throws -> Datagram,
    invite: (String) throws -> AutoSaveCodec.Invitation?
  ) throws -> AutoSaveHandshake {
    var lastFailure: WirelessFailure?
    while true {
      let datagram: Datagram
      do {
        datagram = try receive()
      } catch let failure as WirelessFailure {
        if case .timeout = failure, let lastFailure {
          throw SearchExhausted(lastFailure: lastFailure)
        }
        throw failure
      }
      guard let target = try? AutoSaveCodec.discovery(
        datagram.data, phase: phase, source: datagram.source),
        target == (phase == .registration ? "*" : importer)
      else { continue }
      do {
        if let invitation = try invite(datagram.source) {
          return AutoSaveHandshake(address: datagram.source, cameraName: invitation.cameraName)
        }
      } catch let failure as WirelessFailure {
        switch failure {
        case .autoSavePeerUnreachable, .authentication, .connectionLost, .malformedData:
          lastFailure = failure
        default:
          throw failure
        }
      }
    }
  }

  private struct Exchange: Sendable {
    let phase: AutoSaveCodec.Phase
    let interface: NWInterface
    let deadline: ContinuousClock.Instant
    let cancelled: OSAllocatedUnfairLock<Bool>

    private var clock: ContinuousClock { ContinuousClock() }

    func run(importer: String, expectedName: String?) throws -> AutoSaveHandshake {
      let subnet = try localSubnet()
      let udp = try openSocket(SOCK_DGRAM)
      defer { Darwin.close(udp) }
      try bind(udp, to: socketAddress(port: phase.port))

      return try findInvitation(phase: phase, importer: importer) {
        while true {
          let (data, address) = try receiveDatagram(udp)
          if subnet.contains(address.sin_addr), let source = addressString(address.sin_addr) {
            return Datagram(data: data, source: source)
          }
        }
      } invite: { source in
        let listener = try invitationListener()
        defer { Darwin.close(listener) }
        var peer = in_addr()
        guard source.withCString({ inet_pton(AF_INET, $0, &peer) }) == 1 else {
          throw WirelessFailure.malformedData
        }
        try notify(address: source, importer: importer)
        return try acceptInvitation(listener, from: peer, subnet: subnet, expectedName: expectedName)
      }
    }

    private func invitationListener() throws -> Int32 {
      do {
        let fd = try openSocket(SOCK_STREAM)
        do {
          try option(fd, level: SOL_SOCKET, name: SO_REUSEADDR, value: Int32(1))
          try bind(fd, to: socketAddress(port: phase.port))
          guard listen(fd, 4) == 0 else { throw socketFailure(errno, discoveredPeer: false) }
        } catch {
          Darwin.close(fd)
          throw error
        }
        return fd
      } catch WirelessFailure.connectionLost {
        // A local listener failure cannot be resolved by another camera.
        throw WirelessFailure.routeUnavailable
      }
    }

    private func notify(address: String, importer: String) throws {
      let fd = try openSocket(SOCK_STREAM)
      defer { Darwin.close(fd) }
      var peer = socketAddress(port: AutoSaveCodec.notifyPort)
      guard address.withCString({ inet_pton(AF_INET, $0, &peer.sin_addr) }) == 1 else {
        throw WirelessFailure.malformedData
      }
      let limit = min(deadline, clock.now + .seconds(5))
      if withAddress(&peer, { connect(fd, $0, $1) }) != 0 {
        let code = errno
        guard code == EINPROGRESS else { throw socketFailure(code, discoveredPeer: true) }
        try ready(fd, events: Int16(POLLOUT), until: limit, discoveredPeer: true)
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
          throw socketFailure(errno, discoveredPeer: true)
        }
        guard error == 0 else { throw socketFailure(error, discoveredPeer: true) }
      }
      try sendAll(AutoSaveCodec.notify(address: address, importer: importer) + Data("\r\n".utf8), to: fd, until: limit)
      _ = try readMessage(fd, until: limit) { try AutoSaveCodec.notifyAcknowledged($0) ? true : nil }
    }

    private func acceptInvitation(
      _ listener: Int32, from source: in_addr, subnet: Subnet, expectedName: String?
    ) throws -> AutoSaveCodec.Invitation? {
      // The pinned invite wait is 30 seconds. The current attempt also has a shared deadline.
      let limit = min(deadline, clock.now + .seconds(30))
      while true {
        try ready(listener, events: Int16(POLLIN), until: limit, discoveredPeer: true)
        var remote = sockaddr_in()
        let fd = readAddress(&remote) { accept(listener, $0, &$1) }
        if fd < 0 {
          let code = errno
          if code == EAGAIN || code == EINTR { continue }
          throw socketFailure(code, discoveredPeer: true)
        }
        defer { Darwin.close(fd) }
        guard remote.sin_family == sa_family_t(AF_INET), remote.sin_addr.s_addr == source.s_addr else {
          continue
        }
        try configure(fd, type: SOCK_STREAM)
        var local = sockaddr_in()
        guard readAddress(&local, { getsockname(fd, $0, &$1) }) == 0,
          local.sin_addr.s_addr == subnet.address.s_addr,
          let receiver = addressString(local.sin_addr)
        else { throw WirelessFailure.routeUnavailable }
        let messageLimit = min(limit, clock.now + .seconds(5))
        let invitation = try readMessage(fd, until: messageLimit) {
          try AutoSaveCodec.invitation($0, phase: phase, localAddress: receiver)
        }
        guard phase != .registration || invitation.cameraModel == WirelessCameraModel.xe3.rawValue,
          expectedName == nil || invitation.cameraName == expectedName
        else { return nil }
        try sendAll(AutoSaveCodec.response(to: phase) + Data("\r\n".utf8), to: fd, until: messageLimit)
        return invitation
      }
    }

    private func receiveDatagram(_ fd: Int32) throws -> (Data, sockaddr_in) {
      let capacity = AutoSaveCodec.maximumMessageBytes + 1
      var buffer = [UInt8](repeating: 0, count: capacity)
      while true {
        try ready(fd, events: Int16(POLLIN), until: deadline, discoveredPeer: false)
        var address = sockaddr_in()
        let count = readAddress(&address) { recvfrom(fd, &buffer, capacity, 0, $0, &$1) }
        if count < 0 {
          let code = errno
          if code == EAGAIN || code == EINTR { continue }
          throw socketFailure(code, discoveredPeer: false)
        }
        guard address.sin_family == sa_family_t(AF_INET) else { continue }
        // Extra byte detects truncation, including a prefix that might otherwise parse.
        if count > AutoSaveCodec.maximumMessageBytes { continue }
        return (Data(buffer.prefix(count)), address)
      }
    }

    private func readMessage<Value>(
      _ fd: Int32, until limit: ContinuousClock.Instant, parse: (Data) throws -> Value?
    ) throws -> Value {
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: AutoSaveCodec.maximumMessageBytes + 1)
      while true {
        try ready(fd, events: Int16(POLLIN), until: limit, discoveredPeer: true)
        let remaining = buffer.count - bytes.count
        let count = recv(fd, &buffer, remaining, 0)
        if count < 0 {
          let code = errno
          if code == EAGAIN || code == EINTR { continue }
          throw socketFailure(code, discoveredPeer: true)
        }
        guard count > 0, bytes.count + count <= AutoSaveCodec.maximumMessageBytes else {
          throw WirelessFailure.malformedData
        }
        bytes.append(contentsOf: buffer.prefix(count))
        if let message = try parse(bytes) { return message }
      }
    }

    private func sendAll(_ bytes: Data, to fd: Int32, until limit: ContinuousClock.Instant) throws {
      try bytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { throw WirelessFailure.malformedData }
        var sent = 0
        while sent < buffer.count {
          try ready(fd, events: Int16(POLLOUT), until: limit, discoveredPeer: true)
          let count = send(fd, base.advanced(by: sent), buffer.count - sent, 0)
          if count < 0 {
            let code = errno
            if code == EAGAIN || code == EINTR { continue }
            throw socketFailure(code, discoveredPeer: true)
          }
          guard count > 0 else { throw WirelessFailure.connectionLost }
          sent += count
        }
      }
    }

    private func ready(
      _ fd: Int32, events: Int16, until limit: ContinuousClock.Instant, discoveredPeer: Bool
    ) throws {
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      while true {
        let remaining = clock.now.duration(to: limit)
        guard remaining > .zero else {
          if discoveredPeer { throw WirelessFailure.autoSavePeerUnreachable }
          throw WirelessFailure.timeout(phase == .registration ? .autoSaveRegistration : .autoSaveSession)
        }
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        let parts = remaining.components
        let milliseconds = parts.seconds > 0 ? 100 : min(100, parts.attoseconds / 1_000_000_000_000_000 + 1)
        let count = poll(&descriptor, 1, Int32(milliseconds))
        if count < 0 {
          let code = errno
          if code == EINTR { continue }
          throw socketFailure(code, discoveredPeer: discoveredPeer)
        }
        if count > 0 {
          if clock.now >= limit || cancelled.withLock({ $0 }) { continue }
          return
        }
      }
    }

    private func openSocket(_ type: Int32) throws -> Int32 {
      let fd = socket(AF_INET, type, 0)
      guard fd >= 0 else { throw socketFailure(errno, discoveredPeer: false) }
      do {
        try configure(fd, type: type)
        try option(fd, level: IPPROTO_IP, name: IP_BOUND_IF, value: Int32(interface.index))
      } catch {
        Darwin.close(fd)
        throw error
      }
      return fd
    }

    private func configure(_ fd: Int32, type: Int32) throws {
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw socketFailure(errno, discoveredPeer: false)
      }
      if type == SOCK_STREAM {
        try option(fd, level: SOL_SOCKET, name: SO_NOSIGPIPE, value: Int32(1))
      }
    }

    private func option(_ fd: Int32, level: Int32, name: Int32, value: Int32) throws {
      var value = value
      guard setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw socketFailure(errno, discoveredPeer: false)
      }
    }

    private func bind(_ fd: Int32, to address: sockaddr_in) throws {
      var address = address
      guard withAddress(&address, { Darwin.bind(fd, $0, $1) }) == 0 else {
        throw socketFailure(errno, discoveredPeer: false)
      }
    }

    private func localSubnet() throws -> Subnet {
      var interfaces: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&interfaces) == 0, let first = interfaces else {
        throw WirelessFailure.routeUnavailable
      }
      defer { freeifaddrs(first) }
      var item: UnsafeMutablePointer<ifaddrs>? = first
      while let entry = item?.pointee {
        item = entry.ifa_next
        guard String(cString: entry.ifa_name) == interface.name,
          let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
          let mask = entry.ifa_netmask else { continue }
        let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        if netmask.s_addr != 0 { return Subnet(address: local, mask: netmask) }
      }
      throw WirelessFailure.routeUnavailable
    }
  }

  private struct Subnet {
    let address: in_addr
    let mask: in_addr

    func contains(_ peer: in_addr) -> Bool {
      let local = address.s_addr
      let subnet = local & mask.s_addr
      let received = peer.s_addr
      return received & mask.s_addr == subnet && received != local
        && received != subnet && received != (subnet | ~mask.s_addr)
    }
  }

  private static func socketAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    return address
  }

  private static func addressString(_ peer: in_addr) -> String? {
    var peer = peer
    var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &peer, &output, socklen_t(output.count)) != nil else { return nil }
    return String(decoding: output.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  private static func withAddress<Value>(
    _ address: inout sockaddr_in, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> Value
  ) -> Value {
    withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        operation($0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }

  private static func readAddress<Value>(
    _ address: inout sockaddr_in, _ operation: (UnsafeMutablePointer<sockaddr>, inout socklen_t) -> Value
  ) -> Value {
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    return withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, &length) }
    }
  }
}
