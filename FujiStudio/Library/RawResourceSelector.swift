import Foundation

enum RawResourceSelector {
    static func select(_ resources: [ResourceToken]) throws -> OriginalResources {
        let originals = resources.filter { $0.role == .primaryOriginal || $0.role == .alternateOriginal }
        let raws = originals.filter { $0.format == .raf }
        guard !raws.isEmpty else { throw ResourceError.noOriginalRAF }
        guard raws.count == 1 else { throw ResourceError.ambiguousOriginalRAF }
        let jpegs = originals.filter { $0.format == .jpeg }
        guard jpegs.count <= 1 else { throw ResourceError.ambiguousOriginalJPEG }
        return OriginalResources(raf: raws[0], jpeg: jpegs.first)
    }
}
