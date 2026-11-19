import Foundation
import FujiCameraCore
import ImageIO
import UniformTypeIdentifiers

enum OriginalImportError: Error, Equatable, Sendable {
    case invalidSelection, captureMismatch
    case validation(WirelessIdentityTrace.ValidationCheck)
}

struct OriginalImportValidator: Sendable {
    let staging: ImportStagingStore

    func validate(_ selection: ImportSelection, originals: [StagedOriginal], importDate: Date) throws -> ValidatedCapture {
        try selection.validateForOriginalImport()
        guard originals.count == selection.descriptors.count,
              Set(originals.map(\.relativePath)).count == originals.count else { throw OriginalImportError.captureMismatch }
        let ordered = try selection.descriptors.map { object in
            guard let original = originals.first(where: { $0.describes(object) }) else {
                throw OriginalImportError.captureMismatch
            }
            try staging.checkIntegrity(original)
            let file = try staging.fileURL(for: original)
            let current = try Self.inspect(file: file, object: object, transferMode: original.verifiedTransferMode)
            guard current == original.metadata, current.cameraModel == selection.camera.model.rawValue else {
                throw OriginalImportError.captureMismatch
            }
            return original
        }
        if ordered.count == 2 {
            try Self.checkPair(ordered[0].metadata, ordered[1].metadata)
        }

        return .init(selection: selection, originals: ordered,
                     metadata: Self.photoMetadata(selection, originals: ordered, importDate: importDate))
    }

    /// Recovery can compare the metadata originally assigned to Photos without reading
    /// or hashing the retained files again. This does not establish a verified receipt.
    static func photoMetadata(_ selection: ImportSelection, originals: [StagedOriginal],
                              importDate: Date) -> ImportCaptureMetadata {
        let embedded = originals.compactMap { Self.embeddedTimestamp($0.metadata) }
        let reported = selection.descriptors.compactMap { CameraCaptureTimestamp($0.captureDate) }
        let resolvedDate: Date
        let source: ImportCaptureMetadata.DateSource
        if let date = embedded.compactMap(\.absoluteDate).first {
            (resolvedDate, source) = (date, .embedded)
        } else if let date = reported.compactMap({ selection.camera.model == .xt5 ? $0.xT5Date : $0.absoluteDate }).first {
            (resolvedDate, source) = (date, .objectInfo)
        } else {
            (resolvedDate, source) = (importDate, embedded.isEmpty && reported.isEmpty
                                      ? .importTimeMissingDate : .importTimeMissingOffset)
        }
        return .init(creationDate: resolvedDate, dateSource: source,
                     location: originals.compactMap { $0.metadata.location }.first)
    }

    /// Reads only headers/metadata; never decodes raw pixels or rewrites camera bytes.
    static func inspect(file: URL, object: WirelessObjectDescriptor,
                        transferMode: WirelessMode? = nil) throws -> OriginalImportMetadata {
        let properties: [String: Any]
        let dimensions: PixelSize
        let orientation: Int
        let model: String
        switch object.format {
        case .raf:
            let raw = try RAFMetadataReader().metadata(inFileAt: file)
            properties = raw.embeddedJPEGProperties
            dimensions = raw.metadata.recordedGeometry
            orientation = raw.metadata.orientation
            model = raw.metadata.cameraModel
            // ObjectInfo can describe either the visible frame or the full sensor container.
            let omitsDimensions = transferMode == .autoSave && model == WirelessCameraModel.xe3.rawValue
                && object.dimensions == nil
            guard omitsDimensions || object.dimensions == dimensions || object.dimensions == raw.metadata.containerGeometry else {
                throw OriginalImportError.validation(.dimensions(
                    reported: object.dimensions, recorded: dimensions, container: raw.metadata.containerGeometry))
            }
        case .jpeg:
            properties = try jpegProperties(file: file, length: object.byteLength)
            guard let width = integer(properties[kCGImagePropertyPixelWidth as String]), width > 0,
                  let height = integer(properties[kCGImagePropertyPixelHeight as String]), height > 0,
                  let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
                  let modelValue = tiff[kCGImagePropertyTIFFModel as String] as? String else {
                throw OriginalImportError.validation(.jpegMetadata)
            }
            dimensions = .init(width: width, height: height)
            orientation = integer(properties[kCGImagePropertyOrientation as String]) ?? 1
            model = modelValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard object.dimensions == dimensions else {
                throw OriginalImportError.validation(.dimensions(
                    reported: object.dimensions, recorded: dimensions, container: nil))
            }
        case .other: throw ImportStagingError.unsupportedFormat
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // RAF's container also carries the model. For a standalone JPEG require its Fuji make.
        guard !model.isEmpty else { throw OriginalImportError.validation(.cameraModel) }
        guard make == "FUJIFILM" || (make == nil && object.format == .raf) else {
            throw OriginalImportError.validation(.cameraMake)
        }
        guard (1...8).contains(orientation) else { throw OriginalImportError.validation(.orientationRange) }
        if let reported = object.orientation, reported != orientation {
            throw OriginalImportError.validation(.orientation(reported: reported, embedded: orientation))
        }
        let timestamp = exifTimestamp(properties)
        return .init(cameraModel: model, dimensions: dimensions, orientation: orientation,
                     captureWallTime: timestamp?.wallTime, captureOffset: timestamp?.offset,
                     location: gpsLocation(properties))
    }

    private static func jpegProperties(file: URL, length: UInt64) throws -> [String: Any] {
        guard length > 4 else { throw OriginalImportError.validation(.jpegStructure) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 2) == Data([0xff, 0xd8]) else {
            throw OriginalImportError.validation(.jpegStructure)
        }
        try handle.seek(toOffset: length - 2)
        guard try handle.read(upToCount: 2) == Data([0xff, 0xd9]),
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw OriginalImportError.validation(.jpegStructure)
        }
        return properties
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber else { return nil }
        return Int(exactly: value.doubleValue)
    }

