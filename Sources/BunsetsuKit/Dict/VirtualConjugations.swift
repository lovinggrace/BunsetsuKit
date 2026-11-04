// Conjugated forms computed at lookup time.
//
// ichiran stores every conjugated form of every word as a dictionary entry (about 95% of the
// database). A compact database (format "compact") stores only the dictionary entries, the
// conjugation rules, links from conjugations to existing entries, and the conjugations of a few
// words whose stored data cannot be reproduced by the generator ("materialized"). Everything else
// is generated here, replicating `conjugate-entry-outer` / `insert-conjugation` of dict-load.lisp.

import Foundation

/// A conjugated entry that only exists in memory.
///
/// Ids of generated readings and conjugations are negative and encode the entry and the position in it,
/// so no lookup tables are needed.
final class VirtualEntry {
    let seq: Int
    private(set) var kanjiTexts: [String] = []
    private(set) var kanaTexts: [String] = []
    private(set) var conjugateP = false
    var conjs: [ConjugationRow] = []
    var conjProps: [[ConjProp]] = []
    var conjSrc: [[(text: String, sourceText: String)]] = []
    /// reading sets, only needed while the conjugation group is generated
    private var textSets: (kanji: Set<TextKey>, kana: Set<TextKey>)? = nil

    init(seq: Int) { self.seq = seq }

    static let stride = 1024
    static let kanaBase = 256
    static let conjBase = 512

    static func id(_ seq: Int, _ local: Int) -> Int { -((seq - VirtualStore.seqBase) * stride + local) - 1 }

    /// (entry seq, position) of a generated id
    static func decode(_ id: Int) -> (seq: Int, local: Int) {
        let k = -id - 1
        return (VirtualStore.seqBase + k / stride, k % stride)
    }

    private func row(_ table: ReadingTable, _ i: Int) -> ReadingRow {
        let local = table == .kanji ? i : VirtualEntry.kanaBase + i
        return ReadingRow(table: table, id: VirtualEntry.id(seq, local), seq: seq, text: table == .kanji ? kanjiTexts[i] : kanaTexts[i],
                          ord: i, common: nil, commonTags: "", conjugateP: conjugateP, nokanji: false, best: nil)
    }

    var kanji: [ReadingRow] { kanjiTexts.indices.map { row(.kanji, $0) } }
    var kana: [ReadingRow] { kanaTexts.indices.map { row(.kana, $0) } }

    func readings(_ table: ReadingTable) -> [ReadingRow] { table == .kanji ? kanji : kana }

    func hasAll(_ texts: [String], _ table: ReadingTable) -> Bool {
        if textSets == nil { textSets = (Set(kanjiTexts.map(TextKey.init)), Set(kanaTexts.map(TextKey.init))) }
        let have = table == .kanji ? textSets!.kanji : textSets!.kana
        return texts.allSatisfy { have.contains(TextKey($0)) }
    }

    func releaseCaches() { textSets = nil }

    func conjIndex(_ conjId: Int) -> Int? {
        let local = VirtualEntry.decode(conjId).local - VirtualEntry.conjBase
        return local >= 0 && local < conjs.count ? local : nil
    }

    func props(_ conjId: Int) -> [ConjProp] { conjIndex(conjId).map { conjProps[$0] } ?? [] }
    func src(_ conjId: Int) -> [(text: String, sourceText: String)] { conjIndex(conjId).map { conjSrc[$0] } ?? [] }

    func reading(_ local: Int) -> ReadingRow? {
        if local < VirtualEntry.kanaBase { return local < kanjiTexts.count ? row(.kanji, local) : nil }
        let j = local - VirtualEntry.kanaBase
        return local < VirtualEntry.conjBase && j < kanaTexts.count ? row(.kana, j) : nil
    }

    /// Readings are added in order (ord = position) when the entry is created.
    func addReading(_ table: ReadingTable, _ text: String, conjugateP: Bool) {
        self.conjugateP = conjugateP
        if table == .kanji { kanjiTexts.append(text) } else { kanaTexts.append(text) }
    }

    /// The conjugation row from (from, via), created if needed; returns its index.
    func conjugation(from: Int, via: Int?) -> Int {
        if let i = conjs.firstIndex(where: { $0.from == from && $0.via == via }) { return i }
        conjs.append(ConjugationRow(id: VirtualEntry.id(seq, VirtualEntry.conjBase + conjs.count), seq: seq, from: from, via: via))
        conjProps.append([])
        conjSrc.append([])
        return conjs.count - 1
    }
}

