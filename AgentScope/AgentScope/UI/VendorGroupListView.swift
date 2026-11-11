import AgentScopeCore
import AppKit
import SwiftUI

/// Main list: one row per app / vendor, sectioned by purpose, expandable into the concrete items.
struct VendorGroupListView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var expandedGroupIDs: Set<String> = []
    @State private var uninstallRequest: UninstallRequest?

    var body: some View {
        let groups = viewModel.visibleVendorGroups
        VStack(spacing: 0) {
            if let coverage = viewModel.sourceFilter.coverageDescription, viewModel.purposeFilter == nil {
                Label(coverage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.blue.opacity(0.06))
            }

            if groups.isEmpty, viewModel.loadState != .loading {
                emptyState
            } else {
                List(selection: $viewModel.selectedServiceID) {
                    ForEach(sections(groups), id: \.purpose) { section in
                        Section {
                            ForEach(section.groups) { group in
                                groupRow(group)
                            }
                        } header: {
                            Label(
                                "\(section.purpose.displayName) · \(section.groups.count)",
                                systemImage: section.purpose.symbolName
                            )
                        }
                    }
                }
                .listStyle(.inset)
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
    }

    private func requestUninstall(_ group: VendorGroup) {
        uninstallRequest = UninstallRequest(plan: viewModel.uninstallPlan(for: group.items, title: group.name))
    }

    @ViewBuilder
    private func groupRow(_ group: VendorGroup) -> some View {
        let onUninstall: (() -> Void)? = viewModel.canUninstall(group) && !viewModel.uninstallInProgress
            ? { requestUninstall(group) } : nil
        if group.items.count == 1, let item = group.items.first {
            VendorGroupRowView(group: group, showsChevronSpace: true, onUninstall: onUninstall)
                .tag(item.id)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedGroupIDs.contains(group.id) },
                    set: { expanded in
                        if expanded {
                            expandedGroupIDs.insert(group.id)
                        } else {
                            expandedGroupIDs.remove(group.id)
                        }
                    }
                )
            ) {
                ForEach(group.items) { item in
                    VendorItemRowView(item: item, groupSummary: group.summary)
                        .tag(item.id)
                }
            } label: {
                VendorGroupRowView(group: group, showsChevronSpace: false, onUninstall: onUninstall)
            }
        }
    }

    private func sections(_ groups: [VendorGroup]) -> [(purpose: PurposeCategory, groups: [VendorGroup])] {
        let grouped = Dictionary(grouping: groups, by: \.purpose)
        return PurposeCategory.allCases.compactMap { purpose in
            grouped[purpose].map { (purpose, $0) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(viewModel.sourceFilter == .attention ? "没有需要关注的项目" : "没有匹配的项目")
                .font(.headline)
            Text("调整筛选或搜索条件，或点击刷新重新扫描。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VendorGroupRowView: View {
    let group: VendorGroup
    let showsChevronSpace: Bool
    var onUninstall: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.size(10)) {
            icon
                .frame(width: 30, height: 30)
                .padding(.leading, showsChevronSpace ? 14 : 0)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)
                    if group.isLeftover {
                        badge("疑似残留", color: .red)
                    } else if group.needsAttention {
                        badge("需关注", color: .orange)
                    }
                }
                if !group.summary.isEmpty {
                    Text(group.summary)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if group.runningCount > 0 {
                    Label("\(group.runningCount) 运行中", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .imageScale(.small)
                } else {
                    Text("未运行")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(group.items.count) 项")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let onUninstall, group.isLeftover {
                    Button(role: .destructive, action: onUninstall) {
                        Label("卸载…", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("停止并把残留文件移到废纸篓")
                }
            }
        }
        .padding(.vertical, UIScale.size(4))
        .contextMenu {
            if let onUninstall {
                Button(role: .destructive, action: onUninstall) {
                    Label(group.isLeftover ? "卸载残留…" : "卸载 / 删除…", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name)，\(group.summary)，\(caption)，\(group.runningCount) 个运行中")
    }

    private var caption: String {
        [group.composition, group.organization, nextRunText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Earliest upcoming run among the group's items that are not running right now.
    private var nextRunText: String? {
        let upcoming = group.items
            .filter { $0.state != .running }
            .flatMap { item in item.triggers ?? [] }
            .compactMap { trigger in trigger.nextRunAt.map { ($0, trigger.nextRunIsEstimate) } }
            .min { $0.0 < $1.0 }
        guard let upcoming else { return nil }
        return (upcoming.1 ? "预计下次 " : "下次 ") + ServiceDetailView.shortTime(upcoming.0)
    }

    @ViewBuilder
    private var icon: some View {
        if let path = group.iconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: group.purpose.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct VendorItemRowView: View {
    let item: ServiceItem
    let groupSummary: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let summary = item.summary, summary != groupSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(item.state.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, UIScale.size(2))
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String {
        var parts = [item.sourceType.displayName]
        if let trigger = item.triggers?.first?.summary {
            parts.append(trigger)
        }
        if item.state != .running,
           let next = item.triggers?.compactMap({ trigger in trigger.nextRunAt.map { ($0, trigger.nextRunIsEstimate) } })
               .min(by: { $0.0 < $1.0 }) {
            parts.append((next.1 ? "预计下次 " : "下次 ") + ServiceDetailView.shortTime(next.0))
        }
        if item.ownerAppStatus == .missing {
            parts.append("所属应用已不在本机")
        }
        return parts.joined(separator: " · ")
    }

    private var stateColor: Color {
        switch item.state {
        case .running: return .green
        case .failed, .stale: return .red
        case .disabled, .stopped: return .orange
        default: return .blue
        }
    }
}
