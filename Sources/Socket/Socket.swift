//
//  Socket.swift
//  NetworkSandbox
//
//  Created by Dariusz Niklewicz on 24/02/2020.
//  Copyright © 2020 Dariusz Niklewicz. All rights reserved.
//

import Foundation
import Network
import OSLog

public enum SocketError: Error {
    case timeout
    case cancelled
    case connectionFailed(Error)
    case invalidState
}

public struct SocketConfiguration: Sendable {
    public let connectionTimeout: Int
    public let receiveBufferSize: Int
    public let terminationPatterns: [String]
    
    public init(
        connectionTimeout: Int = 5,
        receiveBufferSize: Int = 8192,
        terminationPatterns: [String] = ["end", "err"]
    ) {
        self.connectionTimeout = connectionTimeout
        self.receiveBufferSize = receiveBufferSize
        self.terminationPatterns = terminationPatterns
    }
}

public actor Socket {
    nonisolated public let host: NWEndpoint.Host
    nonisolated public let port: NWEndpoint.Port
    nonisolated public let configuration: SocketConfiguration
    
    nonisolated public let parameters: NWParameters
    
    private var connection: NWConnection?
    private let myQueue = DispatchQueue(label: "Socket-\(UUID().uuidString)")
    
    private var continuation: CheckedContinuation<Data, Error>?
    private var isOperationInProgress = false
    
    private var receivedData: Data?
    private var currentMessage = ""
    
    public init(host: String, port: Int, configuration: SocketConfiguration = SocketConfiguration()) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))
        self.configuration = configuration
        
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = configuration.connectionTimeout
        self.parameters = NWParameters(tls: nil, tcp: options)
        
        if let ipOption = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOption.version = .v4
        }
        parameters.preferNoProxies = true
        parameters.expiredDNSBehavior = .allow
        
        // Initialize connection directly in init since we can't call actor methods
        self.connection = NWConnection(host: self.host, port: self.port, using: parameters)
    }
    
    private func complete(result: Result<Data, Error>) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        self.isOperationInProgress = false
        continuation.resume(with: result)
    }
    
    private func resetState() {
        receivedData = nil
        currentMessage = ""
        continuation = nil
        isOperationInProgress = false
    }
    
    private func performSendTask(message: String) async throws -> Data {
        guard !isOperationInProgress else {
            throw SocketError.invalidState
        }
        
        guard let connection = self.connection else {
            throw SocketError.invalidState
        }
        
        isOperationInProgress = true
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            
            connection.stateUpdateHandler = { [weak self] newState in
                Task {
                    await self?.handleStateUpdate(newState, message: message)
                }
            }
            
            connection.start(queue: self.myQueue)
        }
    }
    
    public func send(message: String, timeout: Duration = .seconds(5)) async throws -> Data {
        if connection?.state == .cancelled || connection == nil {
            resetConnection()
        }
        
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.performSendTask(message: message)
            }
            
            group.addTask {
                try await Task.sleep(for: timeout)
                await self.handleTimeout()
                throw SocketError.timeout
            }
            
            defer { group.cancelAll() }
            
            guard let result = try await group.next() else {
                throw SocketError.timeout
            }
            
            return result
        }
    }
    
    private func handleTimeout() {
        complete(result: .failure(SocketError.timeout))
        cancelConnectionOnly()
    }
    
    // Handle connection state updates
    private func handleStateUpdate(_ newState: NWConnection.State, message: String) {
        switch newState {
        case .ready:
            log("Connection ready", level: .debug)
            sendMsg(message: message)
            receive()
        case .waiting(let error):
//            complete(result: .failure(SocketError.connectionFailed(error)))
            log("Connection waiting with error: \(error.localizedDescription)", level: .error)
//            cancelConnectionOnly()
        case .failed(let error):
            complete(result: .failure(SocketError.connectionFailed(error)))
            log("Connection failed with error: \(error.localizedDescription)", level: .error)
            cancelConnectionOnly()
        case .cancelled:
            complete(result: .failure(SocketError.cancelled))
            log("Connection cancelled")
            cancelConnectionOnly()
        default:
            break
        }
    }
    
    private func resetConnection() {
        cancelConnectionOnly()
        resetState()
        connection = NWConnection(host: host, port: port, using: parameters)
    }
    
    private func sendMsg(message: String) {
        self.receivedData = Data()
        self.currentMessage = message
        let msg = message + "\r\n"
        
        guard let data = msg.data(using: .utf8) else {
            complete(result: .failure(SocketError.invalidState))
            return
        }
        
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                Task {
                    await self?.log("Connection sending error: \(error)", level: .error)
                    await self?.complete(result: .failure(SocketError.connectionFailed(error)))
                    await self?.cancelConnectionOnly()
                }
            }
        })
    }
    
    private func appendReceivedData(_ data: Data) {
        if receivedData == nil {
            receivedData = Data()
        }
        receivedData?.append(data)
    }
    
    private func receive() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: configuration.receiveBufferSize
        ) { [weak self] (content, context, isComplete, error) in
            Task {
                guard let self = self else { return }
                
                if let error = error {
                    await self.complete(result: .failure(SocketError.connectionFailed(error)))
                    await self.cancel()
                    return
                }
                
                if let content = content {
                    await self.appendReceivedData(content)
                }
                
                if isComplete || content == nil {
                    await self.complete(result: .success(self.receivedData ?? Data()))
                    await self.cancel()
                } else if await self.shouldTerminateReceive() {
                    await self.complete(result: .success(self.receivedData ?? Data()))
                    await self.cancel()
                } else if await self.connection?.state == .ready {
                    await self.receive()
                }
            }
        }
    }
    
    private func shouldTerminateReceive() -> Bool {
        guard let data = receivedData,
              let string = String(data: data, encoding: .utf8) else {
            return false
        }
        
        let lowercaseString = string.lowercased()
        let lowercaseMessage = currentMessage.lowercased()
        
        return configuration.terminationPatterns.contains { pattern in
            lowercaseString.contains("\(pattern) \(lowercaseMessage)") ||
            lowercaseString.contains(pattern.lowercased())
        }
    }
    
    // Only shuts down the NWConnection. Does NOT call `complete(...)`
    private func cancelConnectionOnly() {
        connection?.cancel()
        connection = nil
    }
    
    public func cancel() {
        // if a send is in flight, signal cancellation
        complete(result: .failure(SocketError.cancelled))
        cancelConnectionOnly()
        resetState()
    }
    
    private func log(_ message: String, level: OSLogType = .default) {
        let logger = Logger(subsystem: "Socket", category: "Socket")
        logger.log(level: level, "\(message)")
    }
}
