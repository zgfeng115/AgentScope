import AgentScopeCore
import SwiftUI

struct ServiceDetailView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let item: ServiceItem

    @State private var history: [OperationRecord] = []
    @State private var pendingAction: OperationAction?
    @State private var uninstallRequest: UninstallRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.size(20)) {
                header
                explanationSection
                if hasSchedule {
                    runTimeSection
                }
                overviewSection
                if item.sourceType == .loginItem || item.sourceType == .embeddedLoginItem {
                    startupOverviewItemSection
                }
                auditSection
                launchSection
                validitySection
                historySection
            }
            .padding(UIScale.size(24))
        }
        .task(id: item.id) {
            reloadHistory()
            viewModel.loadLatestAnalysis(for: item.id)
        }
        .sheet(item: $pendingAction) { action in
            OperationConfirmationView(item: item, action: action) {
                pendingAction = nil
                Task {
                    await viewModel.perform(action, on: item)
                    reloadHistory()
                }
            } onCancel: {
                pendingAction = nil
            }
        }
        .sheet(item: $uninstallRequest) { request in
            UninstallConfirmationView(plan: request.plan) { selected in
                uninstallRequest = nil
                Task { await viewModel.uninstall(request.plan, selectedOptional: selected) }
            } onCancel: {
                uninstallRequest = nil
            }
        }
        .alert(
            "操作提示",
            isPresented: Binding(
                get: { viewModel.actionError != nil },
                set: { isPresented in
                    if !isPresented { viewModel.actionError = nil }
                }
            )
        ) {
            Button("好") { viewModel.actionError = nil }
        } message: {
            Text(viewModel.actionError ?? "未知错误")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.largeTitle.weight(.bold))
                    Text("\(item.sourceType.displayName) · \(item.scope.displayName)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            if let attribution = item.attribution {
                Label(
                    "归属：\(attribution.kind) · 置信度 \(Int(attribution.confidence * 100))%",
                    systemImage: "person.crop.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var explanationSection: some View {
        DetailSection(title: "这是什么", systemImage: item.purpose?.symbolName ?? "questionmark.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.summary ?? "暂无说明")
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                DetailGrid {
                    DetailValue(label: "用途分类", value: item.purpose?.displayName ?? "未识别")
                    DetailValue(label: "所属应用 / 产品", value: item.vendorName ?? "未识别")
                    DetailValue(label: "开发者签名", value: signerDescription)
                    DetailValue(label: "所属应用状态", value: ownerAppDescription)
                }
                if let source = item.summarySource {
                    Text("说明来源：\(source.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.canUninstall(item) {
                    Button(role: .destructive) {
                        uninstallRequest = UninstallRequest(plan: viewModel.uninstallPlan(for: [item], title: item.name))
                    } label: {
                        Label(item.purpose == .userScript ? "删除…" : "卸载…", systemImage: "trash")
                    }
                    .disabled(viewModel.uninstallInProgress)
                }
            }
        }
    }

    private var signerDescription: String {
        guard let signing = item.signing else { return "未知" }
        switch signing.signature {
        case .developerID:
            let organization = signing.organization ?? "开发者"
            return signing.teamID.map { "\(organization)（\($0)）" } ?? organization
        case .apple: return "Apple 系统程序（脚本解释器）"
        case .adhoc: return "临时签名（未经 Apple 公证）"
        case .unsigned: return "未签名"
        case .invalid: return "签名无效或无法读取"
        case .unknown: return "未知"
        }
    }

    private var ownerAppDescription: String {
        switch item.ownerAppStatus {
        case .installed: return item.ownerAppPath ?? "已安装"
        case .missing: return "已不在本机（疑似卸载残留）"
        case .notApplicable, .none: return "不适用"
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(item.state.displayName)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var overviewSection: some View {
        DetailSection(title: "概览", systemImage: "chart.bar.doc.horizontal") {
            DetailGrid {
                DetailValue(label: "状态", value: item.state.displayName)
                DetailValue(label: "作用域", value: startupOverviewScopeDescription)
                DetailValue(label: "PID", value: item.pid.map(String.init) ?? "—")
                DetailValue(label: "启用状态", value: enabledStatusDescription)
            }
        }
    }

    private var launchSection: some View {
        DetailSection(title: "启动与计划信息", systemImage: "arrow.clockwise.circle") {
            VStack(alignment: .leading, spacing: 10) {
                DetailValue(label: "配置路径", value: item.configurationPath ?? "未知", selectable: true)
                DetailValue(label: "程序路径", value: item.programPath ?? "未知", selectable: true)
                DetailValue(label: "参数", value: item.arguments.isEmpty ? "无" : item.arguments.joined(separator: " "), selectable: true)
                DetailValue(label: "最近运行", value: recentRunDescription)
            }
        }
    }

    private var startupOverviewItemSection: some View {
        DetailSection(title: item.startupOverviewDetailTitle, systemImage: "person.crop.circle.badge.checkmark") {
            VStack(alignment: .leading, spacing: 10) {
                DetailValue(label: "登录触发", value: item.triggers?.first?.summary ?? "用户登录时启动")
                if let hostPath = item.startupOverviewHostApplicationPath {
                    DetailValue(label: "宿主 App", value: hostPath, selectable: true)
                }
                DetailValue(label: "应用/程序路径", value: item.programPath ?? item.configurationPath ?? "未知", selectable: true)
                DetailValue(label: "Bundle Identifier", value: item.label ?? "未知", selectable: true)
                DetailValue(
                    label: item.startupOverviewEvidenceLabel,
                    value: item.executionEvidence?.source ?? item.startupOverviewEvidenceFallback
                )
                if let evidenceDetail = item.executionEvidence?.detail {
                    DetailValue(label: "读取说明", value: evidenceDetail)
                }
            }
        }
    }

    private var auditSection: some View {
        DetailSection(title: "项目与规则审计", systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                Text("当前结论来自本地确定性规则；AI 分析未配置，不会自动联网。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let project = item.project {
                    DetailValue(label: "归属项目", value: "\(project.displayName)（\(project.kind.rawValue)）")
                    DetailValue(label: "项目路径", value: project.rootPath ?? "未知", selectable: true)
                    DetailValue(label: "归因置信度", value: "\(Int(project.confidence * 100))%")
                } else {
                    DetailValue(label: "归属项目", value: "未识别")
                }

                if let assessment = item.assessment {
                    DetailValue(label: "规则判断", value: assessment.status.rawValue)
                    DetailValue(label: "判断置信度", value: "\(Int(assessment.confidence * 100))%")
                    ForEach(assessment.evidence, id: \.self) { evidence in
                        Text("• \(evidence)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let execution = item.executionEvidence {
                    DetailValue(label: "执行证据来源", value: execution.source)
                    DetailValue(label: "连续失败", value: String(execution.consecutiveFailures))
                    DetailValue(label: "执行详情", value: execution.detail ?? "未知")
                }

                aiAnalysisView
            }
        }
    }

    @ViewBuilder
    private var aiAnalysisView: some View {
        Divider()
            .padding(.vertical, 4)

        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 分析")
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.aiConfiguration.isConfigured && viewModel.aiKeyConfigured
                     ? "手动触发；发送前会脱敏并限制配置和源码大小。"
                     : "尚未配置。点击右上角齿轮设置 AI 服务商。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await viewModel.analyze(item) }
            } label: {
                Label("AI 分析", systemImage: "sparkles")
            }
            .disabled(viewModel.analyzingServiceID != nil)
        }

        if viewModel.analyzingServiceID == item.id {
            ProgressView("分析中…")
                .controlSize(.regular)
        }

        if let record = viewModel.analysis(for: item.id) {
            AnalysisRecordView(record: record, time: Self.shortTime(record.analyzedAt))
        }
    }

    private var validitySection: some View {
        DetailSection(title: "有效性与证据", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 12) {
                DetailGrid {
                    DetailValue(label: "有效性", value: item.validity.displayName)
                    DetailValue(label: "签名", value: item.signature.displayName)
                    DetailValue(label: "时间精度", value: item.lastRunPrecision.displayName)
                    DetailValue(label: "最近退出码", value: item.lastExitCode.map(String.init) ?? "—")
                }

                if item.evidence.isEmpty {
                    Text("暂无确定性证据")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(item.evidence, id: \.self) { evidence in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: evidenceIcon(for: evidence.severity))
                                .foregroundStyle(evidenceColor(for: evidence.severity))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(evidence.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(evidence.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var historySection: some View {
        DetailSection(title: "操作历史", systemImage: "clock.arrow.circlepath") {
            if history.isEmpty {
                Text("暂无操作记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(history) { record in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: record.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(record.succeeded ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(record.action.displayName) · \(record.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.subheadline.weight(.semibold))
                                Text(record.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            let actions = viewModel.availableActions(for: item)
            if !actions.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                HStack {
                    ForEach(actions, id: \.self) { action in
                        Button {
                            pendingAction = action
                        } label: {
                            Label(action.displayName, systemImage: action.systemImage)
                        }
                        .disabled(viewModel.operatingServiceID == item.id)
                    }
                }
                if viewModel.operatingServiceID == item.id {
                    ProgressView("操作执行中…")
                        .controlSize(.regular)
                }
            } else {
                Label(
                    readOnlyMessage,
                    systemImage: "lock.fill"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scheduledTriggers: [TriggerInfo] {
        (item.triggers ?? []).filter { [.startInterval, .calendar, .cron, .watchPaths, .periodic].contains($0.kind) }
    }

    private var hasSchedule: Bool { !scheduledTriggers.isEmpty }

    private var runTimeSection: some View {
        DetailSection(title: "运行时间", systemImage: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 10) {
                DetailGrid {
                    DetailValue(label: "运行计划", value: scheduledTriggers.map(\.summary).joined(separator: "；"))
                    DetailValue(label: "当前状态", value: item.state.displayName)
                    DetailValue(label: "上次运行", value: lastRunText)
                    DetailValue(label: "下次运行", value: nextRunText)
                    if let runs = item.executionEvidence?.runCount {
                        DetailValue(label: "本次加载后运行次数", value: "\(runs) 次")
                    }
                    DetailValue(label: "最近退出码", value: item.lastExitCode.map(String.init) ?? "—")
                }
                if item.label != nil, item.sourceType == .launchAgent || item.sourceType == .launchDaemon {
                    HStack(spacing: 8) {
                        Button {
                            Task { await viewModel.queryLastRunFromLog(item) }
                        } label: {
                            Label("查询系统日志（最近 \(DashboardViewModel.logWindowHours(for: item)) 小时，最长约 1 分钟）", systemImage: "doc.text.magnifyingglass")
                        }
                        .disabled(viewModel.logQueryInProgress != nil)
                        if viewModel.logQueryInProgress == item.id {
                            ProgressView()
                        }
                    }
                    if let result = viewModel.logLastRuns[item.id] {
                        Text(logResultText(result))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var lastRunText: String {
        if item.state == .running, let started = item.startedAt {
            return "正在运行（\(Self.shortTime(started)) 启动）"
        }
        guard let date = item.lastRunAt else { return "未知" }
        let text = Self.shortTime(date)
        return item.lastRunPrecision == .exact ? text : "约 \(text)（按日志文件修改时间）"
    }

    private var nextRunText: String {
        if item.disabled || item.state == .disabled { return "已禁用，不会再运行" }
        if item.state == .stale { return "配置已失效，不会运行" }
        let upcoming = scheduledTriggers.compactMap { trigger in trigger.nextRunAt.map { ($0, trigger.nextRunIsEstimate) } }
        guard let next = upcoming.min(by: { $0.0 < $1.0 }) else {
            if scheduledTriggers.contains(where: { $0.kind == .watchPaths }) { return "文件变化时" }
            return scheduledTriggers.contains(where: { $0.kind == .startInterval }) ? "未知（还没有上次运行时间）" : "未知"
        }
        return next.1 ? "预计 \(Self.shortTime(next.0))" : Self.shortTime(next.0)
    }

    private func logResultText(_ result: LogLastRun) -> String {
        if let error = result.error { return "查询失败：\(error)" }
        guard let date = result.date else {
            return "最近 \(DashboardViewModel.logWindowHours(for: item)) 小时的系统日志里没有它的记录。"
        }
        return "系统日志最近一次记录：\(Self.shortTime(date))\n\(result.line ?? "")"
    }

    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private var recentRunDescription: String {
        guard let date = item.lastRunAt else { return "未知" }
        let dateText = date.formatted(date: .abbreviated, time: .shortened)
        return item.lastRunPrecision == .exact ? dateText : "约 \(dateText)"
    }

    private func reloadHistory() {
        history = (try? viewModel.history(for: item.id)) ?? []
    }

    private var readOnlyMessage: String {
        if item.sourceType == .loginItem || item.sourceType == .embeddedLoginItem {
            return item.startupOverviewReadOnlyDescription
        }
        if item.scope == .user {
            return "该来源只读，普通操作不会修改它。"
        }
        return "系统或全局项目只读，普通操作不会修改它。"
    }

    private var startupOverviewScopeDescription: String {
        switch item.sourceType {
        case .loginItem, .launchAgent, .embeddedLoginItem:
            return item.startupOverviewAccessDisplayName
        default:
            return item.scope.displayName
        }
    }

    private var enabledStatusDescription: String {
        if item.disabled || item.state == .disabled {
            return "已禁用"
        }
        if item.state == .enabled || item.state == .running {
            return "已启用"
        }
        return "未知"
    }

    private var statusColor: Color {
        switch item.state {
        case .running: return .green
        case .failed, .stale: return .red
        case .systemReadonly: return .gray
        case .disabled, .stopped: return .orange
        default: return .blue
        }
    }

    private func evidenceIcon(for severity: EvidenceSeverity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "xmark.octagon"
        }
    }

    private func evidenceColor(for severity: EvidenceSeverity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.size(12)) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.size(16))
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: UIScale.size(12)))
    }
}

private struct DetailGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: UIScale.size(14)) {
            content()
        }
    }
}

private struct DetailValue: View {
    let label: String
    let value: String
    var selectable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if selectable {
                Text(value)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } else {
                Text(value)
                    .font(.subheadline)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Structured AI result: summary paragraph, confidence badge, then one row per list item (never truncated).
private struct AnalysisRecordView: View {
    let record: AnalysisRecord
    let time: String

    private var unstructured: Bool { record.evidence == [AnalysisResult.unstructuredMarker] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if unstructured {
                Label("模型未按格式返回，下面是原文", systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(record.summary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if !unstructured {
                    Text("置信度 \(confidenceLevel) · \(Int((record.confidence * 100).rounded()))%")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(confidenceColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(confidenceColor)
                }
                Text("\(record.model) · \(time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !unstructured {
                if !record.projectUsefulness.isEmpty {
                    block("项目用途") {
                        Text(record.projectUsefulness)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                list("风险", items: record.risks, icon: "exclamationmark.triangle.fill", color: .orange)
                list("依赖", items: record.dependencies, icon: "link", color: .secondary)
                list("证据", items: record.evidence, icon: "doc.text", color: .secondary)
            }

            if let raw = record.rawResponse, !unstructured {
                DisclosureGroup("原始返回") {
                    ScrollView {
                        Text(raw)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12 * UIScale.factor / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private var confidenceLevel: String {
        record.confidence >= 0.75 ? "高" : record.confidence >= 0.5 ? "中" : "低"
    }

    private var confidenceColor: Color {
        record.confidence >= 0.75 ? .green : record.confidence >= 0.5 ? .blue : .orange
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func list(_ title: String, items: [String], icon: String, color: Color) -> some View {
        if !items.isEmpty {
            block("\(title)（\(items.count)）") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: icon)
                                .font(.caption)
                                .foregroundStyle(color)
                            Text(entry)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