/// A link from a conjugation to an entry stored in the database (used to verify compaction).
struct StoredLink {
    let target: Int
    let via: Int?
    var props: [ConjProp] = []
    var src: [(text: String, sourceText: String)] = []
}

/// Entries generated for a conjugation group, indexed by kana reading.
final class EntryPool {
    private(set) var entries: [VirtualEntry] = []
    private var byKana: [TextKey: [VirtualEntry]] = [:]

    func append(_ e: VirtualEntry) {
        entries.append(e)
        for t in e.kanaTexts { byKana[TextKey(t), default: []].append(e) }
    }

    /// Entries containing all the readings (in creation order).
    func candidates(kanji: [String], kana: [String]) -> [VirtualEntry] {
        (byKana[TextKey(kana[0])] ?? []).filter { e in
            kanji.isEmpty ? (e.kanji.isEmpty && e.hasAll(kana, .kana)) : (e.hasAll(kanji, .kanji) && e.hasAll(kana, .kana))
        }
    }
}

/// The generated conjugations of one dictionary entry.
final class GeneratedConjugations {
    var entries: [VirtualEntry] = []
    var storedLinks: [StoredLink] = []
}

/// In-memory registry of generated entries.
final class VirtualStore {
    static let seqBase = 1 << 40

    var nextSeq = VirtualStore.seqBase
    var entries: [Int: VirtualEntry] = [:]
    var generated: [Int: GeneratedConjugations] = [:]
    /// text -> ids of generated readings
    var textIndex: [TextKey: [Int]] = [:]
    var deinflected = Set<TextKey>()
    var posiCache: [Int: [String]?] = [:]
    var storedText: [TextKey: Bool] = [:]
    /// entries referenced by long-lived caches (the suffix cache) are never trimmed
    var pinned = Set<Int>()

    func reading(_ id: Int) -> ReadingRow? {
        let (seq, local) = VirtualEntry.decode(id)
        return entries[seq]?.reading(local)
    }

    func entry(conj id: Int) -> VirtualEntry? { entries[VirtualEntry.decode(id).seq] }

    /// A conjugation group and the entries generated for it (the unit of caching).
    final class Group {
        let froms: [Int]
        let entries: [VirtualEntry]
        var lastUse: Int

        init(froms: [Int], entries: [VirtualEntry], lastUse: Int) {
            self.froms = froms
            self.entries = entries
            self.lastUse = lastUse
        }
    }

    var groups: [Int: Group] = [:]
    var groupOf: [Int: Group] = [:]
    var entryCount = 0
    var tick = 0

    func register(_ entryList: [VirtualEntry], froms: [Int]) {
        tick += 1
        let g = Group(froms: froms, entries: entryList, lastUse: tick)
        groups[froms[0]] = g
        for e in entryList {
            entries[e.seq] = e
            groupOf[e.seq] = g
            e.releaseCaches()
            for r in e.kanji + e.kana { textIndex[TextKey(r.text), default: []].append(r.id) }
        }
        entryCount += entryList.count
    }

    func touch(_ ids: [Int]) {
        tick += 1
        for id in ids { groupOf[VirtualEntry.decode(id).seq]?.lastUse = tick }
    }

    /// Evicts the least recently used groups until at most `limit / 2` generated entries remain.
    /// Must only be called between top-level calls (generated seqs become invalid).
    func trim(limit: Int) {
        guard entryCount > limit else { return }
        let target = limit / 2
        for g in groups.values.sorted(by: { $0.lastUse < $1.lastUse }) {
            if entryCount <= target { break }
            if g.froms.contains(where: pinned.contains) { continue }
            groups[g.froms[0]] = nil
            for f in g.froms { generated[f] = nil }
            var texts = Set<TextKey>()
            for e in g.entries {
                entries[e.seq] = nil
                groupOf[e.seq] = nil
                for t in e.kanjiTexts + e.kanaTexts { texts.insert(TextKey(t)) }
            }
            let seqs = Set(g.entries.map(\.seq))
            for t in texts {
                textIndex[t]?.removeAll { seqs.contains(VirtualEntry.decode($0).seq) }
                if textIndex[t]?.isEmpty == true { textIndex[t] = nil }
            }
            entryCount -= g.entries.count
        }
        // texts may now need words that were evicted
        deinflected = []
        storedText = [:]
    }
}

