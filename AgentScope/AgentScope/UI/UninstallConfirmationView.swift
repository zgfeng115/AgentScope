import AgentScopeCore
import SwiftUI

struct UninstallRequest: Identifiable {
    let id = UUID()
    let plan: UninstallPlan
}

/// Lists exactly what will be stopped and moved to the Trash before anything happens.
struct UninstallConfirmationView: View {
    let plan: UninstallPlan
    let onConfirm: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var selectedOptional: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * UIScale.factor / 2) {
            Label("卸载「\(plan.title)」", systemImage: "trash")
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !plan.bootouts.isEmpty {
                        section("先停止的后台服务") {
                            ForEach(plan.bootouts, id: \.self) { bootout in
                                row(icon: "stop.circle", text: bootout.target, admin: bootout.requiresAdmin)
                            }
                        }
                    }
                    if !plan.files.isEmpty {
                        section("移到废纸篓") {
                            ForEach(plan.files) { file in
                                row(icon: "doc", text: "\(file.kind.displayName)：\(file.path)", admin: file.requiresAdmin)
                            }
                        }
                    }
                    if !plan.cronEntries.isEmpty {
                        section("从 crontab 删除的行（会先备份）") {
                            ForEach(plan.cronEntries, id: \.self) { line in
                                row(icon: "calendar.badge.minus", text: "\(line.expression) \(line.command)", admin: false)
                            }
                        }
                    }
                    if !plan.optionalFiles.isEmpty {
                        section("一起删除？（默认不删）") {
                            ForEach(plan.optionalFiles) { file in
                                Toggle(isOn: binding(for: file.path)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(file.kind.displayName)：\(file.path)")
                                            .textSelection(.enabled)
                                        if let note = file.note {
                                            Text(note).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    if !plan.skipped.isEmpty {
                        section("保留不动") {
                            ForEach(plan.skipped, id: \.self) { skip in
                                row(icon: "lock", text: "\(skip.path)（\(skip.reason)）", admin: false)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(plan.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("文件会移到废纸篓；完成后会列出每个文件的原位置，需要时从废纸篓拖回即可。", systemImage: "arrow.uturn.backward.circle")
                if plan.requiresAdmin(selectedOptional: selectedOptional) {
                    Label("涉及系统目录，macOS 会弹出一次管理员密码框。", systemImage: "lock.shield")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                // No Return shortcut: a destructive action must be clicked deliberately.
                Button("卸载", role: .destructive) { onConfirm(selectedOptional) }
                    .disabled(plan.isEmpty)
            }
        }
        .padding(24 * UIScale.factor / 2)
        .frame(width: 430 * UIScale.factor)
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedOptional.contains(path) },
            set: { isOn in
                if isOn { selectedOptional.insert(path) } else { selectedOptional.remove(path) }
            }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(icon: String, text: String, admin: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text).textSelection(.enabled)
            if admin {
                Image(systemName: "lock.shield").foregroundStyle(.orange).help("需要管理员权限")
            }
        }
    }
}
