@testable import FujiCameraCore
import Testing
import Photos
@testable import FujiStudio

struct RawResourceSelectorTests {
    private func token(_ type: PHAssetResourceType, _ uti: String, _ name: String) -> ResourceToken {
        PhotoResourceDescriptor(assetID: "pair", resourceType: type.rawValue,
                                contentTypeIdentifier: uti, filename: name).token
    }

    @Test func originalChoiceIsIndependentOfOrderAndPrimaryRole() throws {
        for rawRole in [PHAssetResourceType.photo, .alternatePhoto] {
            let jpegRole: PHAssetResourceType = rawRole == .photo ? .alternatePhoto : .photo
            let originalRAF = token(rawRole, "com.fuji.raw-image", "DSCF0001.RAF")
            let originalJPEG = token(jpegRole, "public.jpeg", "DSCF0001.JPG")
            let resources = [originalRAF, originalJPEG, token(.fullSizePhoto, "public.jpeg", "adjusted.JPG")]
            for ordering in [resources, resources.reversed().map { $0 }] {
                #expect(try RawResourceSelector.select(ordering).raf == originalRAF)
                #expect(try RawResourceSelector.select(ordering).jpeg == originalJPEG)
            }
        }
    }

    @Test func jpegOnlyAndDNGAreNotRAF() {
        let jpegAndDNGResources = [token(.photo, "public.jpeg", "image.JPG"),
                                  token(.alternatePhoto, "com.adobe.raw-image", "image.DNG")]
        #expect(throws: ResourceError.noOriginalRAF) {
            try RawResourceSelector.select(jpegAndDNGResources)
        }
    }

    @Test func standaloneRAFHasNoJPEG() throws {
        let raf = token(.photo, "com.fuji.raw-image", "image.RAF")
        #expect(try RawResourceSelector.select([raf]).jpeg == nil)
    }

    @Test func adjustedResourcesCannotReplaceOriginals() {
        let resources = [token(.fullSizePhoto, "com.fuji.raw-image", "adjusted.RAF"),
                         token(.adjustmentBasePhoto, "com.fuji.raw-image", "base.RAF"),
                         token(.photo, "public.jpeg", "original.JPG")]
        #expect(throws: ResourceError.noOriginalRAF) { try RawResourceSelector.select(resources) }
    }

    @Test func misleadingExtensionDoesNotClassifyDNGAsRAF() {
        let resources = [token(.photo, "com.adobe.raw-image", "renamed.RAF")]
        #expect(throws: ResourceError.noOriginalRAF) { try RawResourceSelector.select(resources) }
    }

    @Test func ambiguousOriginalsAreRejected() {
        let resources = [token(.photo, "com.fuji.raw-image", "one.RAF"),
                         token(.alternatePhoto, "com.fuji.raw-image", "two.RAF")]
        #expect(throws: ResourceError.ambiguousOriginalRAF) { try RawResourceSelector.select(resources) }
    }
}
