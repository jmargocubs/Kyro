import Foundation

public enum KyroSchema {
    public static let latestVersion = 3
    public static let migrations: [String] = [
        """
        CREATE TABLE profiles(id TEXT PRIMARY KEY, household_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, pin_salt BLOB, pin_hash BLOB, tombstoned_at REAL);
        CREATE INDEX profiles_household ON profiles(household_id, tombstoned_at);
        CREATE TABLE provider_accounts(id TEXT PRIMARY KEY, provider TEXT NOT NULL, subject TEXT NOT NULL, scope TEXT NOT NULL, metadata BLOB NOT NULL);
        CREATE UNIQUE INDEX provider_subject_write_key ON provider_accounts(provider, subject, scope, id);
        CREATE TABLE profile_source_grants(profile_id TEXT NOT NULL REFERENCES profiles(id), account_id TEXT NOT NULL REFERENCES provider_accounts(id), can_write INTEGER NOT NULL, PRIMARY KEY(profile_id,account_id));
        CREATE TABLE provider_subject_writers(provider TEXT NOT NULL, subject TEXT NOT NULL, scope TEXT NOT NULL, profile_id TEXT NOT NULL REFERENCES profiles(id), account_id TEXT NOT NULL REFERENCES provider_accounts(id), PRIMARY KEY(provider,subject,scope));
        CREATE TABLE ledger_operations(op_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id), item_key TEXT NOT NULL, field_key TEXT NOT NULL, payload BLOB NOT NULL, wall_ms INTEGER NOT NULL, logical INTEGER NOT NULL, node TEXT NOT NULL, device_id TEXT NOT NULL);
        CREATE INDEX ledger_profile_item_clock ON ledger_operations(profile_id,item_key,wall_ms,logical,node,op_id);
        """,
        """
        CREATE TABLE catalog_generations(generation INTEGER PRIMARY KEY, state TEXT NOT NULL CHECK(state IN ('staging','published')), created_at REAL NOT NULL);
        CREATE TABLE canonical_titles(generation INTEGER NOT NULL REFERENCES catalog_generations(generation) ON DELETE CASCADE, canonical_key TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, normalized_title TEXT NOT NULL, year INTEGER, parent_key TEXT, edition TEXT, metadata BLOB NOT NULL, PRIMARY KEY(generation,canonical_key));
        CREATE INDEX catalog_keyset ON canonical_titles(generation,canonical_key);
        CREATE TABLE source_partitions(generation INTEGER NOT NULL, account_id TEXT NOT NULL, source_item_id TEXT NOT NULL, canonical_key TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(generation,account_id,source_item_id), FOREIGN KEY(generation,canonical_key) REFERENCES canonical_titles(generation,canonical_key) ON DELETE CASCADE);
        CREATE TABLE media_versions(generation INTEGER NOT NULL, account_id TEXT NOT NULL, source_item_id TEXT NOT NULL, edition TEXT, quality TEXT, payload BLOB NOT NULL, PRIMARY KEY(generation,account_id,source_item_id,edition));
        CREATE TABLE catalog_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), active_generation INTEGER NOT NULL);
        INSERT INTO catalog_state(singleton,active_generation) VALUES(1,0);
        """,
        """
        CREATE VIRTUAL TABLE canonical_titles_fts USING fts5(generation UNINDEXED, canonical_key UNINDEXED, title);
        CREATE TRIGGER catalog_title_fts_insert AFTER INSERT ON canonical_titles BEGIN INSERT INTO canonical_titles_fts(generation,canonical_key,title) VALUES(new.generation,new.canonical_key,new.normalized_title); END;
        CREATE TRIGGER catalog_title_fts_delete AFTER DELETE ON canonical_titles BEGIN DELETE FROM canonical_titles_fts WHERE generation=old.generation AND canonical_key=old.canonical_key; END;
        """
    ]
    public static func migrate(_ writer: SQLiteWriter) async throws { try await writer.migrate(to: latestVersion, statements: migrations) }
}
