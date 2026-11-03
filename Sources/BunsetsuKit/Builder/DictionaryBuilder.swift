// Port of dict-load.lisp: building the dictionary database from JMdict

import Foundation

/// Builds a BunsetsuKit database (ichiran's `full-init`).
///
/// Needs:
/// - `JMdict_e` (uncompressed XML) from https://www.edrdg.org/jmdict/edict_doc.html
/// - the `data` directory of JMdictDB (https://gitlab.com/yamagoya/jmdictdb), for `kwpos.csv`, `conj.csv`, `conjo.csv`
/// - optionally `kanjidic2.xml` (needed for kana hints of some expressions and for kanji info)
public final class DictionaryBuilder {
    let db: SQLiteDB
    let ich: Ichiran
    let jmdictData: URL
    public var log: (String) -> Void = { print($0); fflush(stdout) }

    var posIndex: [String: Int] = [:]
    var posByIndex: [Int: String] = [:]
    var conjDescriptions: [Int: String] = [:]
    var conjRules: [Int: [ConjugationRule]] = [:]

    /// Creates (or overwrites) the database at `databasePath`.
    public init(databasePath: String, jmdictDataDirectory: URL) throws {
        if FileManager.default.fileExists(atPath: databasePath) {
            try FileManager.default.removeItem(atPath: databasePath)
        }
        db = try SQLiteDB(path: databasePath, create: true)
        db.exec("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA cache_size = -200000; PRAGMA temp_store = MEMORY;")
        ich = Ichiran(database: db)
        jmdictData = jmdictDataDirectory
    }

    /// `full-init`
    public func build(jmdict: URL, kanjidic: URL?) throws {
        try loadCSVs()
        db.exec(Schema.dictTables)
        db.exec(Schema.dictIndexes)
        db.exec("CREATE TABLE IF NOT EXISTS conj_description (id INTEGER PRIMARY KEY, description TEXT NOT NULL)")
        try db.transaction {
            for (id, d) in conjDescriptions { db.run("INSERT INTO conj_description (id, description) VALUES (?, ?)", [id, d]) }
        }
        log("Initializing ichiran/dict...")
        try loadJMdict(jmdict)
        log("Calculating readings...")
        db.transaction { loadBestReadings(reset: true) }
        if let kanjidic {
            log("Initializing ichiran/kanji...")
            db.exec(Schema.kanjiTables)
            try loadKanjidic(kanjidic)
            log("Calculating kanji stats...")
            db.transaction { loadKanjiStats() }
        }
        db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('version', ?)", [BunsetsuKitVersion])
        db.exec("ANALYZE")
        db.exec("VACUUM")
        log("Done.")
    }

    // MARK: - CSV data (csv-hash)

    struct ConjugationRule {
        var pos: Int
        var conj: Int
        var neg: Bool
        var fml: Bool
        var onum: Int
        var stem: Int
        var okuri: String
        var euphr: String
        var euphk: String
    }

