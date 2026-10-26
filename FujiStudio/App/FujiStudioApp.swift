import SwiftUI

@main
struct FujiStudioApp: App {
    #if DEBUG
    @State private var protocolProbe = XT5ProbeLaunchRunner()
    @State private var reconnectProbe = CameraReconnectLaunchRunner()
    @State private var bankProbe = XT5BankImportLaunchRunner()
    @State private var baselineProbe = XT5RawBaselineLaunchRunner()
    #endif
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 24) {
                    Text("Fuji Studio").accessibilityIdentifier("fujiStudioTitle")
                    #if DEBUG
                    NavigationLink("Hardware probe") { HardwareProbeView() }
                        .disabled(ProcessInfo.processInfo.arguments.contains { ["--xt5-read-only-probe", "--xt5-direct-values-probe", "--camera-reconnect-probe", "--xt5-bank-import-probe", "--xt5-raw-baseline-probe", "--xt5-unchanged-baseline-probe", "--xt5-output-recovery-probe", "--xt5-output-quarantine-probe", "--xt5-trigger-one-probe", "--xt5-film-only-probe", "--xt5-recipe-batch-probe", "--xt5-paired-baseline-probe"].contains($0) })
                    if ProcessInfo.processInfo.arguments.contains("--xt5-read-only-probe") || ProcessInfo.processInfo.arguments.contains("--xt5-direct-values-probe") {
                        Text(protocolProbe.status).font(.caption)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--camera-reconnect-probe") {
                        Text(reconnectProbe.status).font(.caption)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--xt5-bank-import-probe") {
                        Text(bankProbe.status).font(.caption)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--xt5-raw-baseline-probe") || ProcessInfo.processInfo.arguments.contains("--xt5-unchanged-baseline-probe") || ProcessInfo.processInfo.arguments.contains("--xt5-output-recovery-probe") || ProcessInfo.processInfo.arguments.contains("--xt5-output-quarantine-probe") || ProcessInfo.processInfo.arguments.contains("--xt5-trigger-one-probe") || ProcessInfo.processInfo.arguments.contains("--xt5-film-only-probe") || ProcessInfo.processInfo.arguments.contains("--xt5-recipe-batch-probe") || ProcessInfo.processInfo.arguments.contains("--xt5-paired-baseline-probe") {
                        Text(baselineProbe.status).font(.caption)
                    }
                    #endif
                }
            }
            #if DEBUG
            .task {
                await protocolProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
                await reconnectProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
                await bankProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
                await baselineProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
            }
            #endif
        }
    }
}
