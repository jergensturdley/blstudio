import XCTest
@testable import BlStudio

/// Runs against the real `bl` binary when present. Uses only --dry-run / read-only
/// commands, so it is safe and free to execute.
final class IntegrationTests: XCTestCase {

    private func makeClient() throws -> BLClient {
        let client = BLClient()
        _ = try client.resolveBinary()  // throws (and skips) when bl is not installed
        return client
    }

    func testVersion() async throws {
        let client = try makeClient()
        let version = try await client.cliVersion()
        XCTAssertTrue(version.contains("bl"), "unexpected version output: \(version)")
    }

    func testImageGenerateDryRun() async throws {
        let client = try makeClient()
        let out = try await client.run(arguments: [
            "image", "generate", "--prompt", "unit test", "--dry-run", "--output", "json",
        ], timeoutSeconds: 60)
        XCTAssertEqual(out.exitCode, 0, "stderr: \(out.stderr)")
        // Dry-run prints the request that would be sent.
        XCTAssertTrue(out.stdout.contains("\"model\""), out.stdout)
        XCTAssertTrue(out.stdout.contains("unit test"), out.stdout)
    }

    func testAuthStatusParses() async throws {
        let client = try makeClient()
        // Decoding success is the assertion; either authenticated or a clean error envelope.
        let status = try await client.authStatus()
        if let authenticated = status.authenticated {
            print("bl auth status: authenticated=\(authenticated)")
        }
    }
}
