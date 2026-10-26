import Foundation
import Testing
@testable import FujiStudio

struct XT5RecipeCodecTests {
    @Test func decodesStandardDeviceInfoWithoutRetainingSerial() throws {
        let info = try XT5RecipeCodec.deviceInfo(ProtocolProbeFixtures.deviceInfo())
        #expect(info.model == "X-T5")
        #expect(info.firmware == "4.20")
        #expect(info.operations == [0x1001, 0x1014, 0x1015])
        #expect(info.properties == [0xD16E, 0xD185, 0xD18C, 0xD18D])
        #expect(!String(reflecting: info).contains("PRIVATE-SERIAL"))
    }
    @Test func rejectsEveryTruncatedDeviceInfoAndTrailingBytes() {
        let data = ProtocolProbeFixtures.deviceInfo()
        for count in 0..<data.count {
            #expect(throws: (any Error).self) { try XT5RecipeCodec.deviceInfo(Data(data.prefix(count))) }
        }
        #expect(throws: XT5ProtocolError.trailingBytes) { try XT5RecipeCodec.deviceInfo(data + Data([0])) }
    }
    @Test func boundsPayloadAndUntrustedArrayCountBeforeAllocation() {
        #expect(throws: XT5ProtocolError.oversized) { try XT5RecipeCodec.deviceInfo(Data(repeating: 0, count: 65_537)) }
        var data = ProtocolProbeFixtures.deviceInfo(); data.replaceSubrange(11..<15, with: [255,255,255,255])
        #expect(throws: XT5ProtocolError.oversized) { try XT5RecipeCodec.deviceInfo(data) }
    }
    @Test func strictStringPreservesUnicodeButRejectsInvalidUTF16AndTerminators() throws {
        #expect(try XT5RecipeCodec.value(ProtocolProbeFixtures.string("雪☀️"), type: 0xffff).string == "雪☀️")
        #expect(try XT5RecipeCodec.value(Data([0]), type: 0xffff).string == "")
        for bytes: [UInt8] in [[2,65,0,66,0], [2,0,216,0,0], [3,0,0,65,0,0,0]] {
            #expect(throws: XT5ProtocolError.invalidString) { try XT5RecipeCodec.value(Data(bytes), type: 0xffff) }
        }
    }
    @Test func descriptorPreservesRawValuesAndEnumeration() throws {
        let desc = try XT5RecipeCodec.propertyDescriptor(ProtocolProbeFixtures.modeDescriptor, expectedCode: 0xD16E)
        #expect(desc.dataType == 4)
        #expect(!desc.writable)
        #expect(desc.current.raw == Data([6,0]))
        #expect(desc.current.unsignedInteger == 6)
        #expect(desc.form == .enumeration([.init(raw: Data([5,0]), string: nil), .init(raw: Data([6,0]), string: nil), .init(raw: Data([8,0]), string: nil)]))
    }
    @Test func descriptorRangePreservesSignedRepresentation() throws {
        let desc = try XT5RecipeCodec.propertyDescriptor(Data([0x9a,0xd1,3,0,1,0,0,0xff,0xff,1,0xf7,0xff,9,0,1,0]), expectedCode: 0xD19A)
        #expect(desc.current.raw == Data([255,255]))
        #expect(desc.form == .range(minimum: .init(raw: Data([247,255]), string: nil), maximum: .init(raw: Data([9,0]), string: nil), step: .init(raw: Data([1,0]), string: nil)))
    }
    @Test func rejectsWrongPropertyInvalidAccessUnknownTypeAndForm() {
        #expect(throws: XT5ProtocolError.wrongProperty) { try XT5RecipeCodec.propertyDescriptor(ProtocolProbeFixtures.modeDescriptor, expectedCode: 0xD18C) }
        for (index, byte) in [(2, UInt8(0)), (4, UInt8(2)), (9, UInt8(3))] {
            var data = ProtocolProbeFixtures.modeDescriptor; data[index] = byte
            #expect(throws: (any Error).self) { try XT5RecipeCodec.propertyDescriptor(data, expectedCode: 0xD16E) }
        }
    }
    @Test func rejectsEveryTruncatedDescriptorAndExtraBytes() {
        for original in [ProtocolProbeFixtures.modeDescriptor, ProtocolProbeFixtures.selectorDescriptor] {
            let code: UInt16 = original[0] == 0x6e ? 0xD16E : 0xD18C
            for count in 0..<original.count {
                #expect(throws: (any Error).self) { try XT5RecipeCodec.propertyDescriptor(Data(original.prefix(count)), expectedCode: code) }
            }
            #expect(throws: XT5ProtocolError.trailingBytes) { try XT5RecipeCodec.propertyDescriptor(original + Data([0]), expectedCode: code) }
        }
    }
    @Test func arrayValuesAreBoundedAndPreservedWithoutGuessingScalarType() throws {
        let raw = Data([2,0,0,0,0xff,0xff,7,0])
        #expect(try XT5RecipeCodec.value(raw, type: 0x4004).raw == raw)
        #expect(throws: XT5ProtocolError.truncated) { try XT5RecipeCodec.value(Data(raw.dropLast()), type: 0x4004) }
        #expect(throws: XT5ProtocolError.oversized) { try XT5RecipeCodec.value(Data([255,255,255,255]), type: 0x4004) }
    }
}

