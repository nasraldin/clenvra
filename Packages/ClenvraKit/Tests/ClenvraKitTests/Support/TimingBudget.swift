import Foundation

/// Upper bounds for timing assertions. Real Macs get the strict bound; shared CI runners stall for seconds now and then
/// (a cancelled scan once took 5 s there and 0.1 s locally), so they get 10 s extra. Correctness checks stay the same.
enum TimingBudget {
    /// check.sh forwards GitHub's `CI=true` as `TEST_RUNNER_CI`, which xcodebuild hands to tests as `CI`.
    static let ciSlack: Duration = ProcessInfo.processInfo.environment["CI"] == "true" ? .seconds(10) : .zero

    static func upTo(_ bound: Duration) -> Duration { bound + ciSlack }
}