struct DBMeta {
    static func value(_ db: SQLiteDB, _ key: String) -> String? {
        guard !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'meta'").isEmpty else { return nil }
        return db.single("SELECT value FROM meta WHERE key = ?", [key]).text
    }
}

extension Ichiran {

    func isVirtual(_ seq: Int) -> Bool { seq >= VirtualStore.seqBase }

    func virtualEntry(_ seq: Int) -> VirtualEntry? { vstore.entries[seq] }

    /// Loads the conjugation rules of a compact database.
    func loadConjugator() -> Conjugator {
        var posIndex: [String: Int] = [:]
        for r in db.query("SELECT id, pos FROM pos_index") { posIndex[r[1].text!] = r[0].int! }
        var rules: [Int: [ConjugationRule]] = [:]
        for r in db.query("SELECT pos_id, conj, neg, fml, onum, stem, okuri, euphr, euphk FROM conj_rule ORDER BY id") {
            let rule = ConjugationRule(pos: r[0].int!, conj: r[1].int!, neg: r[2].bool!, fml: r[3].bool!, onum: r[4].int!,
                                       stem: r[5].int!, okuri: r[6].text!, euphr: r[7].text!, euphk: r[8].text!)
            rules[rule.pos, default: []].append(rule)
        }
        let c = Conjugator(rules: rules, posIndex: posIndex)
        for r in db.query("SELECT pos_id, len, ending FROM pos_ending") {
            c.endings[r[0].int!, default: [:]][r[1].int!, default: []].insert(r[2].text!)
        }
        return c
    }

    // MARK: - Generation (conjugate-entry-outer / insert-conjugation)

    func conjSourcesOf(_ seq: Int) -> [ConjSource] {
        if let e = virtualEntry(seq) {
            return (e.kanji.map { ($0, true) } + e.kana.map { ($0, false) })
                .filter { $0.0.conjugateP }
                .map { ConjSource(text: $0.0.text, ord: $0.0.ord, kanji: $0.1) }
        }
        return db.query("""
            SELECT text, ord, 1 FROM kanji_text WHERE seq = ? AND conjugate_p
            UNION SELECT text, ord, 0 FROM kana_text WHERE seq = ? AND conjugate_p
            ORDER BY 3 DESC, 2
            """, [seq, seq]).map { ConjSource(text: $0[0].text!, ord: $0[1].int!, kanji: $0[2].int == 1) }
    }

    func allReadingTexts(_ seq: Int) -> Set<String> {
        if let e = virtualEntry(seq) { return Set((e.kanji + e.kana).map(\.text)) }
        return Set(db.column("SELECT text FROM kanji_text WHERE seq = ? UNION SELECT text FROM kana_text WHERE seq = ?", [seq, seq])
            .compactMap(\.text))
    }

    /// Stored (non-materialized) entries containing all the readings (`insert-conjugation` candidates).
    func storedCandidates(kanji: [String], kana: [String]) -> [Int] {
        // most conjugated forms are not readings of any stored entry: check one reading first
        func exists(_ table: ReadingTable, _ text: String) -> Bool {
            let key = TextKey(table.rawValue + "|" + text)
            if let e = vstore.storedText[key] { return e }
            if let bloom = textBloom, !bloom.mayContain(text) { return false }
            let e = !db.query("SELECT 1 FROM \(table.rawValue) WHERE text = ? LIMIT 1", [text]).isEmpty
            vstore.storedText[key] = e
            return e
        }
        guard exists(.kana, kana[0]), kanji.isEmpty || exists(.kanji, kanji[0]) else { return [] }
        if !kanji.isEmpty {
            return db.column("""
                SELECT k.seq FROM kanji_text k JOIN entry e ON e.seq = k.seq AND NOT e.materialized
                WHERE k.text IN \(placeholders(kanji.count)) GROUP BY k.seq HAVING COUNT(k.id) = ?
                INTERSECT
                SELECT r.seq FROM kana_text r JOIN entry e ON e.seq = r.seq AND NOT e.materialized
                WHERE r.text IN \(placeholders(kana.count)) GROUP BY r.seq HAVING COUNT(r.id) = ?
                """, kanji + [kanji.count as SQLBindable] + kana + [kana.count as SQLBindable]).compactMap(\.int).sorted()
        }
        return db.column("""
            SELECT r.seq FROM kana_text r JOIN entry e ON e.seq = r.seq AND NOT e.materialized
            LEFT JOIN kanji_text k ON r.seq = k.seq
            WHERE k.text IS NULL AND r.text IN \(placeholders(kana.count))
            GROUP BY r.seq HAVING COUNT(r.id) = ?
            """, kana + [kana.count as SQLBindable]).compactMap(\.int).sorted()
    }

