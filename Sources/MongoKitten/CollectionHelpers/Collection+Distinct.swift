import MongoCore
import NIO

extension MongoCollection {
    public func distinctValues(forKey key: String, where query: Document? = nil) -> EventLoopFuture<[Primitive]> {
        return pool.next(for: .basic).flatMap { connection in
            let command = DistinctCommand(onKey: key, where: query, inCollection: self.name)
            return connection.executeCodable(
                command,
                namespace: self.database.commandNamespace,
                in: self.transaction,
                sessionId: self.sessionId ?? connection.implicitSessionId
            )
        }.decodeReply(DistinctReply.self).map { $0.distinctValues }._mongoHop(to: hoppedEventLoop)
    }
}
