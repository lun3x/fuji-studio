import XCTest

extension XCUIElement {
    /// Avoid XCTest's first polling interval when the element is already present.
    /// Elements still appearing retain the full normal XCTest timeout.
    @MainActor
    func waitUntilExists(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }
}
