import AgentScopeCore
import AppKit
import SwiftUI

struct ServiceListView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var expandedLoginItemGroupID: String?

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.globalWarnings.isEmpty {
                warningBanner(warnings: viewModel.globalWarnings)
            }

            if viewModel.showsVendorGroups {
                VendorGroupListView(viewModel: viewModel)
            } else if viewModel.sourceFilter == .projects {
                ProjectGroupListView(viewModel: viewModel)
            } else if viewModel.sourceFilter == .loginItems {
                LoginItemGroupListView(
                    viewModel: viewModel,
                    expandedGroupID: $expandedLoginItemGroupID,
                    unavailableWarnings: viewModel.startupOverviewWarnings
                )
            } else if viewModel.visibleItems.isEmpty, viewModel.loadState != .loading {
                emptyState
            } else {
                List(viewModel.visibleItems, selection: $viewModel.selectedServiceID) { item in
                    ServiceRowView(item: item)
                        .tag(item.id)
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "搜索应用、用途、说明、路径或标签")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("排序", selection: $viewModel.sort) {
                        ForEach(ServiceSort.allCases, id: \.self) { sort in
                            Text(sort.displayName).tag(sort)
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .overlay {
            if viewModel.loadState == .loading {
                ProgressView("扫描中…")
                    .padding(UIScale.size(18))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func warningBanner(warnings: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("部分来源扫描失败")
                    .font(.subheadline.weight(.semibold))
                ForEach(warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(UIScale.size(10))
        .background(.orange.opacity(0.10))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("未发现审计条目")
                .font(.headline)
            Text("调整筛选条件或点击刷新重新扫描自动启动项与定时任务。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoginItemGroupListView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Binding var expandedGroupID: String?
    let unavailableWarnings: [String]

    var body: some View {
        VStack(spacing: 0) {
            coverageBanner

            if !unavailableWarnings.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("部分启动项来源扫描失败")
                            .font(.caption.weight(.semibold))
                        ForEach(unavailableWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(UIScale.size(10))
                .background(.orange.opacity(0.10))
            }

            if viewModel.visibleLoginItemGroups.isEmpty, viewModel.loadState != .loading {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("未发现启动项")
                        .font(.headline)
                    Text("可点击刷新重新扫描已支持的启动项来源。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: $viewModel.selectedServiceID) {
                    ForEach(viewModel.visibleLoginItemGroups) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedGroupID == group.id },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedGroupID = group.id
                                    } else if expandedGroupID == group.id {
                                        expandedGroupID = nil
                                    }
                                }
                            )
                        ) {
                            ForEach(group.items) { item in
                                LoginItemChildRowView(item: item)
                                    .tag(item.id)
                            }
                        } label: {
                            LoginItemApplicationRowView(group: group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var coverageBanner: some View {
        Label(
            SourceFilter.loginItems.coverageDescription ?? "",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.size(10))
        .background(.blue.opacity(0.06))
    }
}

private struct LoginItemApplicationRowView: View {
    let group: LoginItemApplicationGroup

    var body: some View {
        HStack(spacing: 10) {
            applicationIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.applicationName)
                    .font(.headline)
                    .lineLimit(1)
                Text("项目：\(group.project?.displayName ?? "未识别")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(group.sourceSummary) · \(group.accessSummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(group.enabledState.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(enabledStateColor)
                Text(group.stateSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(group.items.count) 个子项")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, UIScale.size(4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.applicationName)，\(group.sourceSummary)，\(group.accessSummary)，\(group.enabledState.displayName)，\(group.stateSummary)，\(group.items.count) 个子项")
    }

    @ViewBuilder
    private var applicationIcon: some View {
        if let applicationPath = group.applicationPath,
           FileManager.default.fileExists(atPath: applicationPath),
           FileManager.default.isReadableFile(atPath: applicationPath) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: applicationPath))
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var enabledStateColor: Color {
        switch group.enabledState {
        case .enabled: return .green
        case .disabled: return .orange
        case .partiallyEnabled: return .blue
        case .unknown: return .secondary
        }
    }
}

private struct LoginItemChildRowView: View {
    let item: ServiceItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if item.isReadOnlyInStartupOverview {
                        Text("只读")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(item.sourceType.displayName) · \(item.startupOverviewAccessDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("项目：\(item.project?.displayName ?? "未识别")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(item.triggers?.first?.summary ?? "触发条件未知")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("应用/程序路径：\(item.programPath ?? item.configurationPath ?? "未知")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            Text(item.state.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, UIScale.size(4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [item.name, "\(item.sourceType.displayName) · \(item.startupOverviewAccessDisplayName)", item.state.displayName]
        if let project = item.project {
            parts.append("项目：\(project.displayName)")
        }
        if let trigger = item.triggers?.first {
            parts.append(trigger.summary)
        }
        if item.isReadOnlyInStartupOverview {
            parts.append("只读")
        }
        return parts.joined(separator: "，")
    }
}

private struct ProjectGroupListView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        if viewModel.visibleProjectGroups.isEmpty, viewModel.loadState != .loading {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("未发现项目归属")
                    .font(.headline)
                Text("项目视图按项目归属聚合，不是另一类启动来源。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $viewModel.selectedServiceID) {
                ForEach(viewModel.visibleProjectGroups) { group in
                    Section {
                        ForEach(group.items) { item in
                            ServiceRowView(item: item)
                                .tag(item.id)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.project.displayName)
                                .font(.headline)
                            Text("项目 · \(group.items.count) 个来源条目")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct ServiceRowView: View {
    let item: ServiceItem

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    if isReadonly {
                        Text("只读")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(item.sourceType.displayName) · \(item.scope.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let project = item.project {
                    Text("项目：\(project.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let trigger = item.triggers?.first {
                    Text(trigger.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            Text(item.state.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, UIScale.size(4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var isReadonly: Bool {
        item.scope != .user || item.state == .systemReadonly
    }

    private var stateColor: Color {
        switch item.state {
        case .running: return .green
        case .failed, .stale: return .red
        case .systemReadonly: return .gray
        case .disabled, .stopped: return .orange
        default: return .blue
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.name, item.state.displayName, "\(item.sourceType.displayName) · \(item.scope.displayName)"]
        if let project = item.project {
            parts.append("项目：\(project.displayName)")
        }
        if let trigger = item.triggers?.first {
            parts.append(trigger.summary)
        }
        return parts.joined(separator: "，")
    }
}
