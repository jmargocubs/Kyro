import XCTest
import KyroFoundation
import KyroIdentity
import KyroLedger
import KyroCatalog
import KyroMatching
import KyroSources
import KyroPlayback
import KyroCapabilities

final class CoreTests: XCTestCase {
    func testHLCOrderAndSkew() {
        let a=HybridLogicalClock(physicalMilliseconds:10_000_000,logical:0,node:"a").advanced(now:1)
        XCTAssertEqual(a.physicalMilliseconds,10_000_000); XCTAssertEqual(a.logical,1)
        XCTAssertLessThan(HybridLogicalClock(physicalMilliseconds:2,logical:1,node:"a"),HybridLogicalClock(physicalMilliseconds:2,logical:1,node:"b"))
    }
    func testIdentityPINGrantsAndTombstone() async throws {
        let pin=try PINVerifier(pin:"4829",rounds:100_000); XCTAssertTrue(pin.verifies("4829")); XCTAssertFalse(pin.verifies("1234"))
        let registry=IdentityRegistry(), household=HouseholdID()
        let p1=await registry.createProfile(householdID:household,name:"A"), p2=await registry.createProfile(householdID:household,name:"B",kind:.kids)
        let a1=ProviderAccount(provider:"jellyfin",subject:"sub",scope:"server1"),a2=ProviderAccount(provider:"jellyfin",subject:"sub",scope:"server1")
        await registry.addAccount(a1);await registry.addAccount(a2)
        try await registry.grant(SourceGrant(profileID:p1.id,accountID:a1.id,canWrite:true))
        do { try await registry.grant(SourceGrant(profileID:p2.id,accountID:a2.id,canWrite:true)); XCTFail("exclusive subject write must fail") } catch IdentityError.exclusiveWriteConflict {}
        await registry.deleteProfile(p1.id);let deleted=await registry.profile(p1.id), active=await registry.profile(p2.id);XCTAssertNotNil(deleted?.tombstonedAt);XCTAssertNil(active?.tombstonedAt)
    }
    func testLedgerMergeAndContinueWatching() {
        let profile=KyroProfileID(), clock=HybridLogicalClock(physicalMilliseconds:1,logical:0,node:"a")
        let ops=(0..<60).map{LedgerOperation(profileID:profile,itemKey:"item\($0)",value:.progress(Double($0)/100),clock:clock)}
        var baseline=Ledger();ops.forEach{baseline.append($0)}
        for seed in 0..<1000 { var shuffled=ops;var generator=SeededGenerator(seed:UInt64(seed));shuffled.shuffle(using: &generator);var merged=Ledger();for op in shuffled { var shard=Ledger();shard.append(op);merged=merged.merged(with:shard) };XCTAssertEqual(merged.operations,baseline.operations);XCTAssertEqual(merged.merged(with:merged).operations,merged.operations) }
        XCTAssertEqual(baseline.continueWatching(profileID:profile).count,59)
        XCTAssertFalse(baseline.continueWatching(profileID:KyroProfileID()).contains{$0.itemKey=="item1"})
    }
    func testCanonicalAndMatchingCorpusNoFalseMerges() {
        XCTAssertEqual(CanonicalMedia(kind:.movie,title:" Amélie ",year:2001).id,CanonicalMedia(kind:.movie,title:"amelie",year:2001).id)
        let matcher=MediaMatcher();var errors=0
        for n in 0..<300 {let original=MatchCandidate(id:"m\(n)",kind:.movie,title:"Film \(n)",year:1980+n,edition:"theatrical");let other=MatchCandidate(id:"other\(n)",kind:.movie,title:"Film \(n)",year:1980+n,edition:"extended");if case .matched=matcher.match(other,against:[original]){errors += 1}}
        XCTAssertEqual(errors,0)
        let remake=MatchCandidate(id:"r",kind:.movie,title:"Dune",year:2021);let old=MatchCandidate(id:"d",kind:.movie,title:"Dune",year:1984);XCTAssertEqual(matcher.match(remake,against:[old]),.unmatched)
    }
    func testPaginationAndGenerationAtomicPromotion() {
        var catalog=CatalogIndex();let first=(0..<50_000).map{CanonicalMedia(kind:.movie,title:"Title \($0)",year:2000)}
        let start=ContinuousClock.now;catalog.promote(first);let page=catalog.page(limit:100);let elapsed=start.duration(to:.now)
        XCTAssertEqual(catalog.count(),50_000);XCTAssertEqual(page.count,100);XCTAssertEqual(Set(page.map{$0.id}).count,100);XCTAssertLessThan(elapsed,.seconds(20))
        let generation=catalog.generation;catalog.promote([CanonicalMedia(kind:.movie,title:"Replacement")]);XCTAssertEqual(catalog.generation,generation+1);XCTAssertEqual(catalog.count(),1)
    }
    func testProviderParsersAndPlaybackQualityProvenance() throws {
        let jelly=try JellyfinCatalogParser().parse(Data(#"{"Items":[{"Name":"Arrival","Type":"Movie","ProductionYear":2016,"Id":"j1"}]}"#.utf8));XCTAssertEqual(jelly.first?.title,"Arrival")
        let xtream=try XtreamVODParser().parse(Data(#"[{"name":"Dune","stream_id":42,"year":2021}]"#.utf8));XCTAssertEqual(xtream.first?.externalIDs["xtream"],"42")
        let quality=MediaQuality(resolution:"1080p",provenance:"provider metadata");XCTAssertEqual(quality.provenance,"provider metadata")
    }
    func testRedaction() { XCTAssertFalse(Redactor.redact("token=abc123").contains("abc123")) }
    func testCircuitBreakerAndRateLimitPolicy() async {
        let breaker=CircuitBreaker(threshold:2,cooldown:.seconds(10)), now=ContinuousClock.now
        let startsClosed=await breaker.allow(now:now);XCTAssertTrue(startsClosed);await breaker.recordFailure(now:now);let remainsOpenAfterOne=await breaker.allow(now:now);XCTAssertTrue(remainsOpenAfterOne);await breaker.recordFailure(now:now);let blocked=await breaker.allow(now:now);XCTAssertFalse(blocked)
        let limiter=HTTPRateLimiter(requestsPerSecond:4);XCTAssertEqual(limiter.minimumInterval,.milliseconds(250))
    }
    func testSQLitePersistenceTransactionsFTSAndMigration() async throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("kyro-core-\(UUID().uuidString).sqlite")
        let location=StorageLocation(url:url);let writer=try SQLiteWriter(location:location);try await writer.migrate(to:KyroSchema.latestVersion,statements:KyroSchema.migrations)
        let initialVersion=try await writer.schemaVersion();XCTAssertEqual(initialVersion,KyroSchema.latestVersion)
        let household=HouseholdID(),profile=KyroProfile(householdID:household,name:"Persisted",kind:.kids)
        let identity=SQLiteIdentityStore(writer:writer);try await identity.save(profile);let account=ProviderAccount(provider:"jellyfin",subject:"subject",scope:"library");try await identity.addAccount(account);try await identity.grant(SourceGrant(profileID:profile.id,accountID:account.id,canWrite:true))
        let persistedProfile=try await identity.profile(profile.id);XCTAssertEqual(persistedProfile?.name,"Persisted")
        let ledgerStore=SQLiteLedgerStore(writer:writer);let operation=LedgerOperation(profileID:profile.id,itemKey:"movie-key",value:.favorite(true),clock:HybridLogicalClock(physicalMilliseconds:1,logical:0,node:"device"));try await ledgerStore.append(operation,deviceID:DeviceID());let persistedOperations=try await ledgerStore.operations(profileID:profile.id);XCTAssertEqual(persistedOperations.count,1)
        let readers=try SQLiteReaderPool(location:location,capacity:3);let catalog=SQLiteCatalogStore(writer:writer,readers:readers);let film=CanonicalMedia(kind:.movie,title:"Persistent Arrival",year:2016,externalIDs:[account.id.description:"jelly-item"]);try await catalog.promote([film],generation:1)
        print("FTS rows", try await writer.query("SELECT rowid,generation,canonical_key,title FROM canonical_titles_fts"));print("FTS hits",try await readers.query("SELECT rowid,canonical_key,title FROM canonical_titles_fts WHERE canonical_titles_fts MATCH 'Persistent'"));let searchResults=try await catalog.search("Persistent");XCTAssertEqual(searchResults.first?.id,film.id)
        do { try await writer.transaction([("INSERT INTO profiles(id,household_id,name,kind) VALUES('rolled','h','Rollback','standard')",[]),("INSERT INTO missing_table VALUES(1)",[])]);XCTFail("transaction should fail") } catch {}
        let rollbackRows=try await writer.query("SELECT id FROM profiles WHERE id='rolled'");XCTAssertTrue(rollbackRows.isEmpty)
        let counts=try await withThrowingTaskGroup(of:Int64.self,returning:[Int64].self) { group in for _ in 0..<12 { group.addTask { try await readers.scalarInt("SELECT COUNT(*) FROM canonical_titles") } };var values=[Int64]();for try await value in group { values.append(value) };return values }
        XCTAssertEqual(counts,Array(repeating:1,count:12));let poolCount=await readers.readerCount;XCTAssertEqual(poolCount,3)
        try await readers.close();await writer.close()
        let reopened=try SQLiteWriter(location:location);try await reopened.migrate(to:KyroSchema.latestVersion,statements:KyroSchema.migrations);let restored=try await SQLiteIdentityStore(writer:reopened).profile(profile.id);XCTAssertEqual(restored?.name,"Persisted");let finalVersion=try await reopened.schemaVersion();XCTAssertEqual(finalVersion,KyroSchema.latestVersion);await reopened.close()
        for suffix in ["","-wal","-shm"] {try? FileManager.default.removeItem(atPath:url.path+suffix)}
    }
}

private struct SeededGenerator: RandomNumberGenerator { var state:UInt64;init(seed:UInt64){state=seed};mutating func next()->UInt64 {state = state &* 6364136223846793005 &+ 1442695040888963407;return state} }
