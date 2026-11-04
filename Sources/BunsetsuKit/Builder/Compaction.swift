// Compaction: from a full ichiran database to a compact one where conjugations are computed at
// lookup time (see VirtualConjugations.swift).
//
// The compact database keeps every dictionary entry, all conjugation links that point to dictionary
// entries, and the conjugation rules. For every conjugated word the runtime generator is run against
// the compact database and compared with the stored conjugations; words whose conjugations are not
// reproduced exactly keep their stored conjugations ("materialized").

import Foundation

nonisolated(unsafe) var debugReason = ""

extension DictionaryBuilder {
    /// Writes a compact copy of the database built by `build` to `path`.
    public func compact(to path: String) throws {
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        if conjRules.isEmpty { try loadCSVs() }
        let out = try SQLiteDB(path: path, create: true)
        out.exec("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA cache_size = -200000; PRAGMA temp_store = MEMORY;")
        out.exec(Schema.dictTables)
        out.exec(Schema.compactTables)
        out.exec(Schema.kanjiTables)
        out.exec("CREATE TABLE IF NOT EXISTS conj_description (id INTEGER PRIMARY KEY, description TEXT NOT NULL)")
        db.exec("PRAGMA wal_checkpoint")
        out.run("ATTACH DATABASE ? AS f", [db.path])

        log("Copying dictionary entries...")
        out.transaction {
            out.exec("""
                CREATE TEMP TABLE keep AS SELECT seq FROM f.entry e
                WHERE e.root_p OR NOT EXISTS (SELECT 1 FROM f.conjugation c WHERE c.seq = e.seq);
                CREATE UNIQUE INDEX temp.keep_seq ON keep(seq);
                INSERT INTO entry SELECT * FROM f.entry WHERE seq IN keep;
                INSERT INTO kanji_text SELECT * FROM f.kanji_text WHERE seq IN keep;
                INSERT INTO kana_text SELECT * FROM f.kana_text WHERE seq IN keep;
                INSERT INTO sense SELECT * FROM f.sense WHERE seq IN keep;
                INSERT INTO gloss SELECT g.* FROM f.gloss g JOIN f.sense s ON s.id = g.sense_id WHERE s.seq IN keep;
                INSERT INTO sense_prop SELECT * FROM f.sense_prop WHERE seq IN keep;
                INSERT INTO restricted_readings SELECT * FROM f.restricted_readings WHERE seq IN keep;
                INSERT INTO conjugation SELECT * FROM f.conjugation WHERE seq IN keep;
                INSERT INTO conj_prop SELECT p.* FROM f.conj_prop p JOIN conjugation c ON c.id = p.conj_id;
                INSERT INTO conj_source_reading SELECT r.* FROM f.conj_source_reading r JOIN conjugation c ON c.id = r.conj_id;
                INSERT INTO conj_description SELECT * FROM f.conj_description;
                """)
            if !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'kanji'").isEmpty {
                out.exec("""
                    INSERT INTO kanji SELECT * FROM f.kanji;
                    INSERT INTO reading SELECT * FROM f.reading;
                    INSERT INTO okurigana SELECT * FROM f.okurigana;
                    INSERT INTO meaning SELECT * FROM f.meaning;
                    """)
            }
            // conjugation rules
            for (pos, id) in posIndex.sorted(by: { $0.value < $1.value }) {
                out.run("INSERT INTO pos_index (id, pos) VALUES (?, ?)", [id, pos])
            }
            for posId in conjRules.keys.sorted() {
                for r in conjRules[posId]! {
                    out.run("""
                        INSERT INTO conj_rule (pos_id, conj, neg, fml, onum, stem, okuri, euphr, euphk) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [posId, r.conj, r.neg, r.fml, r.onum, r.stem, r.okuri, r.euphr, r.euphk])
                }
            }
            writePosEndings(out)
            out.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('format', 'compact')")
            out.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('version', ?)", [BunsetsuKitVersion])
        }
        out.exec(Schema.dictIndexes)

        out.transaction { writeConjGroups(out) }
        log("Verifying generated conjugations...")
        let mismatched = verifyConjugations(out)
        log("\(mismatched.count) words keep their stored conjugations")
        out.transaction {
            materialize(out, mismatched)
            writeTextBloom(out)
        }
        out.exec("DETACH DATABASE f")
        out.exec("ANALYZE")
        out.exec("VACUUM")
        log("Done.")
    }

    /// Possible dictionary form endings per part of speech (used to undo conjugations).
    func writePosEndings(_ out: SQLiteDB) {
        var lengths: [Int: Set<Int>] = [:]
        for (posId, rules) in conjRules {
            for r in rules {
                lengths[posId, default: []].insert(r.stem)
                lengths[posId, default: []].insert(r.stem + 1)
            }
        }
        // the verb/adjective classes whose readings are conjugated: all readings of entries with that pos
        for (posId, lens) in lengths {
            guard let pos = posByIndex[posId] else { continue }
            var endings = Set<[String]>()
            for table in ["kanji_text", "kana_text"] {
                for t in out.column("""
                    SELECT DISTINCT t.text FROM \(table) t JOIN sense_prop sp ON sp.seq = t.seq AND sp.tag = 'pos' AND sp.text = ?
                    """, [pos]).compactMap(\.text) {
                    for l in lens { endings.insert([String(l), t.sub(max(0, t.len - l))]) }
                }
            }
            for e in endings {
                out.run("INSERT OR IGNORE INTO pos_ending (pos_id, len, ending) VALUES (?, ?, ?)", [posId, Int(e[0])!, e[1]])
            }
        }
        // secondary conjugations conjugate potential/passive (v1) and causative (v5s) forms
        for (pos, ending) in [("v1", "る"), ("v5s", "す")] {
            guard let posId = posIndex[pos] else { continue }
            for l in lengths[posId] ?? [] where l == 1 {
                out.run("INSERT OR IGNORE INTO pos_ending (pos_id, len, ending) VALUES (?, ?, ?)", [posId, l, ending])
            }
        }
    }

    /// Debugging aid: prints stored and generated conjugations of the first mismatching words.
    public func debugConjugations(compact path: String, start: Int = 0, limit: Int = 5) throws {
        let out = try SQLiteDB(path: path)
        out.run("ATTACH DATABASE ? AS f", [db.path])
        out.exec("CREATE TEMP TABLE keep AS SELECT seq FROM main.entry WHERE NOT materialized")
        out.transaction { writeConjGroups(out) }
        let ich = Ichiran(database: out)
        ich.materializedFrom = []
        var shown = 0
        for from in out.column("SELECT DISTINCT \"from\" FROM f.conjugation WHERE \"from\" >= ? ORDER BY 1", [start]).compactMap(\.int) {
            ich.vstore = VirtualStore()
            let g = generatedDescription(ich, from, ich.generateConjugations(from))
            let st = storedDescription(out, from)
            if st != g {
                print("== \(from)")
                print("stored:"); for l in st ?? ["<not reproducible: \(debugReason)>"] where !g.contains(l) { print("  " + l) }
                print("generated:"); for l in g where !(st ?? []).contains(l) { print("  " + l) }
                shown += 1
                if shown >= limit { return }
            }
        }
    }

    /// Bloom filter of the reading texts of dictionary entries (lets lookups skip most database queries).
    func writeTextBloom(_ out: SQLiteDB) {
        let texts = out.column("""
            SELECT t.text FROM kanji_text t JOIN entry e ON e.seq = t.seq AND NOT e.materialized
            UNION SELECT t.text FROM kana_text t JOIN entry e ON e.seq = t.seq AND NOT e.materialized
            """).compactMap(\.text)
        var bloom = BloomFilter(capacity: texts.count)
        for t in texts { bloom.insert(t) }
        bloom.save(out)
    }

    /// Records which words share conjugated entries (union of the `from`s of each conjugated entry).
    func writeConjGroups(_ out: SQLiteDB) {
        out.exec(Schema.compactTables)
        out.exec("DELETE FROM conj_group")
        var parent: [Int: Int] = [:]
        func find(_ x: Int) -> Int {
            var x = x
            while let p = parent[x], p != x { parent[x] = parent[p] ?? p; x = p }
            return x
        }
        let rows = out.query("""
            SELECT seq, group_concat(DISTINCT "from") FROM f.conjugation WHERE seq NOT IN (SELECT seq FROM keep)
            GROUP BY seq HAVING COUNT(DISTINCT "from") > 1
            """)
        for r in rows {
            let froms = r[1].text!.split(separator: ",").compactMap { Int($0) }
            for f in froms where parent[f] == nil { parent[f] = f }
            for f in froms.dropFirst() {
                let a = find(froms[0]), b = find(f)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        for seq in parent.keys.sorted() { out.run("INSERT INTO conj_group (seq, grp) VALUES (?, ?)", [seq, find(seq)]) }
        log("\(parent.count) words share conjugated forms")
    }

    // MARK: - Verification

    private func boolKey(_ b: Bool?) -> String { b.map { $0 ? "t" : "f" } ?? "n" }

    private func propKey(_ type: Int, _ pos: String, _ neg: Bool?, _ fml: Bool?) -> String {
        "\(type)/\(pos)/\(boolKey(neg))/\(boolKey(fml))"
    }

    private func srcKey(_ src: [(String, String)]) -> String {
        src.map { "\($0.0)<\($0.1)" }.joined(separator: ",")
    }

    /// Canonical description of the conjugations of `from` in the full database (nil: not reproducible).
    func storedDescription(_ out: SQLiteDB, _ from: Int) -> [String]? {
        let rows = out.query("""
            SELECT c.id, c.seq, c.via, c.seq IN (SELECT seq FROM keep) FROM f.conjugation c WHERE c."from" = ? ORDER BY c.seq, c.id
            """, [from])
        var entrySeqs: [Int] = []
        for r in rows where r[3].int == 0 && !entrySeqs.contains(r[1].int!) { entrySeqs.append(r[1].int!) }
        var viaCache: [Int: String] = [:]
        func viaKey(_ via: Int?) -> String? {
            guard let via else { return "-" }
            if let k = viaCache[via] { return k }
            let k: String
            if !out.query("SELECT seq FROM keep WHERE seq = ?", [via]).isEmpty {
                k = "S\(via)"
            } else {
                k = "V(" + out.column("SELECT text FROM f.kanji_text WHERE seq = ? UNION ALL SELECT text FROM f.kana_text WHERE seq = ?",
                                      [via, via]).compactMap(\.text).joined(separator: ",") + ")"
            }
            viaCache[via] = k
            return k
        }
        func conjKey(_ id: Int, _ conjFrom: Int, _ via: Int?) -> String? {
            guard let vk = viaKey(via) else { return nil }
            let props = out.query("SELECT conj_type, pos, neg, fml FROM f.conj_prop WHERE conj_id = ? ORDER BY id", [id])
                .map { propKey($0[0].int!, $0[1].text!, $0[2].bool, $0[3].bool) }.joined(separator: ";")
            let src = out.query("SELECT text, source_text FROM f.conj_source_reading WHERE conj_id = ? ORDER BY id", [id])
                .map { ($0[0].text!, $0[1].text!) }
            return "\(conjFrom == from ? "F" : String(conjFrom))>\(vk)|\(props)|\(srcKey(src))"
        }
        var desc: [String] = []
        for seq in entrySeqs {
            let e = out.query("SELECT root_p, primary_nokanji FROM f.entry WHERE seq = ?", [seq]).first
            if e?[0].bool == true || e?[1].bool == true { debugReason = "root/primary_nokanji \(seq)"; return nil }
            var parts: [String] = []
            for table in ["kanji_text", "kana_text"] {
                let col = table == "kanji_text" ? "best_kana" : "best_kanji"
                parts.append(out.query("""
                    SELECT text, ord, conjugate_p, common, nokanji, \(col), common_tags FROM f.\(table) WHERE seq = ? ORDER BY ord, id
                    """, [seq]).map { r -> String in
                    if !r[3].isNull || r[4].bool == true || !r[5].isNull || r[6].text != "" {
                        return "!\(r[0].text!) common=\(r[3]) nokanji=\(r[4]) best=\(r[5]) tags=\(r[6])"
                    }
                    return "\(r[0].text!)#\(r[1].int!)#\(boolKey(r[2].bool))"
                }.joined(separator: ","))
            }
            for c in out.query("SELECT id, \"from\", via FROM f.conjugation WHERE seq = ? ORDER BY id", [seq]) {
                guard let k = conjKey(c[0].int!, c[1].int!, c[2].int) else { return nil }
                parts.append(k)
            }
            desc.append("E " + parts.joined(separator: " "))
        }
        for r in rows where r[3].int == 1 {
            guard let k = conjKey(r[0].int!, from, r[2].int) else { return nil }
            desc.append("L\(r[1].int!) " + k)
        }
        return desc.sorted()
    }

    /// Canonical description of the generated conjugations of `from`.
    func generatedDescription(_ ich: Ichiran, _ from: Int, _ gen: GeneratedConjugations) -> [String] {
        func viaKey(_ via: Int?) -> String {
            guard let via else { return "-" }
            if let e = ich.virtualEntry(via) { return "V(" + (e.kanji + e.kana).map(\.text).joined(separator: ",") + ")" }
            return "S\(via)"
        }
        func conjKey(_ conjFrom: Int, _ via: Int?, _ props: [ConjProp], _ src: [(text: String, sourceText: String)]) -> String {
            let p = props.map { propKey($0.conjType, $0.pos, $0.neg, $0.fml) }.joined(separator: ";")
            return "\(conjFrom == from ? "F" : String(conjFrom))>\(viaKey(via))|\(p)|\(srcKey(src.map { ($0.text, $0.sourceText) }))"
        }
        var desc: [String] = []
        for e in gen.entries {
            var parts: [String] = []
            for list in [e.kanji, e.kana] {
                parts.append(list.map { "\($0.text)#\($0.ord)#\(boolKey($0.conjugateP))" }.joined(separator: ","))
            }
            for c in e.conjs { parts.append(conjKey(c.from, c.via, e.props(c.id), e.src(c.id))) }
            desc.append("E " + parts.joined(separator: " "))
        }
        for l in gen.storedLinks { desc.append("L\(l.target) " + conjKey(from, l.via, l.props, l.src)) }
        return desc.sorted()
    }

    /// Returns the words whose conjugations the generator does not reproduce.
    func verifyConjugations(_ out: SQLiteDB) -> Set<Int> {
        let ich = Ichiran(database: out)
        var froms = Set(out.column("SELECT DISTINCT \"from\" FROM f.conjugation").compactMap(\.int))
        let posList = posWithConjRules.sorted()
        froms.formUnion(out.column("""
            SELECT DISTINCT seq FROM sense_prop WHERE tag = 'pos' AND text IN \(placeholders(posList.count))
            """, posList.map { $0 as SQLBindable }).compactMap(\.int))
        var mismatched = Set<Int>()
        for (i, from) in froms.sorted().enumerated() {
            ich.vstore = VirtualStore()
            let gen = ich.generateConjugations(from)
            if storedDescription(out, from) != generatedDescription(ich, from, gen) { mismatched.insert(from) }
            if (i + 1) % 10000 == 0 { log("\(i + 1) words verified, \(mismatched.count) mismatches") }
        }
        // conjugated entries shared by several words: all of them must keep their stored conjugations
        var changed = true
        while changed {
            changed = false
            for m in Array(mismatched) {
                for f in out.column("""
                    SELECT DISTINCT c2."from" FROM f.conjugation c1 JOIN f.conjugation c2 ON c1.seq = c2.seq
                    WHERE c1."from" = ? AND c1.seq NOT IN (SELECT seq FROM keep)
                    """, [m]).compactMap(\.int) where !mismatched.contains(f) {
                    mismatched.insert(f)
                    changed = true
                }
            }
        }
        return mismatched
    }

    /// Copies the stored conjugations of `froms` into the compact database.
    func materialize(_ out: SQLiteDB, _ froms: Set<Int>) {
        out.exec("CREATE TEMP TABLE mat (seq INTEGER PRIMARY KEY)")
        for f in froms.sorted() {
            out.run("INSERT INTO materialized_from (seq) VALUES (?)", [f])
            out.run("""
                INSERT OR IGNORE INTO mat SELECT DISTINCT seq FROM f.conjugation WHERE "from" = ? AND seq NOT IN (SELECT seq FROM keep)
                """, [f])
        }
        out.exec("""
            INSERT INTO entry SELECT * FROM f.entry WHERE seq IN mat;
            UPDATE entry SET materialized = 1 WHERE seq IN mat;
            INSERT INTO kanji_text SELECT * FROM f.kanji_text WHERE seq IN mat;
            INSERT INTO kana_text SELECT * FROM f.kana_text WHERE seq IN mat;
            INSERT INTO conjugation SELECT * FROM f.conjugation WHERE seq IN mat;
            INSERT INTO conj_prop SELECT p.* FROM f.conj_prop p JOIN f.conjugation c ON c.id = p.conj_id WHERE c.seq IN mat;
            INSERT INTO conj_source_reading SELECT r.* FROM f.conj_source_reading r JOIN f.conjugation c ON c.id = r.conj_id WHERE c.seq IN mat;
            """)
    }
}
