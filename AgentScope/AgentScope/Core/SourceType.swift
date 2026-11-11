public enum SourceType: String, Codable, Hashable, Sendable {
    case launchAgent
    case launchDaemon
    case loginItem
    case embeddedLoginItem
    case cron
    case periodic
    case shellStartup
    case homebrew
    case docker
    case tmux
    case process
    case privilegedHelper
    case systemExtension
    case kernelExtension
    case backgroundTask
    case unknown
}

public enum Scope: String, Codable, Hashable, Sendable {
    case user
    case global
    case system
}
