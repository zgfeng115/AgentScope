import AgentScopeCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var showingAISettings = false
    @State private var confirmingBatchExplain = false

    var body: some View {
        NavigationSplitView {
            SourceSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(
                    min: UIScale.size(160), ideal: UIScale.size(190), max: UIScale.size(230)
                )
        } content: {
            ServiceListView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(
                    min: UIScale.size(320), ideal: UIScale.size(380), max: UIScale.size(480)
                )
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("重新扫描自动启动项、定时任务和项目审计")
            }
            if viewModel.supportsDeepScan {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await viewModel.runDeepScan() }
                    } label: {
                        if viewModel.deepScanInProgress {
                            ProgressView().controlSize(.regular)
                        } else {
                            Label("深度扫描", systemImage: "scope")
                        }
                    }
                    .disabled(viewModel.deepScanInProgress)
                    .help(deepScanHelp)
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    if viewModel.batchExplainProgress != nil {
                        viewModel.cancelBatchExplain()
                    } else {
                        confirmingBatchExplain = true
                    }
                } label: {
                    if let progress = viewModel.batchExplainProgress {
                        Label("停止 AI 解释 \(progress.done)/\(progress.total)", systemImage: "stop.circle")
                            .labelStyle(.titleAndIcon)
                            .monospacedDigit()
                    } else {
                        Label("AI 解释", systemImage: "sparkles")
                    }
                }
                .disabled(viewModel.batchExplainProgress == nil && (!viewModel.canExplainWithAI || viewModel.unexplainedItems.isEmpty))
                .help(viewModel.canExplainWithAI
                      ? "用 AI 逐个解释 \(viewModel.unexplainedItems.count) 个只有规则说明的项目（会上传脱敏后的配置与脚本片段）"
                      : "先在「AI 设置」中配置模型和 API Key")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingAISettings = true
                } label: {
                    Label("AI 设置", systemImage: "gearshape")
                }
                .help("配置手动 AI 分析")
            }
        }
        .sheet(isPresented: $showingAISettings) {
            AISettingsView(viewModel: viewModel)
        }
        .confirmationDialog(
            "用 AI 解释未识别的项目？",
            isPresented: $confirmingBatchExplain,
            titleVisibility: .visible
        ) {
            Button("开始解释") {
                Task { await viewModel.explainUnidentifiedWithAI() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(viewModel.batchExplainDisclosure)
        }
        .alert(
            "AI 解释",
            isPresented: Binding(
                get: { viewModel.batchExplainMessage != nil },
                set: { if !$0 { viewModel.batchExplainMessage = nil } }
            )
        ) {
            Button("好") { viewModel.batchExplainMessage = nil }
        } message: {
            Text(viewModel.batchExplainMessage ?? "")
        }
        .alert(
            "卸载",
            isPresented: Binding(
                get: { viewModel.uninstallMessage != nil },
                set: { if !$0 { viewModel.uninstallMessage = nil } }
            )
        ) {
            Button("好") { viewModel.uninstallMessage = nil }
        } message: {
            Text(viewModel.uninstallMessage ?? "")
        }
        .alert(
            "深度扫描未完成",
            isPresented: Binding(
                get: { viewModel.deepScanError != nil },
                set: { if !$0 { viewModel.deepScanError = nil } }
            )
        ) {
            Button("好") { viewModel.deepScanError = nil }
        } message: {
            Text(viewModel.deepScanError ?? "")
        }
        .task {
            guard viewModel.loadState == .idle else { return }
            await viewModel.refresh()
        }
        .controlSize(.large)
        .frame(
            minWidth: UIScale.windowSize(width: 700, height: 450).width,
            minHeight: UIScale.windowSize(width: 700, height: 450).height
        )
    }

    private var deepScanHelp: String {
        let base = "读取系统设置中「允许在后台」的完整列表，需要输入一次管理员密码"
        guard let date = viewModel.lastDeepScanAt else { return base + "（尚未扫描）" }
        return base + "（上次：\(date.formatted(date: .abbreviated, time: .shortened))）"
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedServiceID = viewModel.selectedServiceID,
           let item = viewModel.items.first(where: { $0.id == selectedServiceID }) {
            ServiceDetailView(viewModel: viewModel, item: item)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                Text("选择一个项目查看说明与详情")
                    .font(.headline)
                Text("左侧按用途或启动方式浏览本机的后台程序与启动项。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AISettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var provider: AIProviderPreset
    @State private var enabled: Bool
    @State private var baseURL: String
    @State private var model: String
    @State private var timeout: Double
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var keyStateVersion = 0

    init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
        let configuration = viewModel.aiConfiguration
        _provider = State(initialValue: configuration.preset)
        _enabled = State(initialValue: configuration.enabled)
        _baseURL = State(initialValue: configuration.baseURL.absoluteString)
        _model = State(initialValue: configuration.model)
        _timeout = State(initialValue: configuration.timeout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.size(18)) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI 设置")
                        .font(.title2.weight(.bold))
                    Text("只在你点击「AI 分析」或「AI 解释」时发送脱敏后的配置资料。API Key 保存在 macOS 钥匙串，每个服务商单独保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }

            Form {
                Picker("服务商", selection: $provider) {
                    ForEach(AIProviderPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: provider) { newValue in
                    baseURL = newValue.defaultBaseURL.absoluteString
                    model = newValue.defaultModel
                    apiKey = ""
                    testResult = nil
                }
                Toggle("启用", isOn: $enabled)
                TextField("Base URL", text: $baseURL)
                TextField("模型名称", text: $model, prompt: Text(provider.defaultModel.isEmpty ? "填写模型名称" : provider.defaultModel))
                if provider.requiresKey {
                    SecureField("API Key", text: $apiKey, prompt: Text(storedKey ? "已保存，留空则继续使用" : "粘贴 API Key"))
                    HStack {
                        Text("钥匙串")
                        Spacer()
                        Text(storedKey ? "\(provider.displayName) 的 Key 已保存" : "未保存")
                            .foregroundStyle(.secondary)
                        Button("清除") { clearKey() }
                            .disabled(!storedKey)
                    }
                } else {
                    Text("本地服务，不需要 API Key。")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("请求超时")
                    Slider(value: $timeout, in: 10...180, step: 5)
                    Text("\(Int(timeout)) 秒")
                        .frame(width: UIScale.size(55), alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            if let testResult {
                Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(testResult.ok ? .green : .red)
                    .textSelection(.enabled)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    Task { await test() }
                } label: {
                    if testing {
                        ProgressView()
                    } else {
                        Label("测试连接", systemImage: "bolt.horizontal.circle")
                    }
                }
                .disabled(testing || formConfiguration == nil)
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UIScale.size(24))
        .frame(width: UIScale.size(520))
    }

    private var storedKey: Bool {
        _ = keyStateVersion
        return viewModel.hasStoredAIKey(provider: provider.rawValue)
    }

    private var formConfiguration: AIModelConfiguration? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            return nil
        }
        return AIModelConfiguration(
            providerID: provider.rawValue,
            enabled: enabled,
            baseURL: url,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            timeout: timeout
        )
    }

    private func test() async {
        guard let configuration = formConfiguration else { return }
        testing = true
        testResult = nil
        defer { testing = false }
        switch await viewModel.testAIConnection(configuration, apiKey: apiKey) {
        case .success(let seconds):
            testResult = (true, "连接成功，\(configuration.model) 用时 \(Int(seconds * 1000)) 毫秒")
        case .failure(let error):
            testResult = (false, error.localizedDescription)
        }
    }

    private func clearKey() {
        do {
            try viewModel.removeAIKey(provider: provider.rawValue)
            keyStateVersion += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let configuration = formConfiguration else {
            errorMessage = "Base URL 不是有效地址。"
            return
        }
        do {
            try viewModel.saveAIConfiguration(configuration, apiKey: apiKey)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
