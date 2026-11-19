import Foundation
import BotCore
import CSQLite

/// One in-memory SQLite connection. Callers may hop threads; every statement runs on `queue`.
final class QQMemoryStore: @unchecked Sendable {
    struct Overview: Sendable {
        var scope: String
        var items: Int
        var categories: [(name: String, count: Int, lines: [(id: String, text: String)])]
    }
    private let queue = DispatchQueue(label: "dafeiyu.memory.sqlite")
    private let file: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let schema = """
    CREATE TABLE IF NOT EXISTS subjects (id INTEGER PRIMARY KEY, scope TEXT NOT NULL, subject TEXT NOT NULL, first_seen REAL NOT NULL, last_seen REAL NOT NULL, UNIQUE(scope, subject));
    CREATE TABLE IF NOT EXISTS categories (id INTEGER PRIMARY KEY, subject_id INTEGER NOT NULL REFERENCES subjects(id) ON DELETE CASCADE, name TEXT NOT NULL, item_count INTEGER NOT NULL DEFAULT 0, mention_count INTEGER NOT NULL DEFAULT 0, last_mentioned REAL NOT NULL, created_at REAL NOT NULL, UNIQUE(subject_id, name));
    CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, subject_id INTEGER NOT NULL REFERENCES subjects(id) ON DELETE CASCADE, kind TEXT NOT NULL, text TEXT NOT NULL, keywords TEXT NOT NULL, importance INTEGER NOT NULL, source_ids TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, expires_at REAL NOT NULL, invalidated_at REAL, mention_count INTEGER NOT NULL DEFAULT 1, last_mentioned REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS item_categories (item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE, PRIMARY KEY(category_id, item_id)) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS terms (term TEXT NOT NULL, item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, PRIMARY KEY(term, item_id)) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS events (scope TEXT NOT NULL, id TEXT NOT NULL, subject_id INTEGER NOT NULL, text TEXT NOT NULL, at REAL NOT NULL, learned INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(scope, id));
    CREATE TABLE IF NOT EXISTS event_terms (term TEXT NOT NULL, scope TEXT NOT NULL, event_id TEXT NOT NULL, PRIMARY KEY(term, scope, event_id)) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS scope_meta (scope TEXT PRIMARY KEY, rolling_summary TEXT NOT NULL DEFAULT '', turns INTEGER NOT NULL DEFAULT 0, super_day TEXT NOT NULL DEFAULT '', super_count INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS items_subject_current ON items(subject_id, invalidated_at, expires_at);
    CREATE INDEX IF NOT EXISTS categories_rank ON categories(subject_id, last_mentioned DESC);
    """

