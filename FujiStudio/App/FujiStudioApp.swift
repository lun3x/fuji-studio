import SwiftUI

@main
struct FujiStudioApp: App {
    #if DEBUG
    @State private var protocolProbe = XT5ProbeLaunchRunner()
    #endif
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 24) {
                    Text("Fuji Studio").accessibilityIdentifier("fujiStudioTitle")
                    #if DEBUG
                    NavigationLink("Hardware probe") { HardwareProbeView() }
                    if ProcessInfo.processInfo.arguments.contains("--xt5-read-only-probe") {
                        Text(protocolProbe.status).font(.caption)
                    }
                    #endif
                }
            }
            #if DEBUG
            .task { await protocolProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments) }
            #endif
        }
    }
}
