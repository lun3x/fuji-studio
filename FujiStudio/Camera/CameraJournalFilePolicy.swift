import Foundation
import FujiCameraCore

struct IOSCameraJournalFilePolicy: CameraJournalFilePolicy {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
    }
    func write(_ data: Data, to url: URL, exclusive: Bool) throws {
        try data.write(to: url, options: exclusive ? [.withoutOverwriting, .completeFileProtection] : [.atomic, .completeFileProtection])
    }
}
