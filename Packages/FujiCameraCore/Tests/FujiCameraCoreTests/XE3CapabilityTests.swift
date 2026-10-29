import Foundation
import Testing
@testable import FujiCameraCore
struct XE3CapabilityTests {
    @Test func xe3DoesNotWidenXT5Domain() throws {
        let caps=XE3Capabilities.measured
        #expect(caps.settings[.film]?.editableChoices.count == 15)
        #expect(caps.settings[.grain]?.accepts(.grain(.init(strength:.weak,size:nil)),rendering:true) == true)
        #expect(caps.settings[.grain]?.accepts(.grain(.init(strength:.weak,size:.small)),rendering:true) == false)
        #expect(caps.settings[.colorChrome]?.support == .absent)
        #expect(caps.settings[.clarity]?.support == .absent)
        #expect(caps.settings[.dynamicRange]?.accepts(.integer(200),rendering:true) == true)
        #expect(RecipeCodecRegistry.xt5Capabilities.settings[.dynamicRange]?.accepts(.integer(200),rendering:true) == false)
        #expect(caps.settings[.kelvin]?.accepts(.integer(5310),rendering:true) == false)
    }
}
