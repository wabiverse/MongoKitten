import NIO
import MongoKittenCore
import MongoClient

public struct AggregateBuilderPipeline: QueryCursor {
    public typealias Element = Document
    internal var collection: MongoCollection!
    internal var writing = false
    internal var _comment: String?
    internal var _allowDiskUse: Bool?
    internal var _collation: Collation?
    internal var _readConcern: ReadConcern?
    
    public func allowDiskUse(_ allowDiskUse: Bool? = true) -> AggregateBuilderPipeline {
        var pipeline = self
        pipeline._allowDiskUse = allowDiskUse
        return pipeline
    }
    
    public func comment(_ comment: String?) -> AggregateBuilderPipeline {
        var pipeline = self
        pipeline._comment = comment
        return pipeline
    }
    
    public func collation(_ collation: Collation?) -> AggregateBuilderPipeline {
        var pipeline = self
        pipeline._collation = collation
        return pipeline
    }
    
    public func readConcern(_ readConcern: ReadConcern?) -> AggregateBuilderPipeline {
        var pipeline = self
        pipeline._readConcern = readConcern
        return pipeline
    }
    
    private func makeCommand() -> AggregateCommand {
        var documents = [Document]()
        documents.reserveCapacity(stages.count * 2)
        
        for stage in stages {
            documents.append(contentsOf: stage.stages)
        }
        
        var command = AggregateCommand(
            inCollection: collection.name,
            pipeline: documents
        )
        
        command.comment = _comment
        command.allowDiskUse = _allowDiskUse
        command.collation = _collation
        command.readConcern = _readConcern
        
        return command
    }
    
    public func getConnection() async throws -> MongoConnection {
        return try await collection.pool.next(for: .writable)
    }
    
    public func execute() async throws -> FinalizedCursor<AggregateBuilderPipeline> {
        let command = makeCommand()
        let connection = try await getConnection()
        
        let cursorReply = try await connection.executeCodable(
            command,
            decodeAs: CursorReply.self,
            namespace: self.collection.database.commandNamespace,
            in: self.collection.transaction,
            sessionId: self.collection.sessionId ?? connection.implicitSessionId
        )
        
        let cursor = MongoCursor(
            reply: cursorReply.cursor,
            in: self.collection.namespace,
            connection: connection,
            session: self.collection.session ?? connection.implicitSession,
            transaction: self.collection.transaction
        )
        
        return FinalizedCursor(basedOn: self, cursor: cursor)
    }
    
    public func transformElement(_ element: Document) throws -> Document {
        return element
    }
    
    var stages: [AggregateBuilderStage]
    
    internal init(stages: [AggregateBuilderStage]) {
        self.stages = stages
    }
    
    public func count() async throws -> Int {
        struct Count: Decodable {
            let count: Int
        }
        
        var pipeline = self
        pipeline.stages.append(.count(to: "count"))
        pipeline.stages.append(.project("count"))
        return try await pipeline.decode(Count.self).firstResult()?.count ?? 0
    }
    
    public func out(toCollection collectionName: String) async throws {
        var pipeline = self
        pipeline.stages.append(
            AggregateBuilderStage(document: [
                "$out": collectionName
            ])
        )
        pipeline.writing = true
        
        _ = try await pipeline.execute()
    }
}
