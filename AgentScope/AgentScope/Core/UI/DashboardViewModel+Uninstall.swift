import Foundation

public struct LogLastRun: Hashable, Sendable {
    public let date: Date?
    public let line: String?
    public let error: String?
}

public protocol LaunchdLogQuerying: Sendable {
    func lastActivity(label: String, hours: Int) async throws -> (Date, String)?
}

/// Reads launchd's own spawn/exit lines from the unified log. Slow (~10 s), so only on demand.
public struct LaunchdLogQuery: LaunchdLogQuerying {
    private let commandRunner: any CommandExecuting

    public init(commandRunner: any CommandExecuting = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func lastActivity(label: String, hours: Int) async throws -> (Date, String)? {
        guard !label.contains("\""), !label.contains("\\") else { return nil }
        let result = try await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/log"),
            arguments: [
                "show", "--last", "\(hours)h", "--style", "compact",
                "--predicate", "process == \"launchd\" AND eventMessage CONTAINS \"\(label)\""
            ],
            timeout: 180,
            environment: nil
        )
        return Self.lastActivity(in: result.stdout)
    }

    /// Last compact-style line, e.g. `2026-11-11 08:32:34.600 Df launchd[1:…] … service inactive: label`.
    static func lastActivity(in output: String) -> (Date, String)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let text = String(line)
            guard text.count > 23, let date = formatter.date(from: String(text.prefix(23))) else { continue }
            return (date, text)
        }
        return nil
    }
}

extension DashboardViewModel {
    public func canUninstall(_ item: ServiceItem) -> Bool {
        uninstaller != nil && UninstallPlanner.isEligible(item)
    }

    public func canUninstall(_ group: VendorGroup) -> Bool {
        uninstaller != nil && group.items.contains(where: UninstallPlanner.isEligible)
    }

    public func uninstallPlan(for items: [ServiceItem], title: String) -> UninstallPlan {
        UninstallPlanner.plan(title: title, items: items, allItems: self.items)
    }

    /// Returns true when everything planned was moved.
    @discardableResult
    public func uninstall(_ plan: UninstallPlan, selectedOptional: Set<String>) async -> Bool {
        guard let uninstaller, !uninstallInProgress else { return false }
        uninstallInProgress = true
        uninstallMessage = nil
        defer { uninstallInProgress = false }
        do {
            let report = try await uninstaller.uninstall(plan, selectedOptional: selectedOptional)
            let succeeded = report.failures.isEmpty
            for serviceID in plan.serviceIDs {
                try? operationRecorder?.record(OperationRecord(
                    serviceID: serviceID,
                    action: .uninstall,
                    succeeded: succeeded,
                    message: report.summary
                ))
            }
            try? backgroundTaskStore?.remove(
                labels: Set(plan.labels),
                paths: Set(report.moved.map(\.from))
            )
            uninstallMessage = (succeeded
                ? "已卸载「\(plan.title)」。需要恢复时，到废纸篓找到文件，放回下面的原位置：\n\n"
                : "「\(plan.title)」只完成了一部分：\n\n") + report.summary
            await refresh()
            return succeeded
        } catch {
            uninstallMessage = error.localizedDescription
            return false
        }
    }

    /// Twice the run interval (at least 1 h), 24 h for calendar jobs: a 24 h query takes about a minute.
    public static func logWindowHours(for item: ServiceItem) -> Int {
        let interval = item.triggers?
            .first { $0.kind == .startInterval }
            .flatMap { Double($0.expression ?? "") }
        guard let interval else { return 24 }
        return min(24, max(1, Int((interval * 2 / 3600).rounded(.up))))
    }

    public func queryLastRunFromLog(_ item: ServiceItem) async {
        guard let logQuery, let label = item.label, logQueryInProgress == nil else { return }
        logQueryInProgress = item.id
        defer { logQueryInProgress = nil }
        do {
            let found = try await logQuery.lastActivity(label: label, hours: Self.logWindowHours(for: item))
            logLastRuns[item.id] = LogLastRun(date: found?.0, line: found?.1, error: nil)
        } catch {
            logLastRuns[item.id] = LogLastRun(date: nil, line: nil, error: error.localizedDescription)
        }
    }
}
