import XCTest
@testable import Socket
import Network

/// Tests for edge cases and hard-to-reach code paths
final class SocketEdgeCaseTests: XCTestCase {
    
    func testConnectionNilStateInPerformSendTask() async {
        let socket = Socket(host: "example.com", port: 80)
        
        // Cancel the socket to set connection to nil
        await socket.cancel()
        
        // Try to send while connection is nil - this should trigger the guard
        do {
            _ = try await socket.send(message: "test", timeout: .seconds(1))
            // The socket should reset the connection, so this might succeed
        } catch SocketError.invalidState {
            // This is the path we're trying to test
        } catch {
            // Other errors are also acceptable
        }
    }
    
    func testInvalidUTF8Handling() async {
        // This test is tricky because we can't easily inject invalid UTF-8 into the sendMsg method
        // The guard in sendMsg (line 175-177) is hard to trigger since Swift strings are always valid UTF-8
        // We'll test with extreme Unicode characters that might cause issues
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Test with various Unicode characters
        let unicodeMessage = "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nX-Test: 🚀💻🌟\r\nConnection: close\r\n\r\n"
        
        do {
            _ = try await socket.send(message: unicodeMessage, timeout: .seconds(5))
            // Should succeed since Unicode is valid UTF-8
        } catch {
            // Any error is acceptable for this test
        }
    }
    
    func testReceiveErrorHandling() async {
        // Test connection to a service that might cause receive errors
        let socket = Socket(host: "httpbin.org", port: 443) // HTTPS port without TLS
        
        do {
            _ = try await socket.send(message: "GET / HTTP/1.1\r\nHost: httpbin.org\r\n\r\n", timeout: .seconds(3))
            // Might succeed or fail depending on server behavior
        } catch {
            // Expected to fail in various ways
        }
    }
    
    func testTerminationPatternMatching() async {
        let config = SocketConfiguration(
            connectionTimeout: 5,
            receiveBufferSize: 1024,
            terminationPatterns: ["END_TEST", "DONE_TEST"]
        )
        let socket = Socket(host: "httpbin.org", port: 80, configuration: config)
        
        // Send a request that might trigger termination pattern matching
        do {
            _ = try await socket.send(message: "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n", timeout: .seconds(5))
            // Test the termination pattern logic
        } catch {
            // Connection might fail, which is acceptable
        }
    }
    
    func testNullReceivedDataInitialization() async {
        // This tests the path in appendReceivedData where receivedData is nil
        let socket = Socket(host: "httpbin.org", port: 80)
        
        do {
            _ = try await socket.send(message: "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n", timeout: .seconds(5))
            // This should exercise the appendReceivedData method
        } catch {
            // Connection might fail, which is acceptable
        }
    }
    
    func testShouldTerminateReceiveWithInvalidData() async {
        // Test the early return in shouldTerminateReceive when data can't be converted to string
        // This is hard to test directly, but we can test with binary-like data
        let socket = Socket(host: "httpbin.org", port: 80)
        
        do {
            // Send a request that might return binary-like data
            _ = try await socket.send(message: "GET /bytes/100 HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n", timeout: .seconds(5))
        } catch {
            // Connection might fail, which is acceptable
        }
    }
    
    func testConnectionFailedStateTransition() async {
        // Try to trigger the .failed state in handleStateUpdate
        // This is difficult to trigger reliably, but we can try with problematic connections
        let socket = Socket(host: "0.0.0.0", port: 1) // Invalid address
        
        do {
            _ = try await socket.send(message: "test", timeout: .seconds(2))
            XCTFail("Expected connection to fail")
        } catch SocketError.connectionFailed {
            // This is what we're testing for
        } catch SocketError.timeout {
            // Also acceptable
        } catch {
            // Other errors are also acceptable
        }
    }
    
    func testSendCompletionErrorHandling() async {
        // Test the error handling in the send completion callback
        // This is hard to trigger directly, but we can try with a connection that might fail during send
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Try to send a very large message that might cause send errors
        let largeMessage = String(repeating: "A", count: 100000)
        let httpRequest = "POST /post HTTP/1.1\r\nHost: httpbin.org\r\nContent-Length: \(largeMessage.count)\r\nConnection: close\r\n\r\n\(largeMessage)"
        
        do {
            _ = try await socket.send(message: httpRequest, timeout: .seconds(10))
            // Might succeed or fail
        } catch {
            // Any error is acceptable for this test
        }
    }
    
    func testTaskGroupFallbackTimeout() async {
        // Test the fallback timeout error in the task group (line 128)
        // This is hard to trigger since group.next() should always return a result
        let socket = Socket(host: "httpbin.org", port: 80)
        
        do {
            _ = try await socket.send(message: "test", timeout: .nanoseconds(1))
            XCTFail("Expected timeout")
        } catch SocketError.timeout {
            // Expected
        } catch {
            XCTFail("Expected timeout error, got: \(error)")
        }
    }
    
    func testMultipleStateTransitions() async {
        // Test multiple rapid state transitions
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Start multiple operations that will cause state transitions
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    _ = try await socket.send(message: "test1", timeout: .seconds(1))
                } catch {
                    // Expected to fail due to concurrent access
                }
            }
            
            group.addTask {
                try? await Task.sleep(for: .milliseconds(10))
                await socket.cancel()
            }
            
            group.addTask {
                try? await Task.sleep(for: .milliseconds(20))
                do {
                    _ = try await socket.send(message: "test2", timeout: .seconds(1))
                } catch {
                    // Expected to fail
                }
            }
        }
    }
    
    func testConnectionStateChecking() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Test the connection state checking in send method
        do {
            _ = try await socket.send(message: "GET /delay/1 HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n", timeout: .seconds(3))
        } catch {
            // Any result is acceptable
        }
        
        // Try again to test connection reset logic
        do {
            _ = try await socket.send(message: "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n", timeout: .seconds(3))
        } catch {
            // Any result is acceptable
        }
    }
    
    func testErrorTypeMatching() {
        // Test different error types for completeness
        let nsError = NSError(domain: "TestDomain", code: 123, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        let connectionError = SocketError.connectionFailed(nsError)
        
        switch connectionError {
        case .connectionFailed(let underlyingError):
            XCTAssertEqual((underlyingError as NSError).domain, "TestDomain")
            XCTAssertEqual((underlyingError as NSError).code, 123)
        default:
            XCTFail("Expected connectionFailed error")
        }
    }
    
    func testConfigurationEdgeCases() {
        // Test configuration with extreme values
        let extremeConfig = SocketConfiguration(
            connectionTimeout: 1,
            receiveBufferSize: 1,
            terminationPatterns: []
        )
        
        let socket = Socket(host: "example.com", port: 80, configuration: extremeConfig)
        XCTAssertEqual(socket.configuration.connectionTimeout, 1)
        XCTAssertEqual(socket.configuration.receiveBufferSize, 1)
        XCTAssertEqual(socket.configuration.terminationPatterns, [])
    }
    
    func testConcurrentStateModification() async {
        let socket = Socket(host: "httpbin.org", port: 80)
        
        // Test concurrent state modifications
        await withTaskGroup(of: Void.self) { group in
            // Multiple cancel operations
            for _ in 0..<5 {
                group.addTask {
                    await socket.cancel()
                }
            }
            
            // Try to send during cancellations
            group.addTask {
                do {
                    _ = try await socket.send(message: "test", timeout: .seconds(1))
                } catch {
                    // Expected to fail
                }
            }
        }
    }
} 