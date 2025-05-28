# Socket

A modern, async/await Swift package for TCP socket communication using Apple's Network framework.

## Features

- **Actor-based design** for thread safety
- **Async/await support** for modern Swift concurrency
- **Configurable timeouts** and connection parameters
- **Robust error handling** with detailed error types
- **Automatic connection management** with retry capabilities
- **Customizable termination patterns** for protocol-specific communication

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 6.0+

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/Socket.git", from: "1.0.0")
]
```

Or add it through Xcode:
1. File → Add Package Dependencies
2. Enter the repository URL
3. Select the version range

## Usage

### Basic Usage

```swift
import Socket

// Create a socket connection
let socket = Socket(host: "example.com", port: 80)

do {
    // Send a message and receive response
    let response = try await socket.send(message: "GET / HTTP/1.1\r\nHost: example.com\r\n")
    print("Received: \(String(data: response, encoding: .utf8) ?? "Invalid UTF-8")")
} catch {
    print("Error: \(error)")
}
```

### Custom Configuration

```swift
import Socket

// Create custom configuration
let config = SocketConfiguration(
    connectionTimeout: 10,           // 10 seconds connection timeout
    receiveBufferSize: 16384,        // 16KB receive buffer
    terminationPatterns: ["END", "ERROR", "DONE"]  // Custom termination patterns
)

let socket = Socket(host: "example.com", port: 1234, configuration: config)

do {
    let response = try await socket.send(
        message: "CUSTOM_COMMAND",
        timeout: .seconds(30)        // 30 seconds operation timeout
    )
    // Handle response
} catch {
    print("Error: \(error)")
}
```

### Error Handling

```swift
do {
    let response = try await socket.send(message: "test")
} catch SocketError.timeout {
    print("Operation timed out")
} catch SocketError.cancelled {
    print("Operation was cancelled")
} catch SocketError.connectionFailed(let underlyingError) {
    print("Connection failed: \(underlyingError)")
} catch SocketError.invalidState {
    print("Socket is in invalid state")
} catch {
    print("Unexpected error: \(error)")
}
```

### Cancellation

```swift
let socket = Socket(host: "example.com", port: 80)

let task = Task {
    do {
        let response = try await socket.send(message: "long_running_command")
        // Handle response
    } catch SocketError.cancelled {
        print("Operation was cancelled")
    }
}

// Cancel the operation after 5 seconds
try await Task.sleep(for: .seconds(5))
await socket.cancel()
```

## Configuration Options

### SocketConfiguration

- **connectionTimeout**: Maximum time to wait for connection establishment (default: 5 seconds)
- **receiveBufferSize**: Size of the receive buffer (default: 8192 bytes)
- **terminationPatterns**: Patterns that indicate end of response (default: ["end", "err"])

## Error Types

- **SocketError.timeout**: Operation exceeded the specified timeout
- **SocketError.cancelled**: Operation was cancelled
- **SocketError.connectionFailed(Error)**: Connection failed with underlying error
- **SocketError.invalidState**: Socket is in an invalid state for the operation

## Thread Safety

The `Socket` class is implemented as a Swift actor, ensuring thread safety for all operations. All public methods are async and properly isolated.

## Best Practices

1. **Always handle errors**: Network operations can fail for various reasons
2. **Use appropriate timeouts**: Set reasonable timeouts based on your use case
3. **Cancel long-running operations**: Use the cancel method to clean up resources
4. **Reuse socket instances**: The socket automatically manages connection state
5. **Configure termination patterns**: Set appropriate patterns for your protocol

## Example: HTTP Request

```swift
import Socket

func makeHTTPRequest() async {
    let socket = Socket(host: "httpbin.org", port: 80)
    
    let httpRequest = """
        GET /get HTTP/1.1\r
        Host: httpbin.org\r
        Connection: close\r
        \r
        """
    
    do {
        let response = try await socket.send(
            message: httpRequest,
            timeout: .seconds(10)
        )
        
        if let responseString = String(data: response, encoding: .utf8) {
            print("HTTP Response:")
            print(responseString)
        }
    } catch {
        print("Request failed: \(error)")
    }
}
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
