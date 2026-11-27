import Foundation
import KyroFoundation

public actor SQLiteLedgerStore {
    private let writer: SQLiteWriter
    public init(writer: SQLiteWriter) { self.writer=writer }
    public func append(_ operation: LedgerOperation, deviceID: DeviceID) async throws {
        let payload=try JSONEncoder().encode(operation.value)
        let field=Self.field(operation.value)
        _ = try await writer.execute("INSERT OR IGNORE INTO ledger_operations(op_id,profile_id,item_key,field_key,payload,wall_ms,logical,node,device_id) VALUES(?,?,?,?,?,?,?,?,?)",bindings:[.text(operation.id.uuidString),.text(operation.profileID.description),.text(operation.itemKey),.text(field),.blob(payload),.integer(operation.clock.physicalMilliseconds),.integer(Int64(operation.clock.logical)),.text(operation.clock.node),.text(deviceID.description)])
    }
    public func operations(profileID:KyroProfileID) async throws -> [LedgerOperation] {
        try await writer.query("SELECT op_id,item_key,payload,wall_ms,logical,node FROM ledger_operations WHERE profile_id=? ORDER BY wall_ms,logical,node,op_id",bindings:[.text(profileID.description)]).compactMap { row in
            guard case let .text(opID)?=row["op_id"],let uuid=UUID(uuidString:opID),case let .text(item)?=row["item_key"],case let .blob(data)?=row["payload"],case let .integer(wall)?=row["wall_ms"],case let .integer(logical)?=row["logical"],case let .text(node)?=row["node"],let value=try? JSONDecoder().decode(LedgerValue.self,from:data) else{return nil}
            return LedgerOperation(id:uuid,profileID:profileID,itemKey:item,value:value,clock:HybridLogicalClock(physicalMilliseconds:wall,logical:UInt32(logical),node:node))
        }
    }
    private static func field(_ value:LedgerValue)->String {switch value {case .favorite:return "favorite";case .watchlist:return "watchlist";case .watched:return "watched";case .progress:return "progress";case .collection(let id,_):return "collection:"+id;case .preference(let key,_):return "preference:"+key}}
}