    init(directory: URL, limitMB: Int) throws {
        file = directory.appendingPathComponent("qq-memory.sqlite")
        try queue.sync {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY, nil) == SQLITE_OK, let handle else {
                throw AppFailure.message("记忆库无法在内存中打开")
            }
            db = handle
            sqlite3_hard_heap_limit64(Int64(max(256, min(16384, limitMB))) * 1024 * 1024)
            try exec("PRAGMA foreign_keys=ON")
            if FileManager.default.fileExists(atPath: file.path) {
                try transfer(from: file, intoMemory: true)
                guard try string("PRAGMA integrity_check") == "ok" else { throw AppFailure.message("记忆库快照校验失败") }
                guard try integer("PRAGMA user_version") == 1 else { throw AppFailure.message("记忆库版本无法读取") }
            } else {
                try execScript(schema + "\nPRAGMA user_version=1;")
            }
        }
    }
    deinit { if let db { sqlite3_close(db) } }

    func setLimit(megabytes: Int) { queue.sync { sqlite3_hard_heap_limit64(Int64(megabytes) * 1024 * 1024) } }
    func usageBytes() -> Int { queue.sync { (try? integer("PRAGMA page_count") * integer("PRAGMA page_size")) ?? 0 } }
    func factCount(_ scope: String) -> Int { queue.sync { (try? integer("SELECT count(*) FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=?", scope)) ?? 0 } }
    func contains(_ scope: String, text: String) -> Bool { queue.sync { ((try? integer("SELECT count(*) FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND i.text=?", scope, text)) ?? 0) > 0 } }

    func importScope(_ scope: String, items: [QQMemoryItem]) throws {
        try queue.sync {
            try transaction {
                for item in items { try insert(scope, item, categories: [QQMemoryCategory.fallback(kind: item.kind)], mentions: 1, last: item.updatedAt) }
            }
        }
    }
    func allItems(_ scope: String) -> [QQMemoryItem] {
        queue.sync { (try? stored("SELECT i.id,s.subject,i.kind,i.text,i.keywords,i.importance,i.source_ids,i.updated_at,i.expires_at,i.invalidated_at,i.mention_count,i.last_mentioned FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=?", scope).map(\.item)) ?? [] }
    }
    func commit(scope: String, before: [QQMemoryItem], after: [QQMemoryItem], changes: [QQMemoryDelta.Change], now: Date) throws {
        try queue.sync {
            try transaction {
                let prior = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
                for item in after where prior[item.id] == nil {
                    let match = changes.first { $0.operation == "upsert" && $0.subject == item.subject && $0.text == item.text }
                    let requested = QQMemoryCategory.checked(match?.categories ?? []) ?? []
                    let names = requested.isEmpty ? [QQMemoryCategory.fallback(kind: item.kind)] : QQMemoryCategory.fit(requested, existing: categoryNames(scope, subject: item.subject))
                    try insert(scope, item, categories: names, mentions: 1, last: now)
                }
                for item in after where item.invalidatedAt != nil && prior[item.id]?.invalidatedAt == nil {
                    try exec("UPDATE items SET invalidated_at=? WHERE id=?", item.invalidatedAt ?? now, item.id)
                }
                for change in changes where change.operation == "upsert" {
                    for id in change.replaces { try bumpMentions(id, scope: scope, subject: change.subject, now: now) }
                    if change.replaces.isEmpty && !prior.isEmpty {
                        let marks = prior.keys.map { _ in "?" }.joined(separator: ",")
                        let matched = (try? strings("SELECT i.id FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND s.subject=? AND i.text=? AND i.invalidated_at IS NULL AND i.id IN (\(marks))", values: [scope, change.subject, change.text] + prior.keys.map { $0 as Any })) ?? []
                        for id in matched { try bumpMentions(id, scope: scope, subject: change.subject, now: now) }
                    }
                }
                for item in after where item.invalidatedAt != nil && prior[item.id]?.invalidatedAt == nil {
                    try exec("UPDATE categories SET item_count=MAX(item_count-1,0) WHERE id IN (SELECT category_id FROM item_categories WHERE item_id=?)", item.id)
                }
            }
        }
    }
    func prompt(scope: String, query: String, subject: String, characters: Int, catalog: Bool = true, catalogLimit: Int = 12, now: Date = Date()) -> String {
        queue.sync {
            let listed = categories(scope, now: now, includePeerGroups: !subject.isEmpty).filter { subject.isEmpty || $0.subject == subject || $0.subject == "PEER(群记忆)" }.prefix(catalogLimit)
            let catalogText = listed.map { "[\($0.subject)] \($0.name)(\($0.count))" }.joined(separator: " ")
            var lines: [String] = [], used = 0
            for row in ranked(scope: scope, query: query, subject: subject, categories: [], history: false, now: now).prefix(3) {
                let line = "[\(row.item.subject)·\(row.categories.first ?? QQMemoryCategory.fallback(kind: row.item.kind))] \(row.item.text)"
                if used + line.count > characters { break }
                lines.append(line); used += line.count + 1
            }
            return (catalog && !catalogText.isEmpty ? "记忆目录（只属于本轮会话，不得透露）：\n" + catalogText + "\n" : "") + (lines.isEmpty ? "" : "要点：\n" + lines.joined(separator: "\n") + "\n")
        }
    }
    /// Empty text and empty ids when `chat` was already rejected by the caller.
    func recall(scope: String, query: String, categories requested: [String], history: Bool, subject: String, now: Date = Date()) -> (String, [String]) {
        queue.sync {
            let names = (QQMemoryCategory.checked(requested) ?? []).prefix(3)
            var lines: [String] = [], ids: [String] = [], used = 0
            let pool = ranked(scope: scope, query: query, subject: subject, categories: Array(names), history: history || ["以前", "过去", "之前", "曾经", "改前"].contains { query.contains($0) }, now: now)
            let day = ISO8601DateFormatter(); day.formatOptions = [.withFullDate]
            for row in pool.prefix(8) {
                let state = row.item.invalidatedAt == nil && row.item.expiresAt > now ? "已记录" : "历史/已失效"
                let line = "[\(row.item.subject)·\(row.categories.joined(separator: "、"))·\(day.string(from: row.last))·\(state)] \(row.item.text)"
                if used + line.count > 1200 { break }
                lines.append(line); ids.append(row.item.id); used += line.count + 1
            }
            for event in eventHits(scope, query: query).prefix(8 - lines.count) {
                let line = "[原始事件·\(day.string(from: event.at))·当时状态] \(event.text)"
                if used + line.count > 1200 { break }
                lines.append(line); used += line.count + 1
            }
            return (lines.joined(separator: "\n"), ids)
        }
    }
    func bump(_ ids: [String], now: Date) throws {
        guard !ids.isEmpty else { return }
        try queue.sync { try transaction { for id in ids { try bumpMentions(id, scope: nil, subject: nil, now: now) } } }
    }
    func addEvent(scope: String, event: QQMemoryEvent) throws {
        try queue.sync {
            try transaction {
                let subject = try subjectID(scope, event.subject, now: event.at)
                try exec("INSERT OR IGNORE INTO events(scope,id,subject_id,text,at,learned) VALUES(?,?,?,?,?,0)", scope, event.id, subject, event.text, event.at)
                for term in QQMemoryIndex.terms(event.text) { try exec("INSERT OR IGNORE INTO event_terms(term,scope,event_id) VALUES(?,?,?)", term, scope, event.id) }
            }
        }
    }
    func deleteScope(_ scope: String) throws {
        try queue.sync {
            try transaction {
                try exec("DELETE FROM event_terms WHERE scope=?", scope)
                try exec("DELETE FROM events WHERE scope=?", scope)
                try exec("DELETE FROM subjects WHERE scope=?", scope)
                try exec("DELETE FROM scope_meta WHERE scope=?", scope)
            }
        }
    }
    func deleteItem(scope: String, id: String) throws {
        try queue.sync {
            guard try integer("SELECT count(*) FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND i.id=?", scope, id) == 1 else { throw AppFailure.message("记忆条目不在当前账号的会话中") }
            try exec("UPDATE categories SET item_count=MAX(item_count-1,0) WHERE id IN (SELECT category_id FROM item_categories WHERE item_id=?)", id)
            try exec("DELETE FROM items WHERE id=?", id)
        }
    }
    func deleteCategory(scope: String, name: String) throws {
        try queue.sync { try exec("DELETE FROM categories WHERE name=? AND subject_id IN (SELECT id FROM subjects WHERE scope=?)", name, scope) }
    }
    func overview() -> [Overview] {
        queue.sync {
            let scopes = (try? strings("SELECT DISTINCT scope FROM subjects ORDER BY scope")) ?? []
            return scopes.map { scope in
                let names = categories(scope, now: Date()).prefix(12).map(\.name)
                let groups = names.map { name in
                    let lines = (try? pairs("SELECT i.id,i.text FROM items i JOIN item_categories ic ON ic.item_id=i.id JOIN categories c ON c.id=ic.category_id JOIN subjects s ON s.id=c.subject_id WHERE s.scope=? AND c.name=? AND i.invalidated_at IS NULL ORDER BY i.last_mentioned DESC LIMIT 8", scope, name)) ?? []
                    return (name: name, count: lines.count, lines: lines)
                }
                return Overview(scope: scope, items: (try? integer("SELECT count(*) FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND i.invalidated_at IS NULL", scope)) ?? 0, categories: groups)
            }
        }
    }
    func rememberSummary(_ scope: String, _ summary: String) throws {
        guard !summary.isEmpty else { return }
        try queue.sync { try exec("INSERT INTO scope_meta(scope,rolling_summary,turns) VALUES(?,?,0) ON CONFLICT(scope) DO UPDATE SET rolling_summary=excluded.rolling_summary, turns=0", scope, summary) }
    }
    func rollingSummary(_ scope: String) -> String { queue.sync { (try? string("SELECT rolling_summary FROM scope_meta WHERE scope=?", scope)) ?? "" } }
    func turns(_ scope: String) -> Int { queue.sync { (try? integer("SELECT turns FROM scope_meta WHERE scope=?", scope)) ?? 0 } }
    func noteTurn(_ scope: String, summary: String?) throws {
        try queue.sync {
            try exec("INSERT INTO scope_meta(scope,rolling_summary,turns) VALUES(?,?,1) ON CONFLICT(scope) DO UPDATE SET turns=turns+1, rolling_summary=CASE WHEN ?!='' THEN ? ELSE rolling_summary END", scope, summary ?? "", summary ?? "", summary ?? "")
        }
    }
    func resetTurns(_ scope: String) throws { try queue.sync { try exec("UPDATE scope_meta SET turns=0 WHERE scope=?", scope) } }
    func superLimited(_ scope: String, limit: Int, now: Date = Date()) -> Bool {
        queue.sync {
            let day = Self.day(now)
            let count = (try? integer("SELECT super_count FROM scope_meta WHERE scope=? AND super_day=?", scope, day)) ?? 0
            return count >= limit
        }
    }
    func recordSuperLearn(_ scope: String, now: Date = Date()) throws {
        let day = Self.day(now)
        try queue.sync { try exec("INSERT INTO scope_meta(scope,super_day,super_count) VALUES(?,?,1) ON CONFLICT(scope) DO UPDATE SET super_count=CASE WHEN super_day=? THEN super_count+1 ELSE 1 END, super_day=?", scope, day, day, day) }
    }
    func superCount(_ scope: String, now: Date = Date()) -> Int {
        queue.sync { (try? integer("SELECT super_count FROM scope_meta WHERE scope=? AND super_day=?", scope, Self.day(now))) ?? 0 }
    }
    func snapshot() throws {
        try queue.sync {
            let temporary = file.appendingPathExtension("tmp")
            if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
            var disk: OpaquePointer?
            guard sqlite3_open_v2(temporary.path, &disk, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let opened = disk, let db else {
                if let disk { sqlite3_close(disk) }
                throw AppFailure.message("记忆快照无法创建")
            }
            do {
                try copy(from: db, to: opened)
                try exec(on: opened, "PRAGMA wal_checkpoint(TRUNCATE)")
            } catch {
                sqlite3_close(opened)
                throw error
            }
            // Windows cannot replace a file that still has a SQLite handle open.
            sqlite3_close(opened)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize(); try handle.close()
            try replacePrivateFile(at: file, with: temporary)
        }
    }
    /// Proves a thrown statement does not keep its writes.
    func testingRollback() throws {
        try queue.sync {
            do {
                try transaction {
                    try exec("INSERT INTO scope_meta(scope,rolling_summary,turns) VALUES('rollback-test','x',1)")
                    throw AppFailure.message("expected")
                }
            } catch {}
            guard ((try? integer("SELECT count(*) FROM scope_meta WHERE scope='rollback-test'")) ?? 1) == 0 else {
                throw AppFailure.message("事务没有回滚")
            }
        }
    }
    func testingSetByteLimit(_ bytes: Int64) { queue.sync { sqlite3_hard_heap_limit64(bytes) } }

    private struct Stored { var item: QQMemoryItem; var mentions: Int; var last: Date; var categories: [String] }
    /// Private chats may read this specific peer's verified memories from groups under the same account.
    /// Groups never read private chats or other groups.
    private func peerGroupScopes(for scope: String) -> [(scope: String, subject: String)] {
        let parts = scope.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[1] == "private", !parts[0].isEmpty, !parts[2].isEmpty else { return [] }
        let account = parts[0], peer = parts[2]
        let groupScopes = (try? strings("SELECT DISTINCT scope FROM subjects WHERE scope LIKE ? ORDER BY scope", account + ":group:%")) ?? []
        return groupScopes.map { groupScope in
            let target = String(groupScope.dropFirst(account.count + 1))
            return (scope: groupScope, subject: QQMemoryBook.subject(account: account, target: target, sender: peer))
        }
    }
    private func ranked(scope: String, query: String, subject: String, categories requested: [String], history: Bool, now: Date) -> [Stored] {
        let terms = QQMemoryIndex.terms(query)
        var ids = Set<String>()
        for term in terms.prefix(24) {
            ids.formUnion((try? strings("SELECT i.id FROM terms t JOIN items i ON i.id=t.item_id JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND t.term=? LIMIT 40", scope, term)) ?? [])
            if ids.count >= 80 { break }
        }
        ids.formUnion((try? strings("SELECT i.id FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND s.subject=? AND i.kind IN ('preference','task','legacy') AND i.invalidated_at IS NULL LIMIT 12", scope, subject)) ?? [])
        if !requested.isEmpty {
            let allowed = Set(requested.flatMap { name in (try? strings("SELECT ic.item_id FROM item_categories ic JOIN categories c ON c.id=ic.category_id JOIN subjects s ON s.id=c.subject_id WHERE s.scope=? AND c.name=?", scope, name)) ?? [] })
            ids.formIntersection(allowed)
        }
        let cutoff = now.addingTimeInterval(-90 * 86400)
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        var selected = ids.isEmpty ? [] : ((try? stored("SELECT i.id,s.subject,i.kind,i.text,i.keywords,i.importance,i.source_ids,i.updated_at,i.expires_at,i.invalidated_at,i.mention_count,i.last_mentioned FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND i.id IN (\(marks))", values: [scope] + ids.map { $0 as Any })) ?? [])
        for related in peerGroupScopes(for: scope) {
            var groupIDs = Set<String>()
            for term in terms.prefix(24) {
                groupIDs.formUnion((try? strings("SELECT i.id FROM terms t JOIN items i ON i.id=t.item_id JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND s.subject=? AND i.kind!='legacy' AND t.term=? LIMIT 20", related.scope, related.subject, term)) ?? [])
                if groupIDs.count >= 40 { break }
            }
            groupIDs.formUnion((try? strings("SELECT i.id FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND s.subject=? AND i.kind IN ('preference','task') AND i.invalidated_at IS NULL LIMIT 8", related.scope, related.subject)) ?? [])
            if !requested.isEmpty {
                let allowed = Set(requested.flatMap { name in (try? strings("SELECT ic.item_id FROM item_categories ic JOIN categories c ON c.id=ic.category_id JOIN subjects s ON s.id=c.subject_id WHERE s.scope=? AND s.subject=? AND c.name=?", related.scope, related.subject, name)) ?? [] })
                groupIDs.formIntersection(allowed)
            }
            guard !groupIDs.isEmpty else { continue }
            let groupMarks = groupIDs.map { _ in "?" }.joined(separator: ",")
            let rows = (try? stored("SELECT i.id,s.subject,i.kind,i.text,i.keywords,i.importance,i.source_ids,i.updated_at,i.expires_at,i.invalidated_at,i.mention_count,i.last_mentioned FROM items i JOIN subjects s ON s.id=i.subject_id WHERE s.scope=? AND s.subject=? AND i.kind!='legacy' AND i.id IN (\(groupMarks))", values: [related.scope, related.subject] + groupIDs.map { $0 as Any })) ?? []
            for var row in rows {
                row.item = QQMemoryItem(id: row.item.id, subject: "PEER(群记忆)", kind: row.item.kind, text: row.item.text, keywords: row.item.keywords, importance: row.item.importance, sourceIDs: row.item.sourceIDs, updatedAt: row.item.updatedAt, expiresAt: row.item.expiresAt, invalidatedAt: row.item.invalidatedAt)
                selected.append(row)
            }
        }
        let pool = selected.filter { row in
            if row.item.invalidatedAt == nil && row.item.expiresAt > now { return true }
            guard history, let ended = row.item.invalidatedAt else { return false }
            return ended > cutoff
        }
        return pool.sorted { lhs, rhs in
            let leftTerms = QQMemoryIndex.terms(lhs.item.text + " " + lhs.item.keywords.joined(separator: " "))
            let rightTerms = QQMemoryIndex.terms(rhs.item.text + " " + rhs.item.keywords.joined(separator: " "))
            let left = QQMemoryRank.score(lexical: Double(leftTerms.intersection(terms).count), last: lhs.last, mentions: lhs.mentions, importance: lhs.item.importance, requestedCategory: !requested.filter { lhs.categories.contains($0) }.isEmpty, now: now)
            let right = QQMemoryRank.score(lexical: Double(rightTerms.intersection(terms).count), last: rhs.last, mentions: rhs.mentions, importance: rhs.item.importance, requestedCategory: !requested.filter { rhs.categories.contains($0) }.isEmpty, now: now)
            return left == right ? lhs.item.id < rhs.item.id : left > right
        }
    }
    private func eventHits(_ scope: String, query: String) -> [(text: String, at: Date)] {
        var result: [(String, Date)] = []
        let related = peerGroupScopes(for: scope)
        for term in QQMemoryIndex.terms(query).prefix(12) {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT e.text,e.at FROM events e JOIN event_terms t ON t.scope=e.scope AND t.event_id=e.id WHERE e.scope=? AND t.term=? LIMIT 8", -1, &statement, nil) == SQLITE_OK, let statement {
                defer { sqlite3_finalize(statement) }
                bind(statement, [scope, term])
                while sqlite3_step(statement) == SQLITE_ROW {
                    result.append((columnText(statement, 0), Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))))
                }
            }
            for group in related {
                var groupStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT e.text,e.at FROM events e JOIN subjects s ON s.id=e.subject_id JOIN event_terms t ON t.scope=e.scope AND t.event_id=e.id WHERE e.scope=? AND s.subject=? AND t.term=? LIMIT 4", -1, &groupStmt, nil) == SQLITE_OK, let groupStmt else { continue }
                defer { sqlite3_finalize(groupStmt) }
                bind(groupStmt, [group.scope, group.subject, term])
                while sqlite3_step(groupStmt) == SQLITE_ROW {
                    result.append((columnText(groupStmt, 0), Date(timeIntervalSince1970: sqlite3_column_double(groupStmt, 1))))
                }
            }
        }
        return result
    }
    private func bumpMentions(_ id: String, scope: String?, subject: String?, now: Date) throws {
        if let scope, let subject {
            guard try integer("SELECT count(*) FROM items i JOIN subjects s ON s.id=i.subject_id WHERE i.id=? AND s.scope=? AND s.subject=? AND i.invalidated_at IS NULL", id, scope, subject) == 1 else { return }
        }
        try exec("UPDATE items SET mention_count=mention_count+1, last_mentioned=? WHERE id=? AND invalidated_at IS NULL", now, id)
        try exec("UPDATE categories SET mention_count=mention_count+1, last_mentioned=? WHERE id IN (SELECT category_id FROM item_categories WHERE item_id=?)", now, id)
    }
    private func categories(_ scope: String, now: Date, includePeerGroups: Bool = false) -> [(subject: String, name: String, count: Int, heat: Double)] {
        var result: [(String, String, Int, Double)] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT s.subject,c.name,c.item_count,c.mention_count,c.last_mentioned FROM categories c JOIN subjects s ON s.id=c.subject_id WHERE s.scope=?", -1, &statement, nil) == SQLITE_OK, let statement {
            defer { sqlite3_finalize(statement) }
            bind(statement, [scope])
            while sqlite3_step(statement) == SQLITE_ROW {
                let subject = columnText(statement, 0)
                let name = columnText(statement, 1)
                let count = Int(sqlite3_column_int(statement, 2))
                let mentions = Int(sqlite3_column_int(statement, 3))
                let last = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                result.append((subject, name, count, QQMemoryRank.categoryHeat(last: last, mentions: mentions, now: now)))
            }
        }
        if includePeerGroups {
            for related in peerGroupScopes(for: scope) {
                var groupStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT c.name,c.item_count,c.mention_count,c.last_mentioned FROM categories c JOIN subjects s ON s.id=c.subject_id WHERE s.scope=? AND s.subject=? AND EXISTS (SELECT 1 FROM item_categories ic JOIN items i ON i.id=ic.item_id WHERE ic.category_id=c.id AND i.kind!='legacy' AND i.invalidated_at IS NULL)", -1, &groupStmt, nil) == SQLITE_OK, let groupStmt else { continue }
                defer { sqlite3_finalize(groupStmt) }
                bind(groupStmt, [related.scope, related.subject])
                while sqlite3_step(groupStmt) == SQLITE_ROW {
                    let name = columnText(groupStmt, 0)
                    let count = Int(sqlite3_column_int(groupStmt, 1))
                    let mentions = Int(sqlite3_column_int(groupStmt, 2))
                    let last = Date(timeIntervalSince1970: sqlite3_column_double(groupStmt, 3))
                    result.append(("PEER(群记忆)", name, count, QQMemoryRank.categoryHeat(last: last, mentions: mentions, now: now)))
                }
            }
        }
        return result.sorted { $0.3 > $1.3 }
    }
    private func categoryNames(_ scope: String, subject: String) -> [String] {
        (try? strings("SELECT c.name FROM categories c JOIN subjects s ON s.id=c.subject_id WHERE s.scope=? AND s.subject=?", scope, subject)) ?? []
    }
    private func insert(_ scope: String, _ item: QQMemoryItem, categories names: [String], mentions: Int, last: Date) throws {
        let subject = try subjectID(scope, item.subject, now: item.updatedAt)
        let keywords = String(decoding: try JSONSerialization.data(withJSONObject: item.keywords), as: UTF8.self)
        let sources = String(decoding: try JSONSerialization.data(withJSONObject: item.sourceIDs), as: UTF8.self)
        try exec("INSERT OR REPLACE INTO items(id,subject_id,kind,text,keywords,importance,source_ids,created_at,updated_at,expires_at,invalidated_at,mention_count,last_mentioned) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                 item.id, subject, item.kind, item.text, keywords, item.importance, sources, item.updatedAt, item.updatedAt, item.expiresAt, item.invalidatedAt as Any, mentions, last)
        for term in QQMemoryIndex.terms(item.text + " " + item.keywords.joined(separator: " ")) { try exec("INSERT OR IGNORE INTO terms(term,item_id) VALUES(?,?)", term, item.id) }
        for name in QQMemoryCategory.fit(names, existing: categoryNames(scope, subject: item.subject)) {
            try exec("INSERT INTO categories(subject_id,name,item_count,mention_count,last_mentioned,created_at) VALUES(?,?,1,?, ?,?) ON CONFLICT(subject_id,name) DO UPDATE SET item_count=item_count+1, last_mentioned=excluded.last_mentioned",
                     subject, name, mentions, last, last)
            try exec("INSERT OR IGNORE INTO item_categories(item_id,category_id) SELECT ?,id FROM categories WHERE subject_id=? AND name=?", item.id, subject, name)
        }
    }
    private func subjectID(_ scope: String, _ subject: String, now: Date) throws -> Int {
        try exec("INSERT INTO subjects(scope,subject,first_seen,last_seen) VALUES(?,?,?,?) ON CONFLICT(scope,subject) DO UPDATE SET last_seen=excluded.last_seen", scope, subject, now, now)
        return try integer("SELECT id FROM subjects WHERE scope=? AND subject=?", scope, subject)
    }
    private func stored(_ sql: String, _ values: Any...) throws -> [Stored] { try stored(sql, values: values) }
    private func stored(_ sql: String, values: [Any]) throws -> [Stored] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AppFailure.message("记忆查询无法准备") }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var result: [Stored] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let keywords = (try? JSONSerialization.jsonObject(with: Data(columnText(statement, 4).utf8)) as? [String]) ?? []
            let sources = (try? JSONSerialization.jsonObject(with: Data(columnText(statement, 6).utf8)) as? [String]) ?? []
            let updated = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            let invalidated = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
            let item = QQMemoryItem(id: columnText(statement, 0), subject: columnText(statement, 1), kind: columnText(statement, 2), text: columnText(statement, 3), keywords: keywords, importance: Int(sqlite3_column_int(statement, 5)), sourceIDs: sources, updatedAt: updated, expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)), invalidatedAt: invalidated)
            let names = (try? strings("SELECT c.name FROM categories c JOIN item_categories ic ON ic.category_id=c.id WHERE ic.item_id=?", item.id)) ?? []
            result.append(Stored(item: item, mentions: Int(sqlite3_column_int(statement, 10)), last: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)), categories: names))
        }
        return result
    }
    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }
    private func transfer(from origin: URL, intoMemory: Bool) throws {
        var disk: OpaquePointer?
        guard sqlite3_open_v2(origin.path, &disk, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let disk, let db else { throw AppFailure.message("记忆快照无法打开") }
        defer { sqlite3_close(disk) }
        if intoMemory { try copy(from: disk, to: db) } else { try copy(from: db, to: disk) }
    }
    private func copy(from source: OpaquePointer, to destination: OpaquePointer) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw AppFailure.message("记忆快照无法开始") }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { throw AppFailure.message("记忆快照没有完成") }
    }
    private func execScript(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppFailure.message(String(cString: sqlite3_errmsg(db))) }
    }
    private func exec(_ sql: String, _ values: Any...) throws { try exec(sql, values: values) }
    private func exec(_ sql: String, values: [Any]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AppFailure.message(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw AppFailure.message(result == SQLITE_NOMEM ? "记忆库已达到内存上限，已停止写入新内容" : String(cString: sqlite3_errmsg(db))) }
    }
    private func exec(on database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw AppFailure.message(String(cString: sqlite3_errmsg(database))) }
    }
    private func integer(_ sql: String, _ values: Any...) throws -> Int { try scalar(sql, values) { Int(sqlite3_column_int($0, 0)) } }
    private func string(_ sql: String, _ values: Any...) throws -> String { try scalar(sql, values) { sqlite3_column_text($0, 0).map { String(cString: $0) } ?? "" } }
    private func pairs(_ sql: String, _ values: Any...) throws -> [(id: String, text: String)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var result: [(id: String, text: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append((id: columnText(statement, 0), text: columnText(statement, 1))) }
        return result
    }
    private func strings(_ sql: String, _ values: Any...) throws -> [String] { try strings(sql, values: values) }
    private func strings(_ sql: String, values: [Any]) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(columnText(statement, 0)) }
        return result
    }
    private func scalar<T>(_ sql: String, _ values: [Any], _ read: (OpaquePointer) -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AppFailure.message("记忆查询无法准备") }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AppFailure.message("记忆查询没有结果") }
        return read(statement)
    }
    private func bind(_ statement: OpaquePointer, _ values: [Any]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case let date as Date: sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
            case let number as Int: sqlite3_bind_int64(statement, index, sqlite3_int64(number))
            case let number as Int64: sqlite3_bind_int64(statement, index, number)
            default: sqlite3_bind_null(statement, index)
            }
        }
    }
    private static func day(_ date: Date) -> String { String(ISO8601DateFormatter().string(from: date).prefix(10)) }
    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }
}

extension QQMemoryRecall {
    static var definition: [String: Any] {
        ["type": "function", "function": ["name": "recall_memory",
         "description": "查询本轮这一个会话自己的长期记忆。chat 必须等于提示词给出的群号或私聊对象 QQ 号，否则不会查询。不能读取其他会话。",
         "parameters": ["type": "object", "properties": ["chat": ["type": "string"], "categories": ["type": "array", "items": ["type": "string"]], "query": ["type": "string"], "include_history": ["type": "boolean"]], "required": ["chat"], "additionalProperties": false]]]
    }
}
