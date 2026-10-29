import Foundation
import Testing
@testable import FujiCameraCore

struct XT5AdapterTests {
    @Test(arguments:["4.30","4.32","1.30"])
    func rejectsUnmeasuredFirmwareBeforeAnyIO(_ firmware:String) async throws {
        let device=try PTPDatasets.deviceInfo(ProtocolProbeFixtures.deviceInfo(firmware:firmware))
        let io=CameraOperationIO(temporarySelector:nil) { _,_,_ in Issue.record("Unverified firmware must not perform I/O");throw CameraServiceError.unsupportedContext }
        await #expect(throws:CameraServiceError.unsupportedContext) { try await XT5Adapter().verifyDevice(device,io:io) }
        await io.finish()
    }
    @Test func verifiedSupportRetainsCameraReportedCapabilityOrigin() async throws {
        let properties:[UInt16]=[0xD16E,0xD183,0xD185,0xD186,0xD187,0xD18C,0xD18D]+Array(0xD18E...0xD1A4)
        let operations:[UInt16]=[0x1001,0x1005,0x1007,0x1008,0x1009,0x100B,0x1015,0x1016,0x900C,0x900D]
        let device=try PTPDatasets.deviceInfo(ProtocolProbeFixtures.deviceInfo(properties:properties,operations:operations,firmware:"4.31"))
        let io=CameraOperationIO(temporarySelector:nil) { opcode,parameters,_ in
            guard opcode == 0x1015, [UInt32(0xD16E),0xD186,0xD187].contains(parameters.first ?? 0) else { throw CameraServiceError.unsupportedContext }
            let data=parameters == [0xD16E] ? Data([6,0]) : ProtocolProbeFixtures.string("X-T5_0200")
            return PTPReply(opcode:opcode,parameters:[],logicalTransactionID:1,wireTransactionID:1,correlation:.directWireTransaction,responseCode:0x2001,rawResponse:Data(),data:data)
        }
        let support=try await XT5Adapter().verifyDevice(device,io:io)
        #expect(support.capabilityOrigin == .cameraReported)
        #expect(support.capability == "X-T5_0200")
        #expect(support.capabilities.bankSlots.map(\.id) == [1,2,3,4,5,6,7])
        #expect(support.capabilities.settings[.film]?.accepts(.film(.velvia),rendering:true) == true)
        await io.finish()
    }
}
