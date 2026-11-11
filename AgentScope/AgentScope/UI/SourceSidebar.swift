import AgentScopeCore
import SwiftUI

struct SourceSidebar: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        List(selection: $viewModel.sidebarSelection) {
            Section("概览") {
                sourceRow(.all)
                sourceRow(.attention)
            }

            if !viewModel.purposeCounts.isEmpty {
                Section("按用途") {
                    ForEach(viewModel.purposeCounts, id: \.purpose) { entry in
                        row(
                            title: entry.purpose.displayName,
                            systemImage: entry.purpose.symbolName,
                            count: entry.count
                        )
                        .tag(SidebarItem.purpose(entry.purpose))
                    }
                }
            }

            Section("按启动方式") {
                ForEach(SourceFilter.mechanismFilters, id: \.self) { filter in
                    sourceRow(filter)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("AgentScope")
    }

    private func sourceRow(_ filter: SourceFilter) -> some View {
        row(title: filter.displayName, systemImage: filter.systemImage, count: viewModel.count(for: filter))
            .tag(SidebarItem.source(filter))
    }

    private func row(title: String, systemImage: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(count, format: .number)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
