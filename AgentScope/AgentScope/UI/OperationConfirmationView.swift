import AgentScopeCore
import SwiftUI

struct OperationConfirmationView: View {
    let item: ServiceItem
    let action: OperationAction
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("确认\(action.displayName)", systemImage: action.systemImage)
                .font(.title2.weight(.semibold))

            Text("即将对用户 LaunchAgent 执行此操作。系统服务不会从这里被修改。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ConfirmationValue(label: "服务", value: item.name)
                ConfirmationValue(label: "作用域", value: item.scope.displayName)
                ConfirmationValue(label: "配置", value: item.configurationPath ?? "未知")
            }

            Label("涉及配置变更的操作会先创建本地备份。", systemImage: "archivebox")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("确认\(action.displayName)", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UIScale.size(24))
        .frame(width: UIScale.size(430))
    }
}

private struct ConfirmationValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
