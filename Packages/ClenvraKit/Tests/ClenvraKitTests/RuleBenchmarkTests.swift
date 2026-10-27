import Foundation
import Testing

@testable import ClenvraKit

/// Read-only timing of every catalog rule against a real home folder. Opt-in: `CLENVRA_BENCH_HOME=/Users/me`.
/// Never deletes anything: it only calls `RuleScanner.scan`.
@Suite("Rule benchmark")
struct RuleBenchmarkTests {
    private static let home = ProcessInfo.processInfo.environment["CLENVRA_BENCH_HOME"]

    @Test("time each rule against a real home folder", .enabled(if: home != nil, "set CLENVRA_BENCH_HOME"))
    func timeRules() async throws {
        let home = try #require(Self.home)
        let policy = ProtectionPolicy(home: home)
        let clock = ContinuousClock()
        var total = Duration.zero
        for rule in RuleCatalog.standard {
            let start = clock.now
            let result = await RuleScanner.scan(rule, home: home, policy: policy, ownerState: { _ in .notRunning })
            let elapsed = clock.now - start
            total += elapsed
            guard result.rootExists else { continue }
            let bytes = result.candidates.reduce(0) { $0 + $1.allocatedSize }
            print(
                "BENCH \(rule.id): \(elapsed) · \(result.candidates.count) items · "
                    + "\(bytes.formatted(.byteCount(style: .file)))")
        }
        print("BENCH total: \(total)")
    }
}

@Suite("Storage benchmark")
struct StorageBenchmarkTests {
    private static let root = ProcessInfo.processInfo.environment["CLENVRA_BENCH_ROOT"]

    @Test("time a storage scan of a real folder", .enabled(if: root != nil, "set CLENVRA_BENCH_ROOT"))
    func timeScan() async throws {
        let root = try #require(Self.root)
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try await StorageScanner.scan(root: root)
        let aggregate = snapshot.aggregate(at: root)
        print(
            "BENCH scan \(root): \(clock.now - start) · files \(aggregate?.fileCount ?? 0) · "
                + "dirs \(snapshot.directories.count) · skipped \(snapshot.skipped.count)")
    }
}
