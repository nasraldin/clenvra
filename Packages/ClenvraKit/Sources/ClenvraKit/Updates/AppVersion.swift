import Foundation

/// A version as apps and feeds write it ("1.10", "2.0b3", "1.0-rc.1", "4.2 (1234)"), compared the way people
/// expect: numerically, with pre-releases before the release. Text that is not a version does not parse, so an
/// unreadable version is reported as unknown instead of being guessed (AP-9).
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Pre-release stages in order; anything after the numbers that is not one of these ranks as `development`.
    enum Stage: Int, Sendable, Comparable {
        case development, alpha, beta, candidate, release

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Numeric components without trailing zeros, so "1.0" equals "1" (and "0" is empty).
    let numbers: [Int]
    let stage: Stage
    /// Numbers after the stage word ("beta.10" → [10]).
    let stageNumbers: [Int]

    public let description: String

    /// Longest version accepted; longer text is not a version and would only cost time.
    static let maximumLength = 64

    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rest.isEmpty, rest.count <= Self.maximumLength else { return nil }
        if let first = rest.first, first == "v" || first == "V" { rest = rest.dropFirst() }
        // Build metadata never orders versions: "2.0 (1234)", "2.0+build.5".
        if let cut = rest.firstIndex(where: { $0 == "(" || $0 == "+" }) { rest = rest[..<cut] }

        let numericPart = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard let numbers = Self.numbers(in: numericPart), !numbers.isEmpty else { return nil }
        let suffix = rest.dropFirst(numericPart.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._ ").union(.whitespaces))
            .lowercased()
        guard let (stage, stageNumbers) = Self.stage(of: suffix) else { return nil }

        self.numbers = Self.trimmed(numbers)
        self.stage = stage
        self.stageNumbers = Self.trimmed(stageNumbers)
        self.description = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A plain numeric version, for callers that already have numbers (e.g. the running macOS).
    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        numbers = Self.trimmed([major, minor, patch])
        stage = .release
        stageNumbers = []
        description = "\(major).\(minor).\(patch)"
    }

    /// The running macOS, to skip feed items that need a newer system.
    public static var currentSystem: AppVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return AppVersion(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.numbers == rhs.numbers && lhs.stage == rhs.stage && lhs.stageNumbers == rhs.stageNumbers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(numbers)
        hasher.combine(stage)
        hasher.combine(stageNumbers)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.numbers != rhs.numbers { return lexicographicallyLess(lhs.numbers, rhs.numbers) }
        if lhs.stage != rhs.stage { return lhs.stage < rhs.stage }
        return lexicographicallyLess(lhs.stageNumbers, rhs.stageNumbers)
    }

    // MARK: - Parsing

    private static func numbers(in text: Substring) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        // "1..2" or a trailing dot is not a version; overflowing numbers are not either.
        var numbers: [Int] = []
        for (index, part) in parts.enumerated() {
            if part.isEmpty {
                if index == parts.count - 1 && index > 0 { continue }
                return nil
            }
            guard let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    private static let stageWords: [(String, Stage)] = [
        ("alpha", .alpha), ("beta", .beta), ("rc", .candidate), ("pre", .candidate), ("preview", .candidate),
        ("dev", .development), ("a", .alpha), ("b", .beta), ("c", .candidate),
    ]

    /// The stage named by the suffix and the numbers after it; `nil` when the suffix is not a version suffix.
    private static func stage(of suffix: String) -> (Stage, [Int])? {
        guard !suffix.isEmpty else { return (.release, []) }
        let letters = String(suffix.prefix { $0.isLetter })
        // Bare numbers after the version ("1.0_1") are revisions after the release; unknown words rank first.
        let stage = letters.isEmpty ? .release : stageWords.first { $0.0 == letters }?.1 ?? .development
        let digits = suffix.dropFirst(letters.count)
            .split { !$0.isASCII || !$0.isNumber }
        var numbers: [Int] = []
        for part in digits {
            guard let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return (stage, numbers)
    }

    private static func trimmed(_ numbers: [Int]) -> [Int] {
        var numbers = numbers
        while numbers.last == 0 { numbers.removeLast() }
        return numbers
    }

    private static func lexicographicallyLess(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
