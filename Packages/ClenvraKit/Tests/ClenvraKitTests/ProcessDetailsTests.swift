import Darwin
import Foundation
import Testing

@testable import ClenvraKit

@Suite("ProcessDetails")
struct ProcessDetailsTests {
    @Test("reads this test process: name, path, a start date in the past, and its parent")
    func readsOwnProcess() throws {
        let details = try #require(ProcessDetails.read(pid: getpid()))

        #expect(details.pid == getpid())
        #expect(details.parentPID == getppid())
        #expect(!details.name.isEmpty)
        let path = try #require(details.executablePath)
        #expect(path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: path))
        let start = try #require(details.startDate)
        #expect(start < Date())
        #expect(start > Date().addingTimeInterval(-86_400))
        #expect(try #require(details.threads) >= 1)
        #expect(try #require(details.memoryBytes) > 0)
        let cpu = try #require(details.cpuPercent)
        #expect(cpu >= 0)
        #expect(cpu <= Double(ProcessInfo.processInfo.activeProcessorCount) * 100)
        #expect(details.user == NSUserName())
        let arguments = try #require(details.arguments)
        #expect(!arguments.isEmpty)
    }

    @Test("CPU time is in nanoseconds on every Mac (rusage counts Mach ticks on Apple silicon)")
    func cpuTimeMatchesGetrusage() throws {
        var spin = 0.0
        let begin = Date()
        while Date().timeIntervalSince(begin) < 0.2 { spin += sin(spin) + 1 }
        #expect(spin > 0)

        let ours = try #require(ProcessDetails.cpuTimeNanoseconds(pid: getpid()))
        let sampled = try #require(try ProcessSampler.defaultSampleSource().first { $0.pid == getpid() })
        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        let user = UInt64(usage.ru_utime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_utime.tv_usec) * 1000
        let system = UInt64(usage.ru_stime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_stime.tv_usec) * 1000
        let reference = Double(user + system)

        // Same process, read moments apart: within 30 % (a unit mix-up is off by 40×).
        #expect(Double(ours) > reference * 0.7)
        #expect(Double(ours) < reference * 1.3 + 50_000_000)
        // The CPU and Memory lists use the same units.
        #expect(Double(sampled.cpuTimeNanoseconds) > reference * 0.7)
        #expect(Double(sampled.cpuTimeNanoseconds) < reference * 1.3 + 50_000_000)
    }

    @Test("parses a KERN_PROCARGS2 buffer: count, path, padding, then the arguments")
    func parsesProcArgs() {
        var bytes: [UInt8] = withUnsafeBytes(of: Int32(2)) { Array($0) }
        bytes += Array("/bin/tool".utf8) + [0, 0, 0]
        bytes += Array("tool".utf8) + [0] + Array("-v".utf8) + [0]
        bytes += Array("HOME=/x".utf8) + [0]

        #expect(ProcessDetails.parseProcArgs(bytes) == ["tool", "-v"])
        #expect(ProcessDetails.parseProcArgs([1, 0]) == nil)
    }

    @Test("a process that has exited reads as nil")
    func goneProcessIsNil() throws {
        let child = Process()
        child.executableURL = URL(filePath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let pid = child.processIdentifier

        #expect(pid > 0)
        #expect(ProcessDetails.read(pid: pid) == nil)
    }
}