    /// `insert-conjugation`. `pool` holds the entries generated so far (the conjugation group).
    private func insertVirtual(_ gen: GeneratedConjugations, _ pool: EntryPool, _ readings: [ConjItem], from: Int,
                               pos: String, conjType: Int, neg: Bool?, fml: Bool?, via: Int?) {
        let sorted = readings.enumerated().sorted {
            let a = [$0.element.ord, $0.element.onum], b = [$1.element.ord, $1.element.onum]
            return a != b ? a.lexicographicallyPrecedes(b) : $0.offset < $1.offset
        }.map(\.element)
        func dedupe(_ l: [String]) -> [String] { var s = Set<String>(); return l.filter { s.insert($0).inserted } }
        let kanjiReadings = dedupe(sorted.filter(\.kanjiFlag).map(\.text))
        let kanaReadings = dedupe(sorted.filter { !$0.kanjiFlag }.map(\.text))
        if kanaReadings.isEmpty { return }
        var sourceReadings: [(String, String)] = []
        var seen = Set<[String]>()
        for item in sorted where seen.insert([item.text, item.reading]).inserted {
            sourceReadings.append((item.text, item.reading))
        }

        let stored = storedCandidates(kanji: kanjiReadings, kana: kanaReadings)
        let virtual = pool.candidates(kanji: kanjiReadings, kana: kanaReadings)
        let candidates = stored + virtual.map(\.seq)
        if candidates.contains(from) || (via != nil && candidates.contains(via!)) { return }

        func addProp(_ props: inout [ConjProp], _ conjId: Int) {
            if !props.contains(where: { $0.conjType == conjType && $0.pos == pos && $0.neg == neg && $0.fml == fml }) {
                props.append(ConjProp(id: 0, conjId: conjId, conjType: conjType, pos: pos, neg: neg, fml: fml))
            }
        }
        func addSrc(_ src: inout [(text: String, sourceText: String)]) {
            for (t, s) in sourceReadings where !src.contains(where: { $0.text == t && $0.sourceText == s }) {
                src.append((t, s))
            }
        }

        if let target = stored.first {
            let i = gen.storedLinks.firstIndex { $0.target == target && $0.via == via } ?? {
                gen.storedLinks.append(StoredLink(target: target, via: via))
                return gen.storedLinks.count - 1
            }()
            addProp(&gen.storedLinks[i].props, 0)
            addSrc(&gen.storedLinks[i].src)
            return
        }

        let entry: VirtualEntry
        if let e = virtual.first {
            entry = e
        } else {
            entry = VirtualEntry(seq: vstore.nextSeq)
            vstore.nextSeq += 1
            let conjugateP = ConjugationConstants.secondaryConjugationTypesFrom.contains(conjType)
            for t in kanjiReadings { entry.addReading(.kanji, t, conjugateP: conjugateP) }
            for t in kanaReadings { entry.addReading(.kana, t, conjugateP: conjugateP) }
            pool.append(entry)
            vstore.entries[entry.seq] = entry
        }
        if !gen.entries.contains(where: { $0 === entry }) { gen.entries.append(entry) }
        let ci = entry.conjugation(from: from, via: via)
        addProp(&entry.conjProps[ci], entry.conjs[ci].id)
        addSrc(&entry.conjSrc[ci])
    }

    private func conjugateOuter(_ gen: GeneratedConjugations, _ pool: EntryPool, _ from: Int, via: Int?,
                                conjTypes: [Int]?, posi: [String]) {
        guard let conjugator else { return }
        let seq = via ?? from
        let matrix = conjugator.matrix(posi: posi, readings: conjSourcesOf(seq), conjTypes: conjTypes)
        let original = allReadingTexts(seq)
        for ((posId, conjId), m) in matrix {
            let ignoreNeg = m[2].isEmpty && m[3].isEmpty
            let ignoreFml = m[1].isEmpty && m[3].isEmpty
            let pos = conjugator.posByIndex[posId] ?? ""
            for ii in 0..<4 {
                let readings = m[ii].filter { !original.contains($0.text) }
                if readings.isEmpty { continue }
                insertVirtual(gen, pool, readings, from: from, pos: pos, conjType: conjId,
                              neg: ignoreNeg ? nil : ii >= 2, fml: ignoreFml ? nil : ii % 2 == 1, via: via)
            }
        }
    }

