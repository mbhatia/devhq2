import Foundation
import XCTest
@testable import DevHQ

/// Opt-in throughput checks. Run through `Scripts/terminal-benchmark.sh`; they
/// are not normal unit tests because each case sends 150 MiB through a real PTY.
final class TerminalBenchmarkTests: XCTestCase {
    @MainActor
    func testCat150MiBFixturesThroughProductionPTYPath() throws {
        guard ProcessInfo.processInfo.environment["DEVHQ_RUN_TERMINAL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Run Scripts/terminal-benchmark.sh to execute terminal throughput checks")
        }
        guard TerminalSession.usesGhosttyRenderer else {
            throw XCTSkip("The production throughput check requires the Ghostty VT bridge")
        }
        let fixtureDirectory = try XCTUnwrap(
            ProcessInfo.processInfo.environment["DEVHQ_TERMINAL_BENCHMARK_FIXTURES"],
            "Set by Scripts/terminal-benchmark.sh"
        )
        let maximumSeconds = try XCTUnwrap(
            ProcessInfo.processInfo.environment["DEVHQ_TERMINAL_BENCHMARK_MAX_SECONDS"]
                .flatMap(TimeInterval.init),
            "DEVHQ_TERMINAL_BENCHMARK_MAX_SECONDS must be numeric"
        )
        let repeats = try XCTUnwrap(
            ProcessInfo.processInfo.environment["DEVHQ_TERMINAL_BENCHMARK_REPEATS"]
                .flatMap(Int.init),
            "DEVHQ_TERMINAL_BENCHMARK_REPEATS must be an integer"
        )
        XCTAssertGreaterThan(repeats, 0)

        for fixtureName in ["ascii-150MiB.txt", "unicode-150MiB.txt"] {
            let fixture = URL(fileURLWithPath: fixtureDirectory).appendingPathComponent(fixtureName)
            let fixtureBytes = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber
            ).uint64Value
            XCTAssertEqual(fixtureBytes, 150 * 1024 * 1024, fixtureName)
            let completionMarker = "__DEVHQ_BENCHMARK_EOF_\(fixtureName)__"
            let expectedBytes = fixtureBytes + 2 + UInt64(completionMarker.utf8.count)

            for run in 1...repeats {
                let started = ContinuousClock.now
                let session = try TerminalSession(
                    rootURL: URL(fileURLWithPath: fixtureDirectory, isDirectory: true),
                    // Disable ONLCR so fixture bytes retain their exact byte count, then
                    // append a fresh-row visible sentinel after cat has reached EOF.
                    command: [
                        "/bin/sh", "-c", "stty -onlcr; cat \"$1\"; printf '\\r\\n%s' \"$2\"",
                        "benchmark", fixture.path, completionMarker
                    ]
                )
                defer { session.close() }

                let deadline = Date().addingTimeInterval(maximumSeconds + 5)
                while session.processedOutputByteCount < expectedBytes,
                      Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                }
                let elapsed = started.duration(to: .now)
                let elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000

                XCTAssertEqual(session.processedOutputByteCount, expectedBytes, fixtureName)
                XCTAssertLessThan(
                    elapsedSeconds,
                    maximumSeconds,
                    "\(fixtureName) PTY-to-Ghostty ingestion must be below \(maximumSeconds)s"
                )

                let exitDeadline = Date().addingTimeInterval(2)
                while session.exitStatus == nil, Date() < exitDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                }
                XCTAssertEqual(session.exitStatus, 0, fixtureName)
                XCTAssertTrue(session.visibleText.contains(completionMarker), fixtureName)
                print(
                    "terminal-benchmark fixture=\(fixtureName) run=\(run)/\(repeats) "
                        + "parsed_bytes=\(session.processedOutputByteCount) expected_bytes=\(expectedBytes) "
                        + "geometry=\(session.snapshot.columns)x\(session.snapshot.rows) "
                        + String(format: "seconds=%.6f", elapsedSeconds)
                )
            }
        }
    }
}
