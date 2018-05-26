//
// This source file is part of the MongoKitten open source project
//
// Copyright (c) 2016 - 2017 OpenKitten and the MongoKitten project authors
// Licensed under MIT
//
// See https://github.com/OpenKitten/MongoKitten/blob/mongokitten31/LICENSE.md for license information
// See https://github.com/OpenKitten/MongoKitten/blob/mongokitten31/CONTRIBUTORS.md for the list of MongoKitten project authors
//

import BSON
import NIO

/// A connection to MongoDB
public final class DatabaseConnection {
    let scram = SCRAMContext()
    
    fileprivate var requestID: Int32 = 0
    
    var nextRequestId: Int32 {
        requestID = requestID &+ 1
        return requestID
    }
    
    /// The responses being waited for
    var waitingForResponses = [Int32: Promise<Message.Reply>]()
    
    var wireProtocol: Int = 0
    
    var error: Error?
    
    var serializing: Message.Buffer?
    let eventloop: EventLoop
    
    init(loop: EventLoop) {
        self.eventloop = loop
        
        let client = ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.add(handler: MessageWriter()).then {
                    return channel.pipeline.add(handler: MessageParser())
                }
            }
        
        self.socket = sink.socket
        self.parser = MessageParser().stream(on: eventloop)
        
        serializer.map(to: ByteBuffer.self) { buffer in
            self.serializing = buffer
            return buffer.buffer
        }.output(to: sink)
        
        source.stream(to: parser).map(to: Message.Reply.self) { buffer in
            return try Message.Reply(buffer)
        }.drain { reply in
            let responseId = reply.header.responseTo
            
            self.waitingForResponses[responseId]?.complete(reply)
            self.waitingForResponses[responseId] = nil
        }.catch { error in
            for waiter in self.waitingForResponses.values {
                waiter.fail(error)
            }
            
            self.error = error
            self.waitingForResponses = [:]
            
            self.socket.close()
        }.finally {
            self.socket.close()
        }
    }
    
    public subscript(database: String) -> Database {
        return Database(named: database, atServer: Server(connection: self))
    }
    
    public static func connect(host: MongoHost, credentials: MongoCredentials? = nil, ssl: SSLSettings = false, worker: Worker) throws -> Future<DatabaseConnection> {
        let socket = try TCPSocket()
        let client = try TCPClient(socket: socket)
        
        if ssl.enabled {
            let tls = try AppleTLSClient(tcp: client, using: TLSClientSettings(peerDomainName: host.hostname))
            try tls.connect(hostname: host.hostname, port: host.port)
            
            let sink = tls.socket.sink(on: worker)
            let source = tls.socket.source(on: worker)
            
            let connection = DatabaseConnection(eventloop: worker.eventLoop, source: source, sink: sink)
            
            if let credentials = credentials {
                return try connection.authenticate(with: credentials).transform(to: connection)
            } else {
                return Future(connection)
            }
        } else {
            try client.connect(hostname: host.hostname, port: host.port)
            
            let source = socket.source(on: worker)
            let sink = socket.sink(on: worker)
            
            let connection = DatabaseConnection(eventloop: worker.eventLoop, source: source, sink: sink)
            
            if let credentials = credentials {
                return try connection.authenticate(with: credentials).transform(to: connection)
            } else {
                return Future(connection)
            }
        }
    }
    
    /// Authenticates this connection to a database
    ///
    /// - parameter db: The database to authenticate to
    ///
    /// - throws: Authentication error
    func authenticate(with credentials: MongoCredentials) throws -> Future<Void> {
        switch credentials.authenticationMechanism {
        case .SCRAM_SHA_1:
            return try self.authenticateSASL(credentials)
        case .MONGODB_CR:
            return try self.authenticateCR(credentials)
        case .MONGODB_X509:
            return try self.authenticateX509(credentials: credentials)
        default:
            return Future(error: MongoError.unsupportedFeature("authentication Method \"\(credentials.authenticationMechanism.rawValue)\""))
        }
    }
    
    /// Closes this connection
    public func close() {
        self.socket.close()
        self.closeResponses()
    }
    
    func closeResponses() {
        for (_, callback) in self.waitingForResponses {
            callback.fail(MongoError.notConnected)
        }
        
        self.waitingForResponses = [:]
    }
    
    func send(message: MessageType) -> Future<Message.Reply> {
        if let error = self.error {
            return Future(error: error)
        }
        
        let promise = Promise<Message.Reply>()
        
        self.waitingForResponses[message.header.requestId] = promise
        self.serializer.push(message.storage)
        
        return promise.future
    }
}