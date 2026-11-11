import Foundation

public struct ProjectAttributor: Sendable {
    public init() {}

    public func project(for item: ServiceItem) -> ProjectIdentity? {
        if let project = item.project { return project }

        if item.sourceType == .docker {
            return nil
        }
        if item.sourceType == .homebrew {
            return ProjectIdentity(
                id: "homebrew:\(item.name)",
                displayName: item.name,
                rootPath: nil,
                kind: .homebrewFormula,
                confidence: 0.85,
                evidence: ["Homebrew service name: \(item.name)"]
            )
        }

        guard let programPath = item.programPath else { return nil }
        let url = URL(fileURLWithPath: programPath)
        if programPath.hasSuffix(".app") || programPath.contains(".app/") {
            let appURL = appBundleURL(for: url)
            return ProjectIdentity(
                id: "app:\(appURL.path)",
                displayName: appURL.deletingPathExtension().lastPathComponent,
                rootPath: appURL.path,
                kind: .appBundle,
                confidence: 1.0,
                evidence: ["Executable belongs to App bundle: \(appURL.path)"]
            )
        }

        if let gitRoot = gitRoot(for: url) {
            return ProjectIdentity(
                id: "git:\(gitRoot.path)",
                displayName: gitRoot.lastPathComponent,
                rootPath: gitRoot.path,
                kind: .gitRepository,
                confidence: 0.95,
                evidence: ["Executable is under Git repository: \(gitRoot.path)"]
            )
        }

        if item.sourceType == .shellStartup,
           let configurationPath = item.configurationPath {
            return ProjectIdentity(
                id: "shell:\(configurationPath)",
                displayName: URL(fileURLWithPath: configurationPath).lastPathComponent,
                rootPath: configurationPath,
                kind: .shellReference,
                confidence: 0.55,
                evidence: ["Referenced by shell startup file: \(configurationPath)"]
            )
        }

        return nil
    }

    private func gitRoot(for url: URL) -> URL? {
        var candidate = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let fileManager = FileManager.default
        while candidate.path != "/" {
            let marker = candidate.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return fileManager.fileExists(atPath: "/.git") ? URL(fileURLWithPath: "/") : nil
    }

    private func appBundleURL(for url: URL) -> URL {
        var candidate = url
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return url
    }
}

public struct ServiceReviewEngine: Sendable {
    public init() {}

    public func assess(_ item: ServiceItem) -> ReviewAssessment {
        if item.validity == .missingTarget || item.validity == .missingInterpreter || item.validity == .invalidConfiguration {
            return ReviewAssessment(
                status: .invalid,
                confidence: 0.98,
                evidence: ["配置或执行目标无效：\(item.validity.displayName)"]
            )
        }

        if item.state == .failed {
            return ReviewAssessment(
                status: .abnormal,
                confidence: 0.95,
                evidence: ["launchd 报告服务失败"]
            )
        }

        if let execution = item.executionEvidence, item.state != .running {
            if execution.consecutiveFailures > 0 || (execution.lastExitCode != nil && execution.lastExitCode != 0) {
                return ReviewAssessment(
                    status: .abnormal,
                    confidence: 0.92,
                    evidence: ["\(execution.source) 连续失败 \(execution.consecutiveFailures) 次"]
                )
            }
        }

        if let programPath = item.programPath,
           programPath.hasPrefix("/"),
           !FileManager.default.fileExists(atPath: programPath) {
            return ReviewAssessment(
                status: .invalid,
                confidence: 0.9,
                evidence: ["执行目标不存在：\(programPath)"]
            )
        }

        if item.ownerAppStatus == .missing {
            return ReviewAssessment(
                status: .possiblyStale,
                confidence: 0.85,
                evidence: ["所属应用已不在本机，疑似卸载后的残留，可以考虑清理"]
            )
        }

        if item.state == .stale {
            return ReviewAssessment(
                status: .possiblyStale,
                confidence: 0.8,
                evidence: [item.evidence.first?.detail ?? "疑似残留，已不会被系统启动"]
            )
        }

        if item.validity == .healthy {
            return ReviewAssessment(
                status: .retain,
                confidence: 0.86,
                evidence: ["配置有效，未发现确定性异常"]
            )
        }

        if item.disabled {
            return ReviewAssessment(
                status: .possiblyStale,
                confidence: 0.62,
                evidence: ["项目已被禁用，是否仍有用途需要人工确认"]
            )
        }

        if item.state == .stopped && item.sourceType == .launchAgent {
            return ReviewAssessment(
                status: .retain,
                confidence: 0.72,
                evidence: ["当前未运行，但停止状态本身不代表配置失效"]
            )
        }

        return ReviewAssessment(
            status: .unclear,
            confidence: 0.45,
            evidence: ["缺少足够的执行或目标信息，需要人工确认"]
        )
    }
}
