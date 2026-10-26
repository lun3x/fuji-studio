import Foundation
import CryptoKit

/// Standard PTP grammar only. Vendor look mappings require observed X-T5 fixtures.
enum XT5ProtocolError: Error, Sendable, Equatable {
    case truncated, oversized, trailingBytes, invalidString, wrongProperty, invalidAccess, invalidForm
    case unsupportedDataType(UInt16)
    case unsupportedCamera, missingReadOperations
}

struct XT5DeviceInfo: Sendable, Equatable {
    let standardVersion: UInt16
    let vendorExtensionID: UInt32
    let vendorExtensionVersion: UInt16
    let functionalMode: UInt16
    let operations: [UInt16]
    let events: [UInt16]
    let properties: [UInt16]
    let captureFormats: [UInt16]
    let imageFormats: [UInt16]
    let manufacturer: String
    let model: String
    let firmware: String
    // Serial number and vendor description are deliberately discarded at the parser boundary.
}

struct XT5PropertyValue: Sendable, Equatable {
    let raw: Data
    let string: String?
    /// Callers must establish an unsigned scalar data type before interpreting these bits.
    var unsignedInteger: UInt64? {
        guard string == nil, [1,2,4,8].contains(raw.count) else { return nil }
        return raw.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
}

enum XT5PropertyForm: Sendable, Equatable {
    case none
    case range(minimum: XT5PropertyValue, maximum: XT5PropertyValue, step: XT5PropertyValue)
    case enumeration([XT5PropertyValue])
}

struct XT5PropertyDescriptor: Sendable, Equatable {
    let code: UInt16
    let dataType: UInt16
    let writable: Bool
    let factoryDefault: XT5PropertyValue
    let current: XT5PropertyValue
    let form: XT5PropertyForm
}

enum XT5RecipeCodec {
    static func recipe(slot: Int, nameData: Data, properties: [UInt16: Data], context: RecipeCameraContext, importedAt: Date) throws -> RecipeSnapshot {
        guard (1...7).contains(slot) else { throw RecipeImportError.invalidSlot }
        let codes = Array(UInt16(0xD18E)...0xD1A4)
        guard Set(properties.keys) == Set(codes) else { throw RecipeImportError.incompletePropertyBlock }
        guard let name = try value(nameData, type: 0xffff).string else { throw XT5ProtocolError.invalidString }
        var imported: [ImportedRecipeProperty] = []
        var canonical = Data("xt5.imported-settings.v1\0".utf8)
        var issues: [RecipeRenderingIssue] = [.conversionProfileUnvalidated]
        for code in codes {
            guard let raw = properties[code], raw.count == 2 else { throw RecipeImportError.malformedProperty(code) }
            imported.append(ImportedRecipeProperty(code: code, raw: raw))
            canonical.append(contentsOf: [UInt8(truncatingIfNeeded: code), UInt8(code >> 8), 2, 0])
            canonical.append(raw)
            let word = UInt16(raw[raw.startIndex]) | UInt16(raw[raw.startIndex + 1]) << 8
            if [0xD18E,0xD18F,0xD1A3,0xD1A4].contains(code) { issues.append(.unmappedProperty(code)) }
            // Explicit unresolved observations, not approximate film/grain mappings. Other fields
            // remain blocked by conversionProfileUnvalidated until the whole profile is validated.
            if (code == 0xD192 && !(1...20).contains(word)) || (code == 0xD195 && !(1...6).contains(word)) {
                issues.append(.unsupportedValue(code))
            }
        }
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return RecipeSnapshot(id: UUID(), slot: slot, name: name, importedName: nameData, importedSettings: imported,
                              settingsDigest: digest, cameraContext: context, importedAt: importedAt, renderingIssues: issues)
    }