    func readTSV(_ name: String) throws -> [[String]] {
        let url = jmdictData.appendingPathComponent(name)
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map { unquoteCSVField(String($0)) } }
    }

    func loadCSVs() throws {
        for row in try readTSV("kwpos.csv") where row.count >= 2 {
            guard let id = Int(row[0]) else { continue }
            posIndex[row[1]] = id
            posByIndex[id] = row[1]
        }
        for row in try readTSV("conj.csv") where row.count >= 2 {
            if let id = Int(row[0]) { conjDescriptions[id] = row[1] }
        }
        for (k, v) in Errata.conjDescriptionExtra { conjDescriptions[k] = v }
        for row in try readTSV("conjo.csv") where row.count >= 9 {
            guard let pos = Int(row[0]), let conj = Int(row[1]) else { continue }
            let rule = ConjugationRule(pos: pos, conj: conj, neg: row[2].hasPrefix("t"), fml: row[3].hasPrefix("t"),
                                       onum: Int(row[4]) ?? 1, stem: Int(row[5]) ?? 0,
                                       okuri: row[6], euphr: row[7], euphk: row[8])
            conjRules[pos, default: []].append(rule)
        }
        errataConjRulesHook()
    }

    /// `errata-conj-rules-hook`
    func errataConjRulesHook() {
        if let pos = posIndex["adj-i"] {
            conjRules[pos, default: []] += [
                ConjugationRule(pos: pos, conj: Conj.adverbial, neg: false, fml: false, onum: 1, stem: 1, okuri: "く", euphr: "", euphk: ""),
                ConjugationRule(pos: pos, conj: Conj.adjectiveStem, neg: false, fml: false, onum: 1, stem: 1, okuri: "", euphr: "", euphk: ""),
                ConjugationRule(pos: pos, conj: Conj.adjectiveLiterary, neg: false, fml: false, onum: 1, stem: 1, okuri: "き", euphr: "", euphk: ""),
            ]
        }
        if let pos = posIndex["adj-ix"] {
            conjRules[pos, default: []] += [
                ConjugationRule(pos: pos, conj: Conj.adverbial, neg: false, fml: false, onum: 1, stem: 1, okuri: "く", euphr: "よ", euphk: ""),
                ConjugationRule(pos: pos, conj: Conj.adjectiveStem, neg: false, fml: false, onum: 1, stem: 1, okuri: "", euphr: "よ", euphk: ""),
                ConjugationRule(pos: pos, conj: Conj.adjectiveLiterary, neg: false, fml: false, onum: 1, stem: 1, okuri: "き", euphr: "よ", euphk: ""),
            ]
        }
        if let pos = posIndex["v5aru"] {
            conjRules[pos, default: []].append(
                ConjugationRule(pos: pos, conj: 3, neg: false, fml: false, onum: 2, stem: 1, okuri: "り", euphr: "", euphk: ""))
        }
        // fix non-past negative formal for v1 v1-s
        for p in ["v1", "v1-s"] {
            guard let pos = posIndex[p] else { continue }
            for i in conjRules[pos, default: []].indices where conjRules[pos]![i].conj == 1 && conjRules[pos]![i].fml && conjRules[pos]![i].neg {
                conjRules[pos]![i].okuri = "ません"
            }
        }
        // fix incorrect negative conditional form of v5u verbs
        if let pos = posIndex["v5u"] {
            for i in conjRules[pos, default: []].indices where conjRules[pos]![i].conj == 11 && !conjRules[pos]![i].fml && conjRules[pos]![i].neg {
                conjRules[pos]![i].okuri = "わなかったら"
            }
        }
        // remove potential forms of vs-s verbs
        if let pos = posIndex["vs-s"] {
            conjRules[pos] = conjRules[pos]?.filter { $0.conj != 5 }
        }
        // add conj-negative-stem for godan verbs
        for key in Array(conjRules.keys) {
            var val = conjRules[key]!
            for i in val.indices where val[i].conj == 7 && val[i].onum == 2 {
                val[i].conj = Conj.causativeSu
                val[i].onum = 1
            }
            if let pos = posByIndex[key], pos.hasPrefix("v5"),
               let negRule = val.first(where: { $0.conj == 1 && $0.neg && !$0.fml }), negRule.okuri.len > 2 {
                var newRule = negRule
                newRule.conj = Conj.negativeStem
                newRule.okuri = negRule.okuri.sub(0, negRule.okuri.len - 2)
                val.append(newRule)
            }
            conjRules[key] = val
        }
    }

    // MARK: - Loading entries

    func nextSeq() -> Int { (db.single("SELECT MAX(seq) FROM entry").int ?? 0) + 1 }

    func insertReadings(_ nodes: [XNode], tag: String, table: ReadingTable, seq: Int, pri: String) {
        var toAdd: [(text: String, common: Int?, nokanji: Bool, tags: String)] = []
        var primaryNokanji = false
        for node in nodes {
            let readingText = node.first(tag)?.nodeText ?? ""
            if node.elements("re_inf").contains(where: { $0.nodeText == "ok" }) { continue }
            let nokanji = !node.elements("re_nokanji").isEmpty
            for restr in node.elements("re_restr") {
                db.run("INSERT INTO restricted_readings (seq, reading, text) VALUES (?, ?, ?)", [seq, readingText, restr.nodeText])
            }
            var common: Int? = nil
            var priTags: [String] = []
            for p in node.elements(pri) {
                let t = p.nodeText
                priTags.append(t)
                if common == nil { common = 0 }
                if t.hasPrefix("nf"), let n = Int(t.dropFirst(2)) { common = n }
            }
            toAdd.append((readingText, common, nokanji, priTags.map { "[\($0)]" }.joined()))
        }
        for (ord, r) in toAdd.enumerated() {
            if r.nokanji { primaryNokanji = true }
            db.run("INSERT INTO \(table.rawValue) (seq, text, ord, common, common_tags, conjugate_p, nokanji) VALUES (?, ?, ?, ?, ?, 1, ?)",
                   [seq, r.text, ord, r.common, r.tags, r.nokanji])
        }
        db.run("UPDATE entry SET primary_nokanji = ?, \(table == .kana ? "n_kana" : "n_kanji") = ? WHERE seq = ?",
               [primaryNokanji, toAdd.count, seq])
    }

    func insertSenses(_ nodes: [XNode], seq: Int) {
        for (ord, node) in nodes.enumerated() {
            db.run("INSERT INTO sense (seq, ord) VALUES (?, ?)", [seq, ord])
            let senseId = db.lastInsertRowID
            for (gord, g) in node.elements("gloss").enumerated() {
                db.run("INSERT INTO gloss (sense_id, text, ord) VALUES (?, ?, ?)", [senseId, g.nodeText, gord])
            }
            for tag in ["pos", "misc", "dial", "field", "s_inf", "stagk", "stagr"] {
                for (pord, p) in node.elements(tag).enumerated() {
                    db.run("INSERT INTO sense_prop (sense_id, tag, text, ord, seq) VALUES (?, ?, ?, ?, ?)",
                           [senseId, tag, p.nodeText, pord, seq])
                }
            }
        }
    }

    enum IfExists { case none, skip, overwrite }

    /// `load-entry`
    @discardableResult
    func loadEntry(_ entry: XNode, seq seqArg: Int? = nil, seqText: String? = nil, ifExists: IfExists = .none,
                   conjugateP: Bool = false) -> Int? {
        let seq: Int
        if let seqText {
            // if reading exists use its seq, otherwise choose next available seq
            seq = ich.findWord(seqText).first?.seq ?? nextSeq()
        } else if let seqArg {
            seq = seqArg
        } else {
            guard let s = entry.first("ent_seq").flatMap({ Int($0.nodeText.trimmingCharacters(in: .whitespaces)) }) else { return nil }
            seq = s
        }
        let exists = !db.query("SELECT seq FROM entry WHERE seq = ?", [seq]).isEmpty
        switch ifExists {
        case .skip: if exists { return nil }
        case .overwrite: if exists { deleteEntry(seq) }
        case .none: break
        }
        db.run("INSERT INTO entry (seq, content, root_p) VALUES (?, '', 1)", [seq])
        insertReadings(entry.elements("k_ele"), tag: "keb", table: .kanji, seq: seq, pri: "ke_pri")
        insertReadings(entry.elements("r_ele"), tag: "reb", table: .kana, seq: seq, pri: "re_pri")
        insertSenses(entry.elements("sense"), seq: seq)
        if conjugateP {
            let posi = db.column("SELECT DISTINCT text FROM sense_prop WHERE seq = ? AND tag = 'pos' ORDER BY text", [seq])
                .compactMap(\.text).filter(posWithConjRules.contains)
            if !posi.isEmpty {
                conjugateEntryOuter(seq, asPosi: posi)
                loadSecondaryConjugations(from: [seq])
            }
        }
        return seq
    }

    func deleteEntry(_ seq: Int) {
        let conjIds = db.column("SELECT id FROM conjugation WHERE seq = ? OR \"from\" = ?", [seq, seq]).compactMap(\.int)
        for chunk in chunked(conjIds) {
            let p = placeholders(chunk.count)
            db.run("DELETE FROM conj_prop WHERE conj_id IN \(p)", chunk)
            db.run("DELETE FROM conj_source_reading WHERE conj_id IN \(p)", chunk)
            db.run("DELETE FROM conjugation WHERE id IN \(p)", chunk)
        }
        let senseIds = db.column("SELECT id FROM sense WHERE seq = ?", [seq]).compactMap(\.int)
        for chunk in chunked(senseIds) {
            let p = placeholders(chunk.count)
            db.run("DELETE FROM gloss WHERE sense_id IN \(p)", chunk)
        }
        for t in ["sense_prop", "sense", "kanji_text", "kana_text", "restricted_readings", "entry"] {
            db.run("DELETE FROM \(t) WHERE seq = ?", [seq])
        }
    }

    /// `load-jmdict`
    func loadJMdict(_ url: URL) throws {
        let data = preprocessJMdict(try Data(contentsOf: url))
        var cnt = 0
        try db.transaction {
            let reader = StreamingXMLReader(target: "entry") { entry in
                self.loadEntry(entry)
                cnt += 1
                if cnt % 10000 == 0 { self.log("\(cnt) entries loaded") }
            }
            try reader.parse(data)
        }
        log("\(cnt) entries total")
        recalcEntryStatsAll()
        db.exec("ANALYZE")
        try loadExtras()
    }

    func loadExtras() throws {
        log("Loading conjugations...")
        db.transaction { loadConjugations() }
        log("Loading secondary conjugations...")
        db.transaction { loadSecondaryConjugations() }
        log("Loading custom data...")
        try db.transaction { try loadCustomData(nil) }
        log("Adding errata...")
        ich.resetCaches()
        db.transaction { addErrata() }
        recalcEntryStatsAll()
        db.exec("ANALYZE")
    }

    func recalcEntryStatsAll() {
        db.run("""
            UPDATE entry SET n_kanji = (SELECT COUNT(id) FROM kanji_text WHERE kanji_text.seq = entry.seq),
                             n_kana = (SELECT COUNT(id) FROM kana_text WHERE kana_text.seq = entry.seq)
            """)
    }

    func recalcEntryStats(_ seqs: [Int]) {
        for chunk in chunked(seqs) {
            db.run("""
                UPDATE entry SET n_kanji = (SELECT COUNT(id) FROM kanji_text WHERE kanji_text.seq = entry.seq),
                                 n_kana = (SELECT COUNT(id) FROM kana_text WHERE kana_text.seq = entry.seq)
                WHERE seq IN \(placeholders(chunk.count))
                """, chunk)
        }
    }

    // MARK: - Conjugations ("warning: terrible code ahead")

    let doNotConjugate: Set<String> = ["n", "vs", "adj-na"]
    let doNotConjugateSeq: [Int] = [2765070, 2835284]
    let posWithConjRules: Set<String> = ["adj-i", "adj-ix", "cop-da", "v1", "v1-s", "v5aru",
                                         "v5b", "v5g", "v5k", "v5k-s", "v5m", "v5n", "v5r", "v5r-i", "v5s",
                                         "v5t", "v5u", "v5u-s", "vk", "vs-s", "vs-i"]
    let secondaryConjugationTypesFrom: [Int] = [5, 6, 7, 8, Conj.causativeSu]
    let secondaryConjugationTypes: [Int] = [2, 3, 4, 9, 10, 11, 12, 13]

    func constructConjugation(_ word: String, _ rule: ConjugationRule) -> String {
        let iskana = testWord(word.sub(max(0, word.len - 2)), .kana)
        let stem = rule.stem + ((iskana && !rule.euphr.isEmpty) || (!iskana && !rule.euphk.isEmpty) ? 1 : 0)
        return word.sub(0, max(0, word.len - stem)) + (iskana ? rule.euphr : rule.euphk) + rule.okuri
    }

    struct ConjItem {
        let text: String
        let kanjiFlag: Bool
        let reading: String
        let ord: Int
        let onum: Int
    }

    /// `conjugate-entry-inner`: (pos-id, conj-id) -> 2x2 matrix [neg][fml] in insertion order
    func conjugateEntryInner(_ seq: Int, conjTypes: [Int]? = nil, asPosi: [String]? = nil) -> [((Int, Int), [[ConjItem]])] {
        let posi = asPosi ?? db.column("SELECT DISTINCT text FROM sense_prop WHERE tag = 'pos' AND seq = ? ORDER BY text", [seq]).compactMap(\.text)
        var order: [(Int, Int)] = []
        var matrix: [[Int]: [[ConjItem]]] = [:]
        let readings = db.query("""
            SELECT text, ord, 1 FROM kanji_text WHERE seq = ? AND conjugate_p
            UNION SELECT text, ord, 0 FROM kana_text WHERE seq = ? AND conjugate_p
            ORDER BY 3 DESC, 2
            """, [seq, seq])
        for pos in posi {
            guard let posId = posIndex[pos], let rules = conjRules[posId], !rules.isEmpty, !doNotConjugate.contains(pos) else { continue }
            for r in readings {
                let reading = r[0].text!, ord = r[1].int!, kanjiFlag = r[2].int == 1
                for rule in rules where conjTypes == nil || conjTypes!.contains(rule.conj) {
                    let key = [posId, rule.conj]
                    if matrix[key] == nil {
                        matrix[key] = Array(repeating: [], count: 4)
                        order.append((posId, rule.conj))
                    }
                    let item = ConjItem(text: constructConjugation(reading, rule), kanjiFlag: kanjiFlag, reading: reading, ord: ord, onum: rule.onum)
                    matrix[key]![(rule.neg ? 2 : 0) + (rule.fml ? 1 : 0)].insert(item, at: 0)
                }
            }
        }
        return order.map { ($0, matrix[[$0.0, $0.1]]!) }
    }

    func getAllReadings(_ seq: Int) -> [String] {
        db.column("SELECT text FROM kanji_text WHERE seq = ? UNION SELECT text FROM kana_text WHERE seq = ?", [seq, seq]).compactMap(\.text)
    }

    /// `conjugate-entry-outer`
    func conjugateEntryOuter(_ seqStar: Int, via: Int? = nil, conjTypes: [Int]? = nil, asPosi: [String]? = nil) {
        let seq = via ?? seqStar
        let conjMatrix = conjugateEntryInner(seq, conjTypes: conjTypes, asPosi: asPosi)
        let originalReadings = Set(getAllReadings(seq))
        var next = nextSeq()
        for ((posId, conjId), matrix) in conjMatrix {
            let ignoreNeg = matrix[2].isEmpty && matrix[3].isEmpty
            let ignoreFml = matrix[1].isEmpty && matrix[3].isEmpty
            let pos = posByIndex[posId] ?? ""
            for ii in 0..<4 {
                let neg = ii >= 2, fml = ii % 2 == 1
                let readings = matrix[ii].filter { !originalReadings.contains($0.text) }
                if readings.isEmpty { continue }
                if insertConjugation(readings, seq: next, from: seqStar, pos: pos, conjType: conjId,
                                     neg: ignoreNeg ? nil : neg, fml: ignoreFml ? nil : fml, via: via) {
                    next += 1
                }
            }
        }
    }

    /// `insert-conjugation`: returns true if a new entry is created
    func insertConjugation(_ readings: [ConjItem], seq seqArg: Int, from: Int, pos: String, conjType: Int,
                           neg: Bool?, fml: Bool?, via: Int?) -> Bool {
        let sorted = readings.enumerated().sorted {
            let a = [$0.element.ord, $0.element.onum], b = [$1.element.ord, $1.element.onum]
            return a != b ? a.lexicographicallyPrecedes(b) : $0.offset < $1.offset
        }.map(\.element)
        let sourceReadings = sorted.map { ($0.text, $0.reading) }
        func dedupe(_ l: [String]) -> [String] { var s = Set<String>(); return l.filter { s.insert($0).inserted } }
        let kanjiReadings = dedupe(sorted.filter(\.kanjiFlag).map(\.text))
        let kanaReadings = dedupe(sorted.filter { !$0.kanjiFlag }.map(\.text))
        if kanaReadings.isEmpty { return false }
        var candidates: [Int]
        if !kanjiReadings.isEmpty {
            candidates = db.column("""
                SELECT seq FROM kanji_text WHERE text IN \(placeholders(kanjiReadings.count)) GROUP BY seq HAVING COUNT(id) = ?
                INTERSECT
                SELECT seq FROM kana_text WHERE text IN \(placeholders(kanaReadings.count)) GROUP BY seq HAVING COUNT(id) = ?
                """, kanjiReadings + [kanjiReadings.count as SQLBindable] + kanaReadings + [kanaReadings.count as SQLBindable]).compactMap(\.int)
        } else {
            candidates = db.column("""
                SELECT r.seq FROM kana_text r LEFT JOIN kanji_text k ON r.seq = k.seq
                WHERE k.text IS NULL AND r.text IN \(placeholders(kanaReadings.count))
                GROUP BY r.seq HAVING COUNT(r.id) = ?
                """, kanaReadings + [kanaReadings.count as SQLBindable]).compactMap(\.int)
        }
        candidates.sort()
        if candidates.contains(from) || (via != nil && candidates.contains(via!)) { return false }
        let seq: Int
        if let c = candidates.first {
            seq = c
        } else {
            seq = seqArg
            db.run("INSERT INTO entry (seq, content, root_p) VALUES (?, '', 0)", [seq])
            let conjugateP = secondaryConjugationTypesFrom.contains(conjType)
            for (ord, kr) in kanjiReadings.enumerated() {
                db.run("INSERT INTO kanji_text (seq, text, ord, common, conjugate_p) VALUES (?, ?, ?, NULL, ?)", [seq, kr, ord, conjugateP])
            }
            for (ord, kr) in kanaReadings.enumerated() {
                db.run("INSERT INTO kana_text (seq, text, ord, common, conjugate_p) VALUES (?, ?, ?, NULL, ?)", [seq, kr, ord, conjugateP])
            }
        }
        let oldConj = db.column("SELECT id FROM conjugation WHERE \"from\" = ? AND seq = ? AND via IS ? ORDER BY id", [from, seq, via]).compactMap(\.int)
        let conjId: Int
        if let c = oldConj.first {
            conjId = c
        } else {
            db.run("INSERT INTO conjugation (seq, \"from\", via) VALUES (?, ?, ?)", [seq, from, via])
            conjId = db.lastInsertRowID
        }
        if db.query("SELECT id FROM conj_prop WHERE conj_id = ? AND conj_type = ? AND pos = ? AND neg IS ? AND fml IS ?",
                    [conjId, conjType, pos, neg, fml]).isEmpty {
            db.run("INSERT INTO conj_prop (conj_id, conj_type, pos, neg, fml) VALUES (?, ?, ?, ?, ?)", [conjId, conjType, pos, neg, fml])
        }
        var old = Set<[String]>()
        if !oldConj.isEmpty {
            for r in db.query("SELECT text, source_text FROM conj_source_reading WHERE conj_id = ?", [conjId]) {
                old.insert([r[0].text!, r[1].text!])
            }
        }
        var seen = Set<[String]>()
        for (text, src) in sourceReadings where !old.contains([text, src]) && seen.insert([text, src]).inserted {
            if db.query("SELECT id FROM conj_source_reading WHERE conj_id = ? AND text = ? AND source_text = ?", [conjId, text, src]).isEmpty {
                db.run("INSERT INTO conj_source_reading (conj_id, text, source_text) VALUES (?, ?, ?)", [conjId, text, src])
            }
        }
        return candidates.isEmpty
    }

    /// `load-conjugations`
    func loadConjugations() {
        let seqs = db.column("""
            SELECT DISTINCT seq FROM sense_prop WHERE seq NOT IN \(placeholders(doNotConjugateSeq.count))
            AND tag = 'pos' AND text IN \(placeholders(posWithConjRules.count)) ORDER BY seq
            """, doNotConjugateSeq.map { $0 as SQLBindable } + posWithConjRules.sorted().map { $0 as SQLBindable }).compactMap(\.int)
        for (cnt, seq) in seqs.enumerated() {
            conjugateEntryOuter(seq)
            if (cnt + 1) % 5000 == 0 { log("\(cnt + 1) entries processed") }
        }
    }

    /// `load-secondary-conjugations`
    func loadSecondaryConjugations(from: [Int]? = nil) {
        var cond = ""
        var params: [SQLBindable] = []
        if let from {
            cond = "conj.\"from\" IN \(placeholders(from.count)) AND "
            params += from.map { $0 as SQLBindable }
        }
        params += secondaryConjugationTypesFrom.map { $0 as SQLBindable }
        let rows = db.query("""
            SELECT conj."from", conj.seq, cp.conj_type FROM conjugation conj
            LEFT JOIN conj_prop cp ON conj.id = cp.conj_id
            WHERE \(cond) cp.conj_type IN \(placeholders(secondaryConjugationTypesFrom.count))
              AND cp.pos NOT IN ('vs-i', 'vs-s') AND conj.via IS NULL
              AND (NOT cp.neg OR cp.neg IS NULL) AND (NOT cp.fml OR cp.fml IS NULL)
            ORDER BY conj."from", conj.seq, cp.id
            """, params)
        var seen = Set<[Int]>()
        var cnt = 0
        for r in rows {
            let seqFrom = r[0].int!, seq = r[1].int!, conjType = r[2].int!
            guard seen.insert([seqFrom, seq]).inserted else { continue }
            conjugateEntryOuter(seqFrom, via: seq, conjTypes: secondaryConjugationTypes,
                                asPosi: [conjType == Conj.causativeSu ? "v5s" : "v1"])
            cnt += 1
            if cnt % 10000 == 0 { log("\(cnt) entries processed") }
        }
    }

    // MARK: - Best readings

    /// `set-reading` for a kanji_text row
    func setReadingKanji(id: Int, seq: Int, text: String, curBest: String?) {
        let restricted = db.query("SELECT reading, text FROM restricted_readings WHERE seq = ?", [seq]).map { ($0[0].text!, $0[1].text!) }
        for r in db.query("SELECT text, nokanji FROM kana_text WHERE seq = ? ORDER BY ord, id", [seq]) {
            let rtext = r[0].text!
            let restr = restricted.filter { $0.0 == rtext }.map(\.1)
            if r[1].bool != true && (restr.isEmpty || restr.contains(text)) {
                if curBest != rtext { db.run("UPDATE kanji_text SET best_kana = ? WHERE id = ?", [rtext, id]) }
                return
            }
        }
        if curBest != nil { db.run("UPDATE kanji_text SET best_kana = NULL WHERE id = ?", [id]) }
    }

    /// `set-reading` for a kana_text row
    func setReadingKana(id: Int, seq: Int, text: String, nokanji: Bool, curBest: String?) {
        if nokanji { return }
        let restricted = db.column("SELECT text FROM restricted_readings WHERE seq = ? AND reading = ?", [seq, text]).compactMap(\.text)
        let kanjiList: [String]
        if restricted.isEmpty {
            kanjiList = db.column("SELECT text FROM kanji_text WHERE seq = ? ORDER BY ord, id", [seq]).compactMap(\.text)
        } else {
            kanjiList = db.column("SELECT text FROM kanji_text WHERE seq = ? AND text IN \(placeholders(restricted.count)) ORDER BY ord, id",
                                  [seq] + restricted.map { $0 as SQLBindable }).compactMap(\.text)
        }
        if let k = kanjiList.first {
            if curBest != k { db.run("UPDATE kana_text SET best_kanji = ? WHERE id = ?", [k, id]) }
        } else if curBest != nil {
            db.run("UPDATE kana_text SET best_kanji = NULL WHERE id = ?", [id])
        }
    }

    func setReading(_ table: ReadingTable, where cond: String, _ params: [SQLBindable]) {
        for r in db.query("SELECT id, seq, text, nokanji, \(table.bestColumn) FROM \(table.rawValue) WHERE \(cond)", params) {
            if table == .kanji {
                setReadingKanji(id: r[0].int!, seq: r[1].int!, text: r[2].text!, curBest: r[4].text)
            } else {
                setReadingKana(id: r[0].int!, seq: r[1].int!, text: r[2].text!, nokanji: r[3].bool ?? false, curBest: r[4].text)
            }
        }
    }

    /// `load-best-readings`
    func loadBestReadings(reset: Bool = false) {
        if reset {
            db.run("UPDATE kanji_text SET best_kana = NULL")
            db.run("UPDATE kana_text SET best_kanji = NULL")
        }
        setReading(.kanji, where: "best_kana IS NULL AND seq IN (SELECT seq FROM entry WHERE root_p)", [])
        setReading(.kana, where: "best_kanji IS NULL AND seq IN (SELECT seq FROM entry WHERE root_p)", [])
    }
}

public let BunsetsuKitVersion = "0.1.0"

/// Removes CSV quoting ("" is an empty field, "a""b" is a"b).
func unquoteCSVField(_ f: String) -> String {
    guard f.count >= 2, f.hasPrefix("\""), f.hasSuffix("\"") else { return f }
    return String(f.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
}
