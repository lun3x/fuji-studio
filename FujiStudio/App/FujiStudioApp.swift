import SwiftUI

@main
struct FujiStudioApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 24) {
                    Text("Fuji Studio").accessibilityIdentifier("fujiStudioTitle")
                    #if DEBUG
                    NavigationLink("Hardware probe") { HardwareProbeView() }
                    #endif
                }
            }
        }
    }
}