    static func deviceInfo(_ data: Data) throws -> XT5DeviceInfo {
        var reader = try Reader(data)
        let standard = try reader.u16(), vendor = try reader.u32(), version = try reader.u16()
        _ = try reader.string()
        let mode = try reader.u16()
        let operations = try reader.words(), events = try reader.words(), properties = try reader.words()
        let capture = try reader.words(), images = try reader.words()
        let manufacturer = try reader.string(), model = try reader.string(), firmware = try reader.string()
        _ = try reader.string() // Do not retain serial, including in debug descriptions.
        try reader.finish()
        return XT5DeviceInfo(standardVersion: standard, vendorExtensionID: vendor, vendorExtensionVersion: version,
                             functionalMode: mode, operations: operations, events: events, properties: properties,
                             captureFormats: capture, imageFormats: images, manufacturer: manufacturer, model: model, firmware: firmware)
    }

    static func propertyDescriptor(_ data: Data, expectedCode: UInt16) throws -> XT5PropertyDescriptor {
        var reader = try Reader(data)
        let code = try reader.u16(), type = try reader.u16(), access = try reader.u8()
        guard code == expectedCode else { throw XT5ProtocolError.wrongProperty }
        guard access <= 1 else { throw XT5ProtocolError.invalidAccess }
        let factory = try reader.value(type), current = try reader.value(type)
        let form: XT5PropertyForm
        switch try reader.u8() {
        case 0: form = .none
        case 1:
            guard (1...10).contains(type) else { throw XT5ProtocolError.invalidForm }
            form = try .range(minimum: reader.value(type), maximum: reader.value(type), step: reader.value(type))
        case 2:
            let count = Int(try reader.u16())
            guard count <= 4096 else { throw XT5ProtocolError.oversized }
            var values: [XT5PropertyValue] = []
            for _ in 0..<count { values.append(try reader.value(type)) }
            form = .enumeration(values)
        default: throw XT5ProtocolError.invalidForm
        }
        try reader.finish()
        return XT5PropertyDescriptor(code: code, dataType: type, writable: access == 1, factoryDefault: factory, current: current, form: form)
    }

    static func value(_ data: Data, type: UInt16) throws -> XT5PropertyValue {
        var reader = try Reader(data)
        let value = try reader.value(type)
        try reader.finish()
        return value
    }

    private struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) throws {
            guard data.count <= 65_536 else { throw XT5ProtocolError.oversized }
            self.data = Data(data) // Normalize slices to zero-based indices.
        }
        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw XT5ProtocolError.truncated }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 { let b = try bytes(2); return UInt16(b[0]) | UInt16(b[1]) << 8 }
        mutating func u32() throws -> UInt32 {
            let b = try bytes(4)
            return b.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        mutating func words() throws -> [UInt16] {
            let count = Int(try u32())
            guard count <= 4096 else { throw XT5ProtocolError.oversized }
            guard count <= (data.count - offset) / 2 else { throw XT5ProtocolError.truncated }
            var values: [UInt16] = []
            for _ in 0..<count { values.append(try u16()) }
            return values
        }
        mutating func string() throws -> String {
            let count = Int(try u8())
            if count == 0 { return "" }
            let units = try bytes(count * 2)
            guard units.suffix(2) == Data([0,0]) else { throw XT5ProtocolError.invalidString }
            for position in stride(from: 0, to: units.count - 2, by: 2) {
                guard units[position] != 0 || units[position + 1] != 0 else { throw XT5ProtocolError.invalidString }
            }
            guard let text = String(data: units.dropLast(2), encoding: .utf16LittleEndian) else { throw XT5ProtocolError.invalidString }
            return text
        }
        mutating func value(_ type: UInt16) throws -> XT5PropertyValue {
            let start = offset
            var text: String?
            if type == 0xffff { text = try string() }
            else {
                let array = (0x4001...0x400a).contains(type)
                let scalar = array ? type - 0x4000 : type
                guard (1...10).contains(scalar) else { throw XT5ProtocolError.unsupportedDataType(type) }
                let width = 1 << Int((scalar - 1) / 2)
                let count = array ? Int(try u32()) : 1
                guard count <= 4096 else { throw XT5ProtocolError.oversized }
                _ = try bytes(count * width)
            }
            return XT5PropertyValue(raw: data.subdata(in: start..<offset), string: text)
        }
        func finish() throws { guard offset == data.count else { throw XT5ProtocolError.trailingBytes } }
    }
}
