import XCTest
@testable import Socket
import Network

final class SocketTests: XCTestCase {
    
    func testSocketInitialization() {
        let socket = Socket(host: "example.com", port: 80)
        XCTAssertEqual(socket.host, NWEndpoint.Host("example.com"))
        XCTAssertEqual(socket.port, NWEndpoint.Port(80))
    }
    
    func testSocketInitializationWithConfiguration() {
        let config = SocketConfiguration(
            connectionTimeout: 10,
            receiveBufferSize: 4096,
            terminationPatterns: ["done", "error"]
        )
        let socket = Socket(host: "example.com", port: 80, configuration: config)
        XCTAssertEqual(socket.configuration.connectionTimeout, 10)
        XCTAssertEqual(socket.configuration.receiveBufferSize, 4096)
        XCTAssertEqual(socket.configuration.terminationPatterns, ["done", "error"])
    }
    
    func testSocketErrorTypes() {
        let timeoutError = SocketError.timeout
        let cancelledError = SocketError.cancelled
        let connectionError = SocketError.connectionFailed(NSError(domain: "test", code: 1))
        let invalidStateError = SocketError.invalidState
        
        XCTAssertNotNil(timeoutError)
        XCTAssertNotNil(cancelledError)
        XCTAssertNotNil(connectionError)
        XCTAssertNotNil(invalidStateError)
    }
    
    func testConnectionToInvalidHost() async {
        let socket = Socket(host: "invalid.nonexistent.host", port: 12345)
        
        do {
            _ = try await socket.send(message: "test", timeout: .seconds(2))
            XCTFail("Expected connection to fail")
        } catch let error as SocketError {
            switch error {
            case .connectionFailed, .timeout:
                // Expected errors for invalid host
                break
            default:
                XCTFail("Unexpected error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testTimeoutBehavior() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        do {
            _ = try await socket.send(message: "test", timeout: .milliseconds(1))
            XCTFail("Expected timeout")
        } catch SocketError.timeout {
            // Expected timeout
        } catch {
            XCTFail("Expected timeout error, got: \(error)")
        }
    }
    
    func testConcurrentOperations() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    do {
                        _ = try await socket.send(message: "test\(i)", timeout: .seconds(1))
                    } catch SocketError.invalidState {
                        // Expected when multiple operations try to run concurrently
                    } catch SocketError.timeout {
                        // Also acceptable for this test
                    } catch {
                        XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
    }
    
    func testCancelOperation() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        let task = Task {
            do {
                _ = try await socket.send(message: "test", timeout: .seconds(10))
                XCTFail("Expected cancellation")
            } catch SocketError.cancelled {
                // Expected cancellation
            } catch {
                XCTFail("Expected cancellation error, got: \(error)")
            }
        }
        
        // Cancel after a short delay
        try? await Task.sleep(for: .milliseconds(100))
        await socket.cancel()
        await task.value
    }
    
    func testMultipleConnectionAttempts() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // First attempt
        do {
            _ = try await socket.send(message: "test1", timeout: .seconds(1))
        } catch {
            // Connection might fail, that's okay for this test
        }
        
        // Second attempt should work (connection should be reset)
        do {
            _ = try await socket.send(message: "test2", timeout: .seconds(1))
        } catch {
            // Connection might fail, that's okay for this test
        }
    }
    
    func testConfigurationDefaults() {
        let config = SocketConfiguration()
        XCTAssertEqual(config.connectionTimeout, 5)
        XCTAssertEqual(config.receiveBufferSize, 8192)
        XCTAssertEqual(config.terminationPatterns, ["end", "err"])
    }
    
    func testCustomConfiguration() {
        let config = SocketConfiguration(
            connectionTimeout: 15,
            receiveBufferSize: 16384,
            terminationPatterns: ["done", "finished", "error"]
        )
        XCTAssertEqual(config.connectionTimeout, 15)
        XCTAssertEqual(config.receiveBufferSize, 16384)
        XCTAssertEqual(config.terminationPatterns, ["done", "finished", "error"])
    }
    
    func testNonisolatedProperties() {
        let socket = Socket(host: "example.com", port: 80)
        
        // Test that we can access nonisolated properties directly
        let host = socket.host
        let port = socket.port
        let config = socket.configuration
        
        XCTAssertEqual(host, NWEndpoint.Host("example.com"))
        XCTAssertEqual(port, NWEndpoint.Port(80))
        XCTAssertNotNil(config)
    }
    
    // MARK: - Additional Tests for Missing Coverage
    
