import Foundation
import KyroFoundation

public actor SQLiteCatalogStore {
    private let writer:SQLiteWriter; private let readers:SQLiteReaderPool
    public init(writer:SQLiteWriter,readers:SQLiteReaderPool){self.writer=writer;self.readers=readers}
    public func promote(_ titles:[CanonicalMedia], generation:UInt64) async throws {
        var commands:[(String,[SQLiteValue])]=[("INSERT INTO catalog_generations(generation,state,created_at) VALUES(?,'staging',?)",[.integer(Int64(generation)),.real(Date.now.timeIntervalSince1970)])]
        for title in titles {
            let payload=try JSONEncoder().encode(title)
            commands.append(("INSERT INTO canonical_titles(generation,canonical_key,kind,title,normalized_title,year,parent_key,edition,metadata) VALUES(?,?,?,?,?,?,?,?,?)",[.integer(Int64(generation)),.text(title.id),.text(title.kind.rawValue),.text(title.title),.text(CanonicalMedia.normalize(title.title)),title.year.map{.integer(Int64($0))} ?? .null,title.parentID.map(SQLiteValue.text) ?? .null,title.edition.map(SQLiteValue.text) ?? .null,.blob(payload)]))
            for (source,id) in title.externalIDs { commands.append(("INSERT INTO source_partitions(generation,account_id,source_item_id,canonical_key,payload) VALUES(?,?,?,?,?)",[.integer(Int64(generation)),.text(source),.text(id),.text(title.id),.blob(payload)])) }
        }
        commands.append(("UPDATE catalog_generations SET state='published' WHERE generation=?",[.integer(Int64(generation))]))
        commands.append(("UPDATE catalog_state SET active_generation=? WHERE singleton=1",[.integer(Int64(generation))]))
        try await writer.transaction(commands)
    }
    public func page(after key:String?=nil,limit:Int=50,reverse:Bool=false) async throws->[CanonicalMedia] {
        let gen=try await readers.scalarInt("SELECT active_generation FROM catalog_state WHERE singleton=1")
        let op=reverse ? "<":">";let order=reverse ? "DESC":"ASC"
        let sql=key == nil ? "SELECT metadata FROM canonical_titles WHERE generation=? ORDER BY canonical_key \(order) LIMIT ?":"SELECT metadata FROM canonical_titles WHERE generation=? AND canonical_key \(op) ? ORDER BY canonical_key \(order) LIMIT ?"
        let rows=try await readers.query(sql,bindings:key == nil ? [.integer(gen),.integer(Int64(limit))]:[.integer(gen),.text(key!),.integer(Int64(limit))])
        return rows.compactMap{row in guard case let .blob(data)?=row["metadata"] else{return nil};return try? JSONDecoder().decode(CanonicalMedia.self,from:data)}
    }
    public func search(_ query:String,limit:Int=50) async throws->[CanonicalMedia] {
        let gen=try await readers.scalarInt("SELECT active_generation FROM catalog_state WHERE singleton=1")
        let rows=try await readers.query("SELECT t.metadata FROM canonical_titles_fts f JOIN canonical_titles t ON t.canonical_key=f.canonical_key AND t.generation=CAST(f.generation AS INTEGER) WHERE canonical_titles_fts MATCH ? AND t.generation=? ORDER BY rank LIMIT ?",bindings:[.text(query),.integer(gen),.integer(Int64(limit))])
        return rows.compactMap{row in guard case let .blob(data)?=row["metadata"] else{return nil};return try? JSONDecoder().decode(CanonicalMedia.self,from:data)}
    }
}
