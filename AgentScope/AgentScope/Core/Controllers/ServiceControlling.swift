import Foundation

public protocol ServiceControlling: Sendable {
    func start(_ item: ServiceItem) async throws
    func stop(_ item: ServiceItem) async throws
    func restart(_ item: ServiceItem) async throws
    func setEnabled(_ enabled: Bool, for item: ServiceItem) async throws
    func testRun(_ item: ServiceItem) async throws
}

extension LaunchAgentController: ServiceControlling {}