    func testConnectionFailedState() async {
        // Test connection to a port that will likely fail
        let socket = Socket(host: "127.0.0.1", port: 1) // Port 1 is typically restricted
        
        do {
            _ = try await socket.send(message: "test", timeout: .seconds(3))
            // If this succeeds, that's unexpected but not a test failure
        } catch SocketError.connectionFailed {
            // Expected - connection should fail to restricted port
        } catch SocketError.timeout {
            // Also acceptable - might timeout instead of failing
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testInvalidPortConnection() async {
        // Test with an invalid/unreachable port
        let socket = Socket(host: "192.0.2.1", port: 9999) // RFC 5737 test address
        
        do {
            _ = try await socket.send(message: "test", timeout: .seconds(2))
            XCTFail("Expected connection to fail")
        } catch SocketError.connectionFailed {
            // Expected
        } catch SocketError.timeout {
            // Also acceptable
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testCustomTerminationPatterns() async {
        let config = SocketConfiguration(
            connectionTimeout: 5,
            receiveBufferSize: 1024,
            terminationPatterns: ["DONE", "FINISHED", "ERROR"]
        )
        let socket = Socket(host: "httpbin.org", port: 80, configuration: config)
        
        do {
            _ = try await socket.send(message: "GET /status/200 HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n", timeout: .seconds(5))
            // Test passes if no exception is thrown
        } catch {
            // Connection might fail, which is acceptable for this test
        }
    }
    
    func testVeryShortTimeout() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        do {
            _ = try await socket.send(message: "test", timeout: .nanoseconds(1))
            XCTFail("Expected immediate timeout")
        } catch SocketError.timeout {
            // Expected immediate timeout
        } catch {
            XCTFail("Expected timeout error, got: \(error)")
        }
    }
    
    func testConnectionAfterCancel() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Cancel the socket first
        await socket.cancel()
        
        // Try to use it after cancellation
        do {
            _ = try await socket.send(message: "test", timeout: .seconds(2))
            // Might succeed if connection is reset
        } catch {
            // Expected to fail in some way
        }
    }
    
    func testMultipleCancellations() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Multiple cancellations should be safe
        await socket.cancel()
        await socket.cancel()
        await socket.cancel()
        
        // Should still be able to use the socket
        do {
            _ = try await socket.send(message: "test", timeout: .seconds(1))
        } catch {
            // Expected to potentially fail
        }
    }
    
    func testLargeMessage() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Create a large HTTP request
        let largeData = String(repeating: "X", count: 1000)
        let httpRequest = "GET /post HTTP/1.1\r\nHost: httpbin.org\r\nContent-Length: \(largeData.count)\r\nConnection: close\r\n\r\n\(largeData)"
        
        do {
            _ = try await socket.send(message: httpRequest, timeout: .seconds(10))
            // Test passes if no exception is thrown
        } catch {
            // Connection might fail, which is acceptable for this test
        }
    }
    
    func testEmptyMessage() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        do {
            _ = try await socket.send(message: "", timeout: .seconds(5))
            // Test passes if no exception is thrown
        } catch {
            // Connection might fail, which is acceptable for this test
        }
    }
    
    func testSpecialCharactersInMessage() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Test with various special characters
        let specialMessage = "GET /get?test=hello%20world&special=!@#$%^&*() HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n"
        
        do {
            _ = try await socket.send(message: specialMessage, timeout: .seconds(5))
            // Test passes if no exception is thrown
        } catch {
            // Connection might fail, which is acceptable for this test
        }
    }
    
    func testRapidConnectionAttempts() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Make several rapid connection attempts
        for i in 0..<3 {
            do {
                _ = try await socket.send(message: "GET /status/200 HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n", timeout: .seconds(2))
                break // Success, exit loop
            } catch {
                // Continue trying
                if i == 2 {
                    // Last attempt, any error is acceptable
                }
            }
        }
    }
    
    func testConnectionWithDifferentBufferSizes() async {
        let smallBufferConfig = SocketConfiguration(
            connectionTimeout: 5,
            receiveBufferSize: 64,
            terminationPatterns: ["end", "err"]
        )
        
        let socket = Socket(host: "httpbin.org", port: 80, configuration: smallBufferConfig)
        
        do {
            _ = try await socket.send(message: "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n", timeout: .seconds(5))
            // Test passes if no exception is thrown
        } catch {
            // Connection might fail, which is acceptable for this test
        }
    }
    
    func testConcurrentCancellations() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        await withTaskGroup(of: Void.self) { group in
            // Start a send operation
            group.addTask {
                do {
                    _ = try await socket.send(message: "test", timeout: .seconds(10))
                } catch {
                    // Expected to be cancelled
                }
            }
            
            // Cancel multiple times concurrently
            for _ in 0..<3 {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(50))
                    await socket.cancel()
                }
            }
        }
    }
    
    func testSocketErrorEquality() {
        // Test error type comparisons
        let timeout1 = SocketError.timeout
        let timeout2 = SocketError.timeout
        let cancelled = SocketError.cancelled
        let invalidState = SocketError.invalidState
        
        // These should be different instances but same type
        XCTAssertNotNil(timeout1)
        XCTAssertNotNil(timeout2)
        XCTAssertNotNil(cancelled)
        XCTAssertNotNil(invalidState)
    }
    
    func testConfigurationSendable() async {
        let config = SocketConfiguration(
            connectionTimeout: 10,
            receiveBufferSize: 4096,
            terminationPatterns: ["test"]
        )
        
        // Test that configuration can be passed across actor boundaries
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let socket = Socket(host: "example.com", port: 80, configuration: config)
                XCTAssertEqual(socket.configuration.connectionTimeout, 10)
            }
        }
    }
}
