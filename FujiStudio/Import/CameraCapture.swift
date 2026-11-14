import CryptoKit
import Foundation
import FujiCameraCore

struct CameraCaptureID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    /// This is a candidate identity. Identical evidence can describe more than one object.
    init(describing objects: [WirelessObjectDescriptor]) {
        // Length framing distinguishes missing evidence, empty fields and embedded delimiters.
        var evidence = Data("FujiStudio:CameraCapture:1".utf8)
        func append(_ value: String?) {
            guard let value else {
                evidence.append(0)
                return
            }
            evidence.append(1)
            var size = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &size) { evidence.append(contentsOf: $0) }
            evidence.append(contentsOf: value.utf8)
        }
        for object in objects {
            append(object.cameraID.rawValue.uuidString)
            append(String(object.storageID))
            append(object.reportedStorageID.map(String.init))
            append(CameraCaptureEvidence.directory(object.directory))
            append(CameraCaptureEvidence.filename(object.filename))
            switch object.format {
            case .raf: append("raf")
            case .jpeg: append("jpeg")
            case .other(let code): append("other-\(code)")
            }
            append(String(object.byteLength))
            if let timestamp = CameraCaptureTimestamp(object.captureDate) {
                append(timestamp.wallTime + (timestamp.offset ?? ""))
            } else {
                append(object.captureDate)
            }
            append(object.dimensions.map { "\($0.width)x\($0.height)" })
            append(object.orientation.map(String.init))
        }
        rawValue = SHA256.hash(data: evidence).map { String(format: "%02x", $0) }.joined()
    }

    init(rawValue: String) { self.rawValue = rawValue }
}

enum CaptureAvailability: Equatable, Sendable {
    case checking
    case pair
    case rawOnly
    case jpegOnly
    case rawUnavailable
    case ambiguous
    case unsupported
}

struct CameraCapture: Equatable, Sendable {
    let id: CameraCaptureID
    private(set) var availability: CaptureAvailability
    private let anchor: WirelessObjectDescriptor
    private let mate: WirelessObjectDescriptor?
    let timestamp: CameraCaptureTimestamp?

    var objects: [WirelessObjectDescriptor] { mate.map { [anchor, $0] } ?? [anchor] }
    var captureDate: String? { anchor.captureDate }
    var cameraID: WirelessCameraID { anchor.cameraID }
    var raw: WirelessObjectDescriptor? { anchor.format == .raf ? anchor : nil }
    var jpeg: WirelessObjectDescriptor? { anchor.format == .jpeg ? anchor : mate }
    var thumbnailObject: WirelessObjectDescriptor? {
        if let jpeg, jpeg.hasThumbnail { return jpeg }
        return anchor.hasThumbnail ? anchor : nil
    }

    /// Session-scoped presentation identity, including the anchor route for duplicate digests.
    var rowID: WirelessObjectDescriptor { anchor }

    init(anchor: WirelessObjectDescriptor, mate: WirelessObjectDescriptor? = nil,
         availability: CaptureAvailability) {
        self.anchor = anchor
        self.mate = mate
        self.availability = availability
        self.timestamp = CameraCaptureTimestamp(anchor.captureDate)
        self.id = CameraCaptureID(describing: mate.map { [anchor, $0] } ?? [anchor])
    }

    func withAvailability(_ availability: CaptureAvailability) -> Self {
        var capture = self
        capture.availability = availability
        return capture
    }

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsTime = lhs.timestamp?.wallTime
        let rhsTime = rhs.timestamp?.wallTime
        if lhsTime != rhsTime { return (lhsTime ?? "") > (rhsTime ?? "") }
        if lhs.id != rhs.id { return lhs.id.rawValue < rhs.id.rawValue }
        if lhs.anchor.sessionID != rhs.anchor.sessionID {
            return lhs.anchor.sessionID.uuidString < rhs.anchor.sessionID.uuidString
        }
        if lhs.anchor.storageID != rhs.anchor.storageID { return lhs.anchor.storageID < rhs.anchor.storageID }
        if lhs.anchor.handle != rhs.anchor.handle { return lhs.anchor.handle < rhs.anchor.handle }
        if lhs.anchor.filename != rhs.anchor.filename { return lhs.anchor.filename < rhs.anchor.filename }
        if lhs.anchor.directory != rhs.anchor.directory {
            return (lhs.anchor.directory ?? "") < (rhs.anchor.directory ?? "")
        }
        if lhs.captureDate != rhs.captureDate { return (lhs.captureDate ?? "") < (rhs.captureDate ?? "") }
        return lhs.anchor.hasThumbnail && !rhs.anchor.hasThumbnail
    }
}

enum ImportPolicy: String, Codable, Equatable, Sendable {
    case pair
    case rawOnly
}

struct ImportSelection: Equatable, Sendable {
    let captureID: CameraCaptureID
    let camera: WirelessIdentity
    let descriptors: [WirelessObjectDescriptor]
    let policy: ImportPolicy
}

enum CameraCaptureEvidence {
    static func filename(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func directory(_ value: String?) -> String? {
        guard let value else { return nil }
        let components = value.split { $0 == "/" || $0 == "\\" }
        return components.isEmpty ? nil : filename(components.joined(separator: "/"))
    }

    static func stem(_ object: WirelessObjectDescriptor) -> String? {
        let filename = filename(object.filename)
        guard let extensionStart = filename.lastIndex(of: "."), extensionStart > filename.startIndex else {
            return nil
        }
        let suffix = filename[filename.index(after: extensionStart)...]
        switch object.format {
        case .raf where suffix == "raf", .jpeg where suffix == "jpg" || suffix == "jpeg":
            return String(filename[..<extensionStart])
        default:
            return nil
        }
    }
}

/// Ordering uses the camera's reported wall time. An absent offset remains absent and
/// never participates in evidence matching as if it were an explicit offset.
struct CameraCaptureTimestamp: Hashable, Sendable {
    let wallTime: String
    let offset: String?

    init?(_ value: String?) {
        guard let value,
              let match = value.wholeMatch(
                of: /([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})(?:\.([0-9]+))?(Z|[+-][0-9]{4})?/
              ),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6),
              year > 0, (1...12).contains(month), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second)
        else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        let fraction = match.7.map { String($0.reversed().drop(while: { $0 == "0" }).reversed()) } ?? ""
        wallTime = String(value.prefix(15)) + (fraction.isEmpty ? "" : ".\(fraction)")
        switch match.8 {
        case nil: offset = nil
        case "Z", "+0000": offset = "Z"
        case let zone?:
            guard let hours = Int(zone.dropFirst().prefix(2)), hours <= 23,
                  let minutes = Int(zone.suffix(2)), minutes <= 59 else { return nil }
            offset = String(zone)
        }
    }
}
