import Foundation

public enum OperationAction: String, Codable, Hashable, Sendable {
    case start
    case stop
    case restart
    case enable
    case disable
    case testRun
    case backup
    case restore
    case uninstall
}

public struct OperationRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let serviceID: String
    public let action: OperationAction
    public let timestamp: Date
    public let succeeded: Bool
    public let message: String
    public let backupPath: String?

    public init(
        id: UUID = UUID(),
        serviceID: String,
        action: OperationAction,
        timestamp: Date = Date(),
        succeeded: Bool,
        message: String,
        backupPath: String? = nil
    ) {
        self.id = id
        self.serviceID = serviceID
        self.action = action
        self.timestamp = timestamp
        self.succeeded = succeeded
        self.message = message
        self.backupPath = backupPath
    }
}