struct XT5ImportedRecipeTests {
    private let context = RecipeCameraContext(model: "X-T5", firmware: "4.31", capability: "X-T5_0200", sessionIdentity: UUID(), sessionGeneration: 7)
    @Test func snapshotPreservesAllUnknownBytesAndRejectsUnvalidatedRendering() throws {
        let snapshot = try XT5RecipeCodec.recipe(slot: 3, nameData: ProtocolProbeFixtures.string("Café"), properties: BankImportFixtures.properties, context: context, importedAt: Date())
        #expect(snapshot.slot == 3)
        #expect(snapshot.name == "Café")
        #expect(snapshot.importedSettings.count == 23)
        #expect(snapshot.importedSettings.first { $0.code == 0xD18E }?.raw == Data([7,0]))
        #expect(snapshot.renderingIssues.contains(.unmappedProperty(0xD18E)))
        #expect(snapshot.renderingIssues.contains(.unsupportedValue(0xD195))) // Actual observed 7 is outside pinned table.
        #expect(snapshot.renderingIssues.contains(.conversionProfileUnvalidated))
        #expect(throws: (any Error).self) { try snapshot.requireRenderable() }
    }
    @Test func settingsDigestExcludesNamesSlotsDatesIDsAndIncludesUnknownFields() throws {
        let one = try XT5RecipeCodec.recipe(slot: 1, nameData: ProtocolProbeFixtures.string("One"), properties: BankImportFixtures.properties, context: context, importedAt: Date(timeIntervalSince1970: 1))
        let two = try XT5RecipeCodec.recipe(slot: 7, nameData: ProtocolProbeFixtures.string("Two"), properties: BankImportFixtures.properties, context: context, importedAt: Date(timeIntervalSince1970: 2))
        #expect(one.id != two.id)
        #expect(one.settingsDigest == two.settingsDigest)
        var changed = BankImportFixtures.properties; changed[0xD1A4] = Data([2,0])
        let three = try XT5RecipeCodec.recipe(slot: 1, nameData: ProtocolProbeFixtures.string("One"), properties: changed, context: context, importedAt: Date())
        #expect(one.settingsDigest != three.settingsDigest)
    }
    @Test func unknownFilmSimulationIsPreservedAndUnsupportedInsteadOfApproximated() throws {
        var values = BankImportFixtures.properties; values[0xD192] = Data([255,127])
        let snapshot = try XT5RecipeCodec.recipe(slot: 1, nameData: ProtocolProbeFixtures.string("Synthetic"), properties: values, context: context, importedAt: Date())
        #expect(snapshot.renderingIssues.contains(.unsupportedValue(0xD192)))
        #expect(snapshot.importedSettings.first { $0.code == 0xD192 }?.raw == Data([255,127]))
    }
    @Test func incompleteMalformedOrExtraFieldsNeverBecomeImportedRecipes() {
        var missing = BankImportFixtures.properties; missing[0xD1A4] = nil
        var malformed = BankImportFixtures.properties; malformed[0xD19A] = Data([0])
        var extra = BankImportFixtures.properties; extra[0xD1A5] = Data([0,0])
        for values in [missing, malformed, extra] {
            #expect(throws: (any Error).self) { try XT5RecipeCodec.recipe(slot: 1, nameData: Data([0]), properties: values, context: context, importedAt: Date()) }
        }
    }
}
