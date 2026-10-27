import SwiftUI

@main
struct FujiStudioApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--workspace-fixture") {
                WorkspaceFixtureEntry()
            } else if ProcessInfo.processInfo.arguments.contains("--grid-fixture") {
                GridFixtureEntry()
            } else if ProcessInfo.processInfo.arguments.contains("--viewer-fixture") {
                ViewerFixtureEntry()
            } else {
                LiveEntryView()
            }
            #else
            LiveEntryView()
            #endif
        }
    }
}

private struct LiveEntryView: View {
    #if DEBUG
    @State private var protocolProbe = XT5ProbeLaunchRunner()
    @State private var reconnectProbe = CameraReconnectLaunchRunner()
    @State private var bankProbe = XT5BankImportLaunchRunner()
    @State private var baselineProbe = XT5RawBaselineLaunchRunner()
    @State private var productionProbe = XT5ProductionAcceptanceRunner()
    @State private var rawDisplayProbe = RawDisplayAcceptanceRunner()
    #endif
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Fuji Studio").accessibilityIdentifier("fujiStudioTitle")
                #if DEBUG
                NavigationLink("Hardware probe") { HardwareProbeView() }
                    .disabled(ProcessInfo.processInfo.arguments.contains { ["--raw-display-acceptance-probe", "--xt5-read-only-probe", "--xt5-direct-values-probe", "--camera-reconnect-probe", "--xt5-bank-import-probe", "--xt5-raw-baseline-probe", "--xt5-unchanged-baseline-probe", "--xt5-output-recovery-probe", "--xt5-output-quarantine-probe", "--xt5-trigger-one-probe", "--xt5-film-only-probe", "--xt5-recipe-batch-probe", "--xt5-paired-baseline-probe", "--xt5-production-acceptance-probe"].contains($0) })
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
                if ProcessInfo.processInfo.arguments.contains("--xt5-production-acceptance-probe") { Text(productionProbe.status).font(.caption) }
                if ProcessInfo.processInfo.arguments.contains("--raw-display-acceptance-probe") { Text(rawDisplayProbe.status).font(.caption) }
                #endif
            }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("--raw-display-acceptance-probe") {
                await rawDisplayProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
            } else {
                await protocolProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
                await reconnectProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
                await bankProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
                await baselineProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
                await productionProbe.runIfRequested(arguments: ProcessInfo.processInfo.arguments)
            }
        }
        #endif
    }
}
