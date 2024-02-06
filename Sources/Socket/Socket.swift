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

public class Socket {
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
        
        connection = create()
    }
    
    func complete(result: Result<Data, Error>) {
        completionHandler?(result)
        completionHandler = nil
    }
    
    func create() -> NWConnection{
        return NWConnection(host: host, port: port, using: parameters)
    }
    
    public func send(message: String, completion: @escaping ((Result<Data, Error>) -> Void)) {
        self.completionHandler = completion
        if connection == nil {
            connection = create()
        }
        connection?.stateUpdateHandler = { [weak self] (newState) in
            switch (newState) {
            case .ready:
                self?.log("Connection ready", level: .debug)
                self?.sendMsg(message: message)
                self?.receive()
            case .waiting(let error):
                self?.complete(result: .failure(error))
                self?.log("Connection waiting with error: \(error.localizedDescription)", level: .error)
                self?.cancel()
            case .failed(let error):
                self?.complete(result: .failure(error))
                self?.log("Connection failed with error: \(error.localizedDescription)", level: .error)
                self?.cancel()
            case .cancelled:
                self?.log("Connection cancelled")
            default:
                break
            }
        }
        self.connection?.start(queue: self.myQueue)

        connection?.betterPathUpdateHandler = { [weak self] (betterPathAvailable) in
            if (betterPathAvailable) {
                self?.log("Connection: Better path available")
                self?.cancel()
                self?.connection = self?.create()
            }
        }
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
                self?.log("Connection sending error: \(sendError)", level: .error)
            }
        })
    }
    
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] (content, context, isComplete, error) in
            if let error = error {
                self?.complete(result: .failure(error))
                self?.cancel()
                return
            }
            
            if let content = content {
                self?.receivedData?.append(content)
            }
			if isComplete || content == nil {
				self?.complete(result: .success(self?.receivedData ?? Data()))
				self?.cancel()
			} else if let data = self?.receivedData,
					  let message = self?.message,
					  let string = String(data: data, encoding: .utf8),
					  (string.localizedCaseInsensitiveContains("end \(message)")
					   || string.localizedCaseInsensitiveContains("err")) {
				self?.complete(result: .success(self?.receivedData ?? Data()))
				self?.cancel()
			} else if self?.connection?.state == .ready && isComplete == false {
				self?.receive()
			}
			
        }
    }
    
    public func cancel() {
        connection?.cancel()
        connection = nil
    }
    
    private func log(_ message: String, level: OSLogType = .default) {
        if #available(OSX 11.0, iOS 14.0, *) {
            let logger = Logger(subsystem: "Socket", category: "Socket")
            logger.log(level: level, "\(message)")
        } else {
            switch level {
            case .debug:
                NSLog("[Debug] \(message)")
            case .default:
                NSLog("[Notice] \(message)")
            case .error:
                NSLog("[Error] \(message)")
            case .fault:
                NSLog("[Fault] \(message)")
            case .info:
                NSLog("[Info] \(message)")
            default:
                NSLog("[Notice] \(message)")
            }
            
        }
        
    }
}