    private static func embeddedTimestamp(_ metadata: OriginalImportMetadata) -> CameraCaptureTimestamp? {
        metadata.captureWallTime.flatMap { CameraCaptureTimestamp($0 + (metadata.captureOffset ?? "")) }
    }

    private static func exifTimestamp(_ properties: [String: Any]) -> CameraCaptureTimestamp? {
        guard let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
              let match = date.wholeMatch(of: /([0-9]{4}):([0-9]{2}):([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})/)
        else { return nil }
        var wallTime = "\(match.1)\(match.2)\(match.3)T\(match.4)\(match.5)\(match.6)"
        if let fraction = exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
           fraction.wholeMatch(of: /[0-9]{1,9}/) != nil {
            wallTime += "." + fraction
        }
        if let zone = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
           zone.wholeMatch(of: /[+-][0-9]{2}:[0-9]{2}/) != nil,
           let timestamp = CameraCaptureTimestamp(wallTime + zone.replacingOccurrences(of: ":", with: "")) {
            return timestamp
        }
        return CameraCaptureTimestamp(wallTime)
    }

    private static func gpsLocation(_ properties: [String: Any]) -> ImportLocation? {
        guard let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let lat = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
              let lon = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue,
              let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String, ["N", "S"].contains(latRef),
              let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String, ["E", "W"].contains(lonRef),
              (0...90).contains(abs(lat)), (0...180).contains(abs(lon)) else { return nil }
        var altitude: Double?
        if let value = (gps[kCGImagePropertyGPSAltitude as String] as? NSNumber)?.doubleValue, value.isFinite,
           let altitudeRef = integer(gps[kCGImagePropertyGPSAltitudeRef as String]), [0, 1].contains(altitudeRef) {
            altitude = altitudeRef == 1 ? -abs(value) : abs(value)
        }
        return .init(latitude: latRef == "S" ? -abs(lat) : abs(lat),
                     longitude: lonRef == "W" ? -abs(lon) : abs(lon), altitude: altitude)
    }

    #if DEBUG
    static func checkDiagnosticCaptureTime(_ metadata: OriginalImportMetadata,
                                           object: WirelessObjectDescriptor) throws {
        guard var reported = CameraCaptureTimestamp(object.captureDate) else {
            throw OriginalImportError.validation(.objectInfoCaptureTimeMissingOrInvalid)
        }
        guard let embedded = embeddedTimestamp(metadata) else {
            throw OriginalImportError.validation(.embeddedCaptureTimeMissingOrInvalid)
        }
        // X-T5 Wi-Fi ObjectInfo reports UTC without a suffix. EXIF retains the camera's local offset.
        if reported.offset == nil, embedded.offset != nil {
            guard let utc = CameraCaptureTimestamp(reported.wallTime + "Z") else {
                throw OriginalImportError.validation(.objectInfoCaptureTimeMissingOrInvalid)
            }
            reported = utc
        }
        guard reported.agreesForCapture(with: embedded) else {
            throw OriginalImportError.validation(.captureTimeMismatch)
        }
    }
    #endif

    static func checkPair(_ raw: OriginalImportMetadata, _ jpeg: OriginalImportMetadata) throws {
        guard raw.orientation == jpeg.orientation else { throw OriginalImportError.validation(.pairOrientation) }
        if let rawTime = embeddedTimestamp(raw), let jpegTime = embeddedTimestamp(jpeg),
           !rawTime.agreesForCapture(with: jpegTime) {
            throw OriginalImportError.validation(.pairCaptureTime)
        }
        if let a = raw.location, let b = jpeg.location {
            guard abs(a.latitude - b.latitude) < 0.00001, abs(a.longitude - b.longitude) < 0.00001 else {
                throw OriginalImportError.validation(.pairLocation)
            }
        }
    }
}

extension CameraCaptureTimestamp {
    /// Unsuffixed X-T5 gallery ObjectInfo is UTC.
    var xT5Date: Date? {
        offset == nil ? CameraCaptureTimestamp(wallTime + "Z")?.absoluteDate : absoluteDate
    }

    func agreesForCapture(with other: Self) -> Bool {
        if let first = absoluteDate, let second = other.absoluteDate {
            return abs(first.timeIntervalSince(second)) < 1
        }
        return wallTime.prefix(15) == other.wallTime.prefix(15)
    }

    var absoluteDate: Date? {
        // A wall clock without a reliable offset cannot be converted to an absolute date.
        guard let offset, offset != "-0000" else { return nil }
        let bytes = Array(wallTime.utf8)
        func number(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = DateComponents(year: number(0..<4), month: number(4..<6), day: number(6..<8),
                                   hour: number(9..<11), minute: number(11..<13), second: number(13..<15))
        guard let date = calendar.date(from: parts) else { return nil }
        let fraction = bytes.count > 15 ? (Double("0." + String(wallTime.dropFirst(16).prefix(9))) ?? 0) : 0
        let hours = Int(offset.dropFirst().prefix(2)) ?? 0
        let minutes = Int(offset.suffix(2)) ?? 0
        let offsetSeconds = Double(hours * 3600 + minutes * 60) * (offset.hasPrefix("-") ? -1 : 1)
        return date.addingTimeInterval(fraction - offsetSeconds)
    }
}
