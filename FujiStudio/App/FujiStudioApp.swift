import SwiftUI

@main
struct FujiStudioApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            switch FixtureEnvironment.route(arguments: ProcessInfo.processInfo.arguments,
                unitHost: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil) {
            case .unitHost: Color.clear
            case .flow: AppEntryView(fixture: true)
            case .liveAcceptance(let id): AppEntryView(acceptanceID: id)
            case .workspace: WorkspaceFixtureEntry()
            case .grid: GridFixtureEntry()
            case .viewer: ViewerFixtureEntry()
            case .probe: ProbeEntryView()
            case .invalid: Text("Fixture and probe launch modes cannot be combined.")
            case .live: AppEntryView()
            }
            #else
            AppEntryView()
            #endif
        }
    }
}

private struct AppEntryView: View {
    @State private var model: AppModel?
    @State private var error: String?
    @Environment(\.scenePhase) private var phase
    @State private var latestScenePhase: ScenePhase = .inactive
    @Environment(\.dynamicTypeSize) private var nativeDynamicTypeSize
    #if DEBUG
    var fixture = false
    var acceptanceID: UUID?
    @State private var acceptance = LiveAcceptanceRunner()
    @State private var fixtureSaveBarrier: FixtureBarrier?
    @State private var fixtureStartBarrier: FixtureBarrier?
    #endif
    var body: some View {
        Group {
            if let model {
                VStack(spacing: 0) {
                    AppWorkspaceView(model: model)
                        #if DEBUG
                        .disabled(acceptanceID != nil)
                        #endif
                    #if DEBUG
                    if acceptanceID != nil { Text(acceptance.status).font(.caption).accessibilityIdentifier("acceptance.status") }
                    if let barrier = fixtureStartBarrier {
                        Button("Finish fixture start") { Task { await barrier.release(); fixtureStartBarrier = nil } }
                            .accessibilityIdentifier("fixture.finishStart").accessibilityValue(String(describing: latestScenePhase))
                    }
                    if fixture && ProcessInfo.processInfo.arguments.contains("--fixture-scene-controls") {
                        HStack {
                            Button("Inject background") { Task { await model.sceneChanged(.background) } }.accessibilityIdentifier("fixture.background")
                            Button("Inject foreground") { Task { await model.sceneChanged(.active) } }.accessibilityIdentifier("fixture.foreground")
                        }.font(.caption).buttonStyle(.bordered)
                    }
                    if let barrier = fixtureSaveBarrier {
                        Button("Finish fixture save") { Task { await barrier.release(); fixtureSaveBarrier = nil } }
                            .accessibilityIdentifier("fixture.finishSave").accessibilityValue(model.environment.platform.idleTimerDisabled ? "Awake" : "Idle timer restored").buttonStyle(.bordered)
                    }
                    #endif
                }
            }
            else if let error { ContentUnavailableView("Fuji Studio could not open", systemImage: "externaldrive.badge.exclamationmark", description: Text(error)) }
            else { ProgressView("Opening Fuji Studio…") }
        }.task {
            guard model == nil, error == nil else { return }
            do {
                let environment: AppEnvironment
                #if DEBUG
                if fixture {
                    let flags = ProcessInfo.processInfo.arguments
                    let bundle = try await FixtureEnvironment.make(access: flags.contains("--fixture-denied") ? .denied : flags.contains("--fixture-limited") ? .limited : .full, uncertain: flags.contains("--fixture-unknown-save"))
                    environment = bundle.environment
                    if flags.contains("--fixture-held-start") {
                        let barrier = FixtureBarrier(); fixtureStartBarrier = barrier
                        await bundle.reader.holdDiscovery(barrier)
                    }
                    if flags.contains("--fixture-held-save") {
                        let barrier = FixtureBarrier(); fixtureSaveBarrier = barrier
                        await bundle.writer.holdSave(barrier)
                    }
                } else { environment = try await AppEnvironment.live() }
                #else
                environment = try await AppEnvironment.live()
                #endif
                let owner = AppModel(environment: environment)
                model = owner
                await owner.start()
                await owner.sceneChanged(latestScenePhase)
                #if DEBUG
                if let acceptanceID { await acceptance.run(model: owner, id: acceptanceID) }
                #endif
            } catch { self.error = AppModel.explain(error) }
        }.onChange(of: phase, initial: true) { _, value in
            latestScenePhase = value
            Task { await model?.sceneChanged(value) }
        }
        #if DEBUG
        .environment(\.dynamicTypeSize, fixture && ProcessInfo.processInfo.arguments.contains("--fixture-accessibility") ? .accessibility5 : nativeDynamicTypeSize)
        .preferredColorScheme(fixture && ProcessInfo.processInfo.arguments.contains("--fixture-dark") ? .dark : nil)
        #endif
    }
}

#if DEBUG
private struct ProbeEntryView: View {
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

#endif
