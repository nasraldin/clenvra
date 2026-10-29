import Foundation
import Security

/// Who signed a program, read from its code signature with the public Security framework. Only the executable is
/// checked (not every resource of a bundle), so reading is quick enough for a details view.
public struct CodeSignature: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Part of macOS or signed by Apple.
        case apple
        /// Distributed through the Mac App Store.
        case appStore
        /// Signed with a Developer ID, outside the App Store.
        case developerID
        /// Signed with another certificate, for example a development one.
        case otherCertificate
        /// Signed without an identity ("ad hoc"), as builds made on the same Mac are.
        case adHoc
        case unsigned
        /// The signature is broken: the program changed after it was signed.
        case invalid
    }

    public let kind: Kind
    /// The signer's name as written in the certificate, for example "Developer ID Application: Example Inc (TEAM)".
    public let authority: String?
    public let teamIdentifier: String?

    /// `nil` when nothing exists at `path`.
    public static func read(at path: String) -> CodeSignature? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &staticCode) == errSecSuccess,
            let code = staticCode
        else { return CodeSignature(kind: .unsigned, authority: nil, teamIdentifier: nil) }

        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil)
        if validity == errSecCSUnsigned { return CodeSignature(kind: .unsigned, authority: nil, teamIdentifier: nil) }

        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let information = info as? [String: Any] ?? [:]
        let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let authority = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String

        guard validity == errSecSuccess else {
            return CodeSignature(kind: .invalid, authority: authority, teamIdentifier: team)
        }
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let kind: Kind =
            if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
                .adHoc
            } else if satisfies(code, "anchor apple") {
                .apple
            } else if satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]") {
                .appStore
            } else if satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]") {
                .developerID
            } else {
                .otherCertificate
            }
        return CodeSignature(kind: kind, authority: authority, teamIdentifier: team)
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement)
            == errSecSuccess
    }
}
