import Foundation
import FujiCameraCore

enum CaptureResolver {
    static func resolve(
        objects: [WirelessObjectDescriptor], inventory: WirelessStorageInventory
    ) -> [CameraCapture] {
        let objects = Set(objects)
        let allListed = !inventory.storage.isEmpty && !inventory.storage.values.contains(.pending)
            && objects.allSatisfy { inventory.storage[$0.storageID] != nil }
        guard allListed else {
            return objects.map(checking).sorted(by: CameraCapture.newestFirst)
        }

        let hasUnavailableCard = inventory.storage.values.contains(.unavailable)
        var groups: [GroupKey: [Evidence]] = [:]
        var singles: [CameraCapture] = []
        var seenIDs: Set<CameraCaptureID> = []
        var duplicateIDs: Set<CameraCaptureID> = []
        for object in objects {
            let row = checking(object)
            if !seenIDs.insert(row.id).inserted { duplicateIDs.insert(row.id) }
            if let stem = CameraCaptureEvidence.stem(object) {
                let key = GroupKey(camera: object.cameraID, session: object.sessionID, stem: stem)
                groups[key, default: []].append(.init(row))
            } else {
                singles.append(single(row, inventory: inventory, hasUnavailableCard: hasUnavailableCard))
            }
        }

        // Resolve digest collisions before evaluating mates. Even a uniquely corroborated
        // mate cannot distinguish between source objects with identical descriptive evidence.
        for group in groups.values {
            let raws = group.filter { $0.object.format == .raf }
            let jpegs = group.filter { $0.object.format == .jpeg }
            let rawIndex = MateIndex(raws)
            let jpegIndex = MateIndex(jpegs)
            var pairedJPEGs: Set<WirelessObjectDescriptor> = []

            for raw in raws {
                if !duplicateIDs.contains(raw.id),
                   inventory.storage[raw.object.storageID] == .complete,
                   let jpeg = jpegIndex.uniquePlausibleMate(for: raw),
                   inventory.storage[jpeg.object.storageID] == .complete,
                   !duplicateIDs.contains(jpeg.id),
                   raw.corroborates(jpeg),
                   rawIndex.uniquePlausibleMate(for: jpeg)?.object == raw.object {
                    singles.append(.init(anchor: raw.object, mate: jpeg.object, availability: .pair))
                    pairedJPEGs.insert(jpeg.object)
                } else {
                    singles.append(single(raw.row, inventory: inventory, hasUnavailableCard: hasUnavailableCard,
                                          hasPossibleMate: !jpegs.isEmpty))
                }
            }
            for jpeg in jpegs where !pairedJPEGs.contains(jpeg.object) {
                singles.append(single(jpeg.row, inventory: inventory, hasUnavailableCard: hasUnavailableCard,
                                      hasPossibleMate: !raws.isEmpty))
            }
        }
        return singles.map { capture in
            guard capture.availability != .unsupported, duplicateIDs.contains(capture.id) else { return capture }
            return capture.withAvailability(.ambiguous)
        }.sorted(by: CameraCapture.newestFirst)
    }

    static func checking(_ object: WirelessObjectDescriptor) -> CameraCapture {
        switch object.format {
        case .raf, .jpeg: return .init(anchor: object, availability: .checking)
        case .other: return .init(anchor: object, availability: .unsupported)
        }
    }

    private static func single(
        _ row: CameraCapture, inventory: WirelessStorageInventory, hasUnavailableCard: Bool,
        hasPossibleMate: Bool = false
    ) -> CameraCapture {
        let availability: CaptureAvailability
        switch row.rowID.format {
        case .raf:
            availability = hasPossibleMate || hasUnavailableCard ? .ambiguous : .rawOnly
        case .jpeg:
            if hasPossibleMate { availability = .ambiguous }
            else if inventory.rawExposure != .available || hasUnavailableCard { availability = .rawUnavailable }
            else { availability = .jpegOnly }
        case .other:
            availability = .unsupported
        }
        return row.withAvailability(availability)
    }

