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
}

public actor Socket {
    public let host: NWEndpoint.Host
    public let port: NWEndpoint.Port
	public let parameters: NWParameters = {
		let options = NWProtocolTCP.Options()
		options.connectionTimeout = 5
		let parameters = NWParameters(tls: nil, tcp: options)
		if let isOption = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
			isOption.version = .v4
		}
		parameters.preferNoProxies = true
		return parameters
	}()
    
    public var connection: NWConnection?
    let myQueue = DispatchQueue(label: NSUUID().uuidString)
    
    public init(host: String, port: Int) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))
        parameters.expiredDNSBehavior = .allow
        
		connection = NWConnection(host: self.host, port: self.port, using: parameters)
    }
    
    func complete(result: Result<Data, Error>) {
        completionHandler?(result)
        completionHandler = nil
    }
    
    public func send(message: String, completion: @escaping ((Result<Data, Error>) -> Void)) {
        self.completionHandler = completion
        if connection == nil {
			resetConnection()
        }
        connection?.stateUpdateHandler = { [weak self] (newState) in
			Task {
				await self?.handleStateUpdate(newState, message: message)
			}
        }
        self.connection?.start(queue: self.myQueue)

//        connection?.betterPathUpdateHandler = { [weak self] (betterPathAvailable) in
//			Task {
//				if (betterPathAvailable) {
//					await self?.log("Connection: Better path available")
//					await self?.cancel()
//					await self?.resetConnection()
//				}
//			}
//        }
    }
	
	// Handle connection state updates
	private func handleStateUpdate(_ newState: NWConnection.State, message: String) async {
		switch (newState) {
		case .ready:
			log("Connection ready", level: .debug)
			sendMsg(message: message)
			receive()
		case .waiting(let error):
			log("Connection waiting with error: \(error.localizedDescription)", level: .error)
		case .failed(let error):
			complete(result: .failure(error))
			log("Connection failed with error: \(error.localizedDescription)", level: .error)
			cancel()
		case .cancelled:
			log("Connection cancelled")
		default:
			break
		}
	}
	
	func resetConnection() {
		self.connection = NWConnection(host: host, port: port, using: parameters)
	}
    
    private var completionHandler: ((Result<Data, Error>) -> Void)?
    private var receivedData: Data?
    private var message = ""
    
    private func sendMsg(message: String) {
        self.receivedData = Data()
        self.message = message
        let msg = message + "\r\n"
        let data: Data? = msg.data(using: .utf8)
        connection?.send(content: data, completion: .contentProcessed { [weak self] (sendError) in
            if let sendError = sendError {
				Task {
					await self?.log("Connection sending error: \(sendError)", level: .error)
				}
            }
        })
    }
	
	private func appendReceivedData(_ data: Data) {
		receivedData?.append(data)
	}
    
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] (content, context, isComplete, error) in
			Task {
				if let error {
					await self?.complete(result: .failure(error))
					await self?.cancel()
					return
				}
				
				if let content {
					await self?.appendReceivedData(content)
				}
				if isComplete || content == nil {
					await self?.complete(result: .success(self?.receivedData ?? Data()))
					await self?.cancel()
				} else if let data = await self?.receivedData,
						  let message = await self?.message,
						  let string = String(data: data, encoding: .utf8),
						  (string.localizedCaseInsensitiveContains("end \(message)")
						   || string.localizedCaseInsensitiveContains("err")) {
					await self?.complete(result: .success(self?.receivedData ?? Data()))
					await self?.cancel()
				} else if await self?.connection?.state == .ready && isComplete == false {
					await self?.receive()
				}
			}
        }
    }
    
    public func cancel() {
        connection?.cancel()
        connection = nil
    }
    
    private func log(_ message: String, level: OSLogType = .default) {
		let logger = Logger(subsystem: "Socket", category: "Socket")
		logger.log(level: level, "\(message)")
    }
}
