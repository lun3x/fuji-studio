import FujiCameraCore
import Foundation

struct PhotoDaySection: Equatable {
    let date: Date?
    var sourceIDs: [SourceID]

    static func grouped(_ sources: [PhotoSource], calendar: Calendar = .current) -> [Self] {
        var sections: [Self] = []
        var indices: [Date?: Int] = [:]
        for source in sources {
            let day = source.captureDate.map { calendar.startOfDay(for: $0) }
            if let index = indices[day] { sections[index].sourceIDs.append(source.id) }
            else {
                indices[day] = sections.count
                sections.append(Self(date: day, sourceIDs: [source.id]))
            }
        }
        return sections
    }
}