    private struct GroupKey: Hashable {
        let camera: WirelessCameraID
        let session: UUID
        let stem: String
    }

    private struct Evidence {
        let row: CameraCapture
        let location: Location
        var object: WirelessObjectDescriptor { row.rowID }
        var id: CameraCaptureID { row.id }
        var date: CameraCaptureTimestamp? { row.timestamp }

        init(_ row: CameraCapture) {
            self.row = row
            self.location = .init(row.rowID)
        }

        func corroborates(_ other: Self) -> Bool {
            guard let date, date == other.date else { return false }
            if object.storageID == other.object.storageID { return true }
            guard let size = object.dimensions else { return false }
            return size == other.object.dimensions
        }
    }

    private struct Location: Hashable {
        let directory: String?
        let reportedStorage: UInt32?
        let orientation: Int?

        init(_ object: WirelessObjectDescriptor) {
            directory = CameraCaptureEvidence.directory(object.directory)
            reportedStorage = object.reportedStorageID
            orientation = object.orientation
        }

        func canMatch(_ other: Self, sameCard: Bool) -> Bool {
            if let orientation, let otherOrientation = other.orientation, orientation != otherOrientation {
                return false
            }
            if sameCard {
                if let directory, let otherDirectory = other.directory, directory != otherDirectory { return false }
                if let reportedStorage, let otherStorage = other.reportedStorage,
                   reportedStorage != otherStorage { return false }
            }
            return true
        }
    }

    private struct MateIndex {
        private struct Bucket: Hashable {
            let date: CameraCaptureTimestamp?
            let storage: UInt32
            let directory: String?
        }

        private let allOnCard: [CameraCaptureTimestamp?: [UInt32: [Evidence]]]
        private let byDirectory: [Bucket: [Evidence]]
        private let datesByWallTime: [String: Set<CameraCaptureTimestamp>]

        init(_ evidence: some Sequence<Evidence>) {
            var allOnCard: [CameraCaptureTimestamp?: [UInt32: [Evidence]]] = [:]
            var byDirectory: [Bucket: [Evidence]] = [:]
            var datesByWallTime: [String: Set<CameraCaptureTimestamp>] = [:]
            for item in evidence {
                let storage = item.object.storageID
                allOnCard[item.date, default: [:]][storage, default: []].append(item)
                byDirectory[.init(date: item.date, storage: storage, directory: item.location.directory),
                            default: []].append(item)
                if let date = item.date {
                    datesByWallTime[date.wallTime, default: []].insert(date)
                }
            }
            self.allOnCard = allOnCard
            self.byDirectory = byDirectory
            self.datesByWallTime = datesByWallTime
        }

        func uniquePlausibleMate(for source: Evidence) -> Evidence? {
            guard let date = source.date else { return nil }
            // Same wall time with an unknown offset can compete for uniqueness.
            // The full timestamp still has to match before it can corroborate a pair.
            let compatibleDates = (datesByWallTime[date.wallTime] ?? []).filter {
                date.offset == nil || $0.offset == nil || date.offset == $0.offset
            }
            var match: Evidence?
            for candidateDate in compatibleDates.map(Optional.some) + [nil] {
                for (storage, all) in allOnCard[candidateDate] ?? [:] {
                    let sameCard = storage == source.object.storageID
                    let lists: [[Evidence]]
                    if sameCard, let directory = source.location.directory {
                        lists = [byDirectory[.init(date: candidateDate, storage: storage, directory: directory)] ?? [],
                                 byDirectory[.init(date: candidateDate, storage: storage, directory: nil)] ?? []]
                    } else {
                        lists = [all]
                    }
                    for list in lists {
                        for candidate in list where source.location.canMatch(candidate.location, sameCard: sameCard) {
                            guard match == nil else { return nil }
                            match = candidate
                        }
                    }
                }
            }
            return match
        }
    }
}
