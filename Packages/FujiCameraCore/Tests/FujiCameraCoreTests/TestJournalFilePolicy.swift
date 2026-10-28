import Foundation
@testable import FujiCameraCore
struct TestJournalFilePolicy: CameraJournalFilePolicy {
 func createDirectory(at url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
 func write(_ data: Data, to url: URL, exclusive: Bool) throws { try data.write(to: url, options: exclusive ? [.withoutOverwriting] : [.atomic]) }
}
