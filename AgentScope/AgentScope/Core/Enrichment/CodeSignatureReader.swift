import Foundation
import Security

public struct SigningInfo: Codable, Hashable, Sendable {
    public var signature: SignatureClass
    public var teamID: String?
    public var organization: String?
    public var signedPath: String

    public init(signature: SignatureClass, teamID: String? = nil, organization: String? = nil, signedPath: String) {
        self.signature = signature
        self.teamID = teamID
        self.organization = organization
        self.signedPath = signedPath
    }
}

public protocol CodeSignatureReading: Sendable {
    func read(path: String) -> SigningInfo?
}

/// Reads code signatures in-process via Security.framework (no `codesign` subprocess, no hashing of the bundle).
public struct SecurityCodeSignatureReader: CodeSignatureReading {
    public init() {}

    public func read(path: String) -> SigningInfo? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return SigningInfo(signature: .invalid, signedPath: path)
        }

        var rawInfo: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        )
        guard status == errSecSuccess, let info = rawInfo as? [String: Any] else {
            return SigningInfo(signature: .invalid, signedPath: path)
        }
        guard info[kSecCodeInfoIdentifier as String] != nil else {
            return SigningInfo(signature: .unsigned, signedPath: path)
        }

        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String).flatMap(Self.nonEmpty)
        let certificates = (info[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        let leafSummary = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isPlatform = info[kSecCodeInfoPlatformIdentifier as String] != nil

        return SigningInfo(
            signature: Self.classify(
                teamID: teamID,
                leafSummary: leafSummary,
                isAdhoc: flags & 0x0002 != 0 || certificates.isEmpty,
                isPlatform: isPlatform
            ),
            teamID: teamID,
            organization: leafSummary.flatMap(Self.organization(fromCertificateSummary:)),
            signedPath: path
        )
    }

    static func classify(teamID: String?, leafSummary: String?, isAdhoc: Bool, isPlatform: Bool) -> SignatureClass {
        if isPlatform { return .apple }
        if isAdhoc { return .adhoc }
        let summary = leafSummary ?? ""
        if teamID == nil, summary.hasPrefix("Software Signing") || summary.hasPrefix("Apple ") {
            return .apple
        }
        if summary.hasPrefix("Developer ID") || teamID != nil {
            return .developerID
        }
        return .unknown
    }

    /// "Developer ID Application: Docker Inc (9BNSXJN65R)" -> "Docker Inc"
    static func organization(fromCertificateSummary summary: String) -> String? {
        guard let colon = summary.firstIndex(of: ":") else { return nil }
        var name = summary[summary.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = name[..<open].trimmingCharacters(in: .whitespaces)
        }
        return nonEmpty(name)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
