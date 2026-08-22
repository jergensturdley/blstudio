import XCTest
@testable import BlStudio

/// Runs against the real `bl` binary when present. Uses only --dry-run / read-only
/// commands, so it is safe and free to execute. Skips cleanly on machines (like CI
/// runners) where bl is not installed.
final class IntegrationTests: XCTestCase {

    private func makeClient() throws -> BLClient? {
        let client = BLClient()
        guard (try? client.resolveBinary()) != nil else { return nil }
        return client
    }

    func testVersion() async throws {
        guard let client = try makeClient() else { throw XCTSkip("bl is not installed") }
        let version = try await client.cliVersion()
        XCTAssertTrue(version.contains("bl"), "unexpected version output: \(version)")
    }

    func testImageGenerateDryRun() async throws {
        guard let client = try makeClient() else { throw XCTSkip("bl is not installed") }
        let out = try await client.run(arguments: [
            "image", "generate", "--prompt", "unit test", "--dry-run", "--output", "json",
        ], timeoutSeconds: 60)
        XCTAssertEqual(out.exitCode, 0, "stderr: \(out.stderr)")
        // Dry-run prints the request that would be sent.
        XCTAssertTrue(out.stdout.contains("\"model\""), out.stdout)
        XCTAssertTrue(out.stdout.contains("unit test"), out.stdout)
    }

    func testAuthStatusParses() async throws {
        guard let client = try makeClient() else { throw XCTSkip("bl is not installed") }
        // Decoding success is the assertion; either authenticated or a clean error envelope.
        let status = try await client.authStatus()
        if let authenticated = status.authenticated {
            print("bl auth status: authenticated=\(authenticated)")
        }
    }
}