    /// Parts of speech of an entry if it is conjugated by the loader, nil otherwise
    func conjugatedPosi(_ seq: Int) -> [String]? {
        if let c = vstore.posiCache[seq] { return c }
        let r = conjugatedPosiUncached(seq)
        vstore.posiCache[seq] = r
        return r
    }

    private func conjugatedPosiUncached(_ seq: Int) -> [String]? {
        guard virtualMode, !isVirtual(seq), !materializedFrom.contains(seq),
              !ConjugationConstants.doNotConjugateSeq.contains(seq) else { return nil }
        let posi = db.column("SELECT DISTINCT text FROM sense_prop WHERE tag = 'pos' AND seq = ? ORDER BY text", [seq]).compactMap(\.text)
        return posi.contains(where: ConjugationConstants.posWithConjRules.contains) ? posi : nil
    }

    /// Words whose conjugated forms coincide with those of `seq` (the loader merges them into shared
    /// entries, so they are generated together). Recorded in `conj_group` when the database is compacted.
    func conjugationGroup(_ seq: Int) -> [Int] {
        let members = db.column("SELECT seq FROM conj_group WHERE grp = (SELECT grp FROM conj_group WHERE seq = ?) ORDER BY seq", [seq])
            .compactMap(\.int).filter { conjugatedPosi($0) != nil }
        return members.isEmpty ? [seq] : members
    }

    /// Generates all conjugated entries derived from the dictionary entry `seq`
    /// (`conjugate-entry-outer` followed by `load-secondary-conjugations`), together with its conjugation group.
    func generateConjugations(_ seq: Int) -> GeneratedConjugations {
        if let g = vstore.generated[seq] { return g }
        guard conjugatedPosi(seq) != nil else {
            let empty = GeneratedConjugations()
            vstore.generated[seq] = empty
            return empty
        }
        let group = conjugationGroup(seq).filter { vstore.generated[$0] == nil }
        var gens: [Int: GeneratedConjugations] = [:]
        for g in group {
            gens[g] = GeneratedConjugations()
            vstore.generated[g] = gens[g]
        }
        let pool = EntryPool()
        // load-conjugations: primary conjugations of all words first, in seq order
        for g in group {
            guard let posi = conjugatedPosi(g) else { continue }
            conjugateOuter(gens[g]!, pool, g, via: nil, conjTypes: nil, posi: posi)
        }
        // load-secondary-conjugations: (from, seq) pairs with their first qualifying conjugation type
        func qualifies(_ p: ConjProp) -> Bool {
            ConjugationConstants.secondaryConjugationTypesFrom.contains(p.conjType)
                && !["vs-i", "vs-s"].contains(p.pos) && p.neg != true && p.fml != true
        }
        for g in group {
            guard let gen = gens[g], conjugatedPosi(g) != nil else { continue }
            var targets: [(seq: Int, type: Int)] = []
            for r in db.query("""
                SELECT conj.seq, cp.conj_type, cp.pos, cp.neg, cp.fml FROM conjugation conj
                JOIN conj_prop cp ON conj.id = cp.conj_id JOIN entry e ON e.seq = conj.seq AND NOT e.materialized
                WHERE conj."from" = ? AND conj.via IS NULL ORDER BY conj.seq, cp.id
                """, [g]) {
                let p = ConjProp(id: 0, conjId: 0, conjType: r[1].int!, pos: r[2].text!, neg: r[3].bool, fml: r[4].bool)
                if qualifies(p), !targets.contains(where: { $0.seq == r[0].int! }) { targets.append((r[0].int!, p.conjType)) }
            }
            for e in gen.entries {
                for c in e.conjs where c.from == g && c.via == nil {
                    if let p = e.props(c.id).first(where: qualifies), !targets.contains(where: { $0.seq == e.seq }) {
                        targets.append((e.seq, p.conjType))
                    }
                }
            }
            targets.sort { $0.seq < $1.seq }
            for t in targets {
                conjugateOuter(gen, pool, g, via: t.seq, conjTypes: ConjugationConstants.secondaryConjugationTypes,
                               posi: [t.type == Conj.causativeSu ? "v5s" : "v1"])
            }
        }
        vstore.register(pool.entries, froms: group)
        return vstore.generated[seq]!
    }

