import AgentScopeCore
import AppKit
import Darwin
import SwiftUI

@MainActor
@main
struct AgentScopeApp: App {
    @State private var viewModel: DashboardViewModel?
    @State private var bootstrapError: String?

    init() {
        SingleInstance.handOffIfAlreadyRunning()
        let result = ProductionDependencyFactory.make()
        _viewModel = State(initialValue: result.viewModel)
        _bootstrapError = State(initialValue: result.error)
    }

    var body: some Scene {
        // Single `Window` (not `WindowGroup`): no "New Window", one dashboard per process.
        // The id stays "main-2x" so older saved (small) frames do not override the 2x default size.
        Window("AgentScope", id: "main-2x") {
            if let viewModel {
                DashboardView(viewModel: viewModel)
                    .overlay(alignment: .top) {
                        if let bootstrapError {
                            BootstrapNotice(message: bootstrapError)
                                .padding(.top, 8)
                        }
                    }
            } else {
                BootstrapFailureView(message: bootstrapError ?? "应用初始化失败。")
            }
        }
        .defaultSize(UIScale.windowSize(width: 900, height: 600))
    }
}

/// A second launch (e.g. `open -n`, another copy of the app) activates the running one and quits.
@MainActor
private enum SingleInstance {
    static func handOffIfAlreadyRunning() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) else { return }
        running.activate(options: [.activateAllWindows])
        exit(0)
    }
}

@MainActor
private enum ProductionDependencyFactory {
    static func make() -> ProductionDependencyResult {
        let fileManager = FileManager.default
        let applicationSupport = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support"))
            .appending(path: "AgentScope")
        let backupRoot = applicationSupport.appending(path: "Backups")
        let userID = getuid()
        let launchAgentCollector = LaunchAgentCollector(userID: userID)
        let backgroundTaskStore = BackgroundTaskStore(fileURL: applicationSupport.appending(path: "background-tasks.json"))
        let inventory = ProductionCollectors.makeInventory(userID: userID, backgroundTaskStore: backgroundTaskStore)

        do {
            let store = try LocalStore(directoryURL: applicationSupport)
            let aiConfigurationStore = UserDefaultsAIConfigurationStore()
            let apiKeyStore = KeychainProviderKeyStore()
            let aiConfiguration = aiConfigurationStore.load()
            apiKeyStore.migrateLegacyKey(to: aiConfiguration.providerID)
            let aiKey = (try? apiKeyStore.load(provider: aiConfiguration.providerID)) ?? nil
            let keyReady = aiKey?.isEmpty == false || !aiConfiguration.preset.requiresKey
            let analysisProvider: (any AnalysisProvider)? = aiConfiguration.isConfigured && keyReady
                ? AIProviderFactory.make(configuration: aiConfiguration, apiKey: aiKey)
                : nil
            let controller = try LaunchAgentController(
                commandRunner: CommandRunner(),
                collector: launchAgentCollector,
                store: store,
                backupRoot: backupRoot,
                userID: userID
            )
            return ProductionDependencyResult(
                viewModel: DashboardViewModel(
                    inventory: inventory,
                    controller: controller,
                    historyProvider: store,
                    analysisProvider: analysisProvider,
                    analysisStore: store,
                    aiConfigurationStore: aiConfigurationStore,
                    apiKeyStore: apiKeyStore,
                    deepScanner: BackgroundTaskDeepScanner(store: backgroundTaskStore),
                    uninstaller: UninstallExecutor(
                        stagingRoot: applicationSupport.appending(path: "Uninstall-staging"),
                        backupRoot: backupRoot
                    ),
                    operationRecorder: store,
                    backgroundTaskStore: backgroundTaskStore,
                    logQuery: LaunchdLogQuery()
                ),
                error: nil
            )
        } catch {
            let message = "本地存储或服务控制器初始化失败：\(error.localizedDescription)"
            return ProductionDependencyResult(
                viewModel: DashboardViewModel(
                    inventory: inventory,
                    controller: nil,
                    historyProvider: EmptyHistoryProvider()
                ),
                error: message
            )
        }
    }
}

private struct ProductionDependencyResult {
    let viewModel: DashboardViewModel?
    let error: String?
}

private struct EmptyHistoryProvider: OperationHistoryProviding {
    func fetchOperationRecords(serviceID: String?) throws -> [OperationRecord] {
        []
    }
}

private struct BootstrapNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
    }
}

private struct BootstrapFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("AgentScope 无法初始化")
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 500, minHeight: 300)
    }
}