    // MARK: - Lookup

    /// Dictionary entries that may have `text` as a conjugated form.
    func deinflectionCandidates(_ text: String) -> Set<Int> {
        guard let conjugator else { return [] }
        var bases = conjugator.baseCandidates(text)
        // secondary conjugations: conjugate potential/passive/causative forms again
        var intermediates = Set<String>()
        if let v1 = conjugator.posIndex["v1"], let v5s = conjugator.posIndex["v5s"] {
            for m in conjugator.baseCandidates(text, conjTypes: Set(ConjugationConstants.secondaryConjugationTypes), posIds: [v1, v5s]) {
                intermediates.insert(m.text)
                bases.formUnion(conjugator.baseCandidates(m.text, conjTypes: Set(ConjugationConstants.secondaryConjugationTypesFrom)))
            }
        }
        var posByText: [String: Set<String>] = [:]
        for b in bases { if let p = conjugator.posByIndex[b.posId] { posByText[b.text, default: []].insert(p) } }
        func lookup(_ all: [String]) -> [(Int, String)] {
            let texts = textBloom.map { b in all.filter(b.mayContain) } ?? all
            var r: [(Int, String)] = []
            for chunk in chunked(texts) {
                let p = placeholders(chunk.count)
                r += db.query("""
                    SELECT t.seq, t.text FROM kanji_text t JOIN entry e ON e.seq = t.seq AND NOT e.materialized
                    WHERE t.text IN \(p) AND t.conjugate_p
                    UNION SELECT t.seq, t.text FROM kana_text t JOIN entry e ON e.seq = t.seq AND NOT e.materialized
                    WHERE t.text IN \(p) AND t.conjugate_p
                    """, chunk + chunk).map { ($0[0].int!, $0[1].text!) }
            }
            return r
        }
        var seqs = Set<Int>()
        for (seq, base) in lookup(Array(posByText.keys)) {
            if let posi = conjugatedPosi(seq), !posByText[base, default: []].isDisjoint(with: posi) { seqs.insert(seq) }
        }
        // secondary conjugations of stored entries (conjugations linked to existing words)
        if !intermediates.isEmpty {
            for (target, _) in lookup(Array(intermediates)) {
                for f in db.column("SELECT DISTINCT \"from\" FROM conjugation WHERE seq = ?", [target]).compactMap(\.int) {
                    seqs.insert(f)
                }
            }
        }
        return seqs.subtracting(materializedFrom)
    }

    /// Generated readings with the given text.
    func virtualReadings(_ text: String) -> [ReadingRow] {
        guard virtualMode, text.len <= Ichiran.maxWordLength else { return [] }
        if vstore.deinflected.insert(TextKey(text)).inserted {
            for seq in deinflectionCandidates(text).sorted() {
                _ = generateConjugations(seq)
            }
        }
        let ids = vstore.textIndex[TextKey(text)] ?? []
        vstore.touch(ids)
        return ids.compactMap(vstore.reading)
    }

    /// Generated readings of a virtual entry.
    func virtualReadings(seq: Int, _ table: ReadingTable) -> [ReadingRow] {
        virtualEntry(seq)?.readings(table) ?? []
    }

    /// Generated entries derived from `from`.
    func virtualEntries(from: Int) -> [VirtualEntry] {
        guard virtualMode else { return [] }
        return generateConjugations(from).entries
    }

    func maybeTrimVirtual() {
        if virtualMode && vstore.entryCount > virtualCacheLimit {
            vstore.trim(limit: virtualCacheLimit)
            conjDataCache.removeAll()
        }
    }
}

/// A dictionary key for text that hashes and compares UTF-8 bytes (Swift's String hashing
/// normalizes Unicode, which is slow for Japanese and unnecessary here).
struct TextKey: Hashable {
    let text: String

    init(_ text: String) { self.text = text }

    func hash(into hasher: inout Hasher) {
        var t = text
        t.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }

    static func == (a: TextKey, b: TextKey) -> Bool { a.text.utf8.elementsEqual(b.text.utf8) }
}
