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
    let group: VirtualStore.Group
    private var byKana: [TextKey: [VirtualEntry]] = [:]

    init(_ group: VirtualStore.Group) { self.group = group }

    var entries: [VirtualEntry] { group.entries }

    /// The seq of the next entry: generation is deterministic, so an entry gets the same seq
    /// (and its readings and conjugations the same ids) every time its group is generated.
    var nextSeq: Int { VirtualStore.firstSeq(group: group.key) + group.entries.count }

    func append(_ e: VirtualEntry) {
        group.entries.append(e)
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
///
/// Entries are generated per conjugation group (a word and the words sharing conjugated forms with
/// it) and kept in a packed form; an entry is only turned into an object when its conjugation data
/// is needed. The least recently used groups are removed when memory is needed. Seqs and ids of
/// generated entries are derived from the group and the position in it, so they stay valid when a
/// group is generated again.
final class VirtualStore {
    static let seqBase = 1 << 40
    /// maximum number of entries of a group
    static let groupStride = 1 << 20
    static func firstSeq(group key: Int) -> Int { seqBase + key * groupStride }
    static func groupKey(_ seq: Int) -> Int { (seq - seqBase) / groupStride }

    /// A conjugation group and the entries generated for it (the unit of caching).
    final class Group {
        let key: Int
        let froms: [Int]
        var firstSeq: Int { VirtualStore.firstSeq(group: key) }
        /// the entries as objects, only while the group is generated
        var entries: [VirtualEntry] = []
        var generating = false
        var lastUse = 0

        // packed entries: a record of 32-bit words per entry
        //   counts: kanji readings (8 bits), kana readings (8), conjugations (15), conjugate_p (1)
        //   first string (the readings are consecutive strings, kanji first)
        //   per conjugation: from, via (0: none, high bit set: position in the group), counts: props (16 bits), source readings (16),
        //     props: conjugation type (8 bits), pos (8), neg (2), fml (2)
        //     source readings: number of the reading (8 bits), string of the source text (24)
        private var words: [UInt32] = []
        private var offsets: [UInt32] = []
        /// UTF-16 (shorter than UTF-8 for Japanese)
        private var stringUnits: [UInt16] = []
        private var stringOffsets: [UInt32] = [0]
        /// readings sorted by text hash: hash (32 bits), position of the entry (22), number of the reading (10)
        private var index: [UInt64] = []
        /// dictionary entry -> positions of the entries conjugated from it, in generation order
        private(set) var fromLists: [Int: [Int]] = [:]
        /// entries turned into objects (kept until the end of the top-level call)
        var unpacked: [Int: VirtualEntry] = [:]

        init(key: Int, froms: [Int]) {
            self.key = key
            self.froms = froms
        }

        var count: Int { generating ? entries.count : offsets.count }

        /// Packs the generated entries and releases the objects.
        func pack(fromLists: [Int: [Int]], posIndex: [String: Int]) {
            var words: [UInt32] = [], offsets: [UInt32] = [], units: [UInt16] = [], stringOffsets: [UInt32] = [0], index: [UInt64] = []
            words.reserveCapacity(entries.count * 12)
            units.reserveCapacity(entries.count * 40)
            index.reserveCapacity(entries.count * 4)
            func add(_ s: String) -> UInt32 {
                units.append(contentsOf: s.utf16)
                stringOffsets.append(UInt32(units.count))
                return UInt32(stringOffsets.count - 2)
            }
            // source readings are readings of few entries
            var sources: [TextKey: UInt32] = [:]
            var lastSource: (text: String, index: UInt32)? = nil
            func source(_ s: String) -> UInt32 {
                if let last = lastSource, sameText(last.text, s) { return last.index }
                let k = TextKey(s)
                let i = sources[k] ?? add(s)
                sources[k] = i
                lastSource = (s, i)
                return i
            }
            func flag(_ b: Bool?) -> UInt32 { b == nil ? 0 : (b! ? 2 : 1) }
            let first = firstSeq
            for (position, e) in entries.enumerated() {
                offsets.append(UInt32(words.count))
                words.append(UInt32(e.kanjiTexts.count) | UInt32(e.kanaTexts.count) << 8 | UInt32(e.conjs.count) << 16
                    | (e.conjugateP ? 1 << 31 : 0))
                words.append(UInt32(stringOffsets.count - 1))
                for (i, t) in e.kanjiTexts.enumerated() {
                    _ = add(t)
                    index.append(UInt64(textHash(t) & 0xffff_ffff) << 32 | UInt64(position) << 10 | UInt64(i))
                }
                for (i, t) in e.kanaTexts.enumerated() {
                    _ = add(t)
                    index.append(UInt64(textHash(t) & 0xffff_ffff) << 32 | UInt64(position) << 10 | UInt64(VirtualEntry.kanaBase + i))
                }
                for (ci, c) in e.conjs.enumerated() {
                    words.append(UInt32(c.from))
                    if let via = c.via {
                        words.append(via >= VirtualStore.seqBase ? 0x8000_0000 | UInt32(via - first) : UInt32(via))
                    } else {
                        words.append(0)
                    }
                    let props = e.conjProps[ci], src = e.conjSrc[ci]
                    words.append(UInt32(props.count) | UInt32(src.count) << 16)
                    for p in props {
                        words.append(UInt32(p.conjType) | UInt32(posIndex[p.pos] ?? 0) << 8 | flag(p.neg) << 16 | flag(p.fml) << 18)
                    }
                    for (t, sourceText) in src {
                        // the text is one of the readings of the entry
                        let reading = e.kanjiTexts.firstIndex { sameText($0, t) }
                            ?? e.kanaTexts.firstIndex { sameText($0, t) }.map { e.kanjiTexts.count + $0 } ?? 0
                        words.append(UInt32(reading) | source(sourceText) << 8)
                    }
                }
            }
            // generation order within a hash
            index.sort()
            // copies without spare capacity
            func exact<T>(_ a: [T]) -> [T] {
                var r: [T] = []
                r.reserveCapacity(a.count)
                r.append(contentsOf: a)
                return r
            }
            self.words = exact(words)
            self.offsets = exact(offsets)
            self.stringUnits = exact(units)
            self.stringOffsets = exact(stringOffsets)
            self.index = exact(index)
            self.fromLists = fromLists
            entries = []
            unpacked = [:]
            generating = false
        }

        private func string(_ i: UInt32) -> String {
            String(decoding: stringUnits[Int(stringOffsets[Int(i)])..<Int(stringOffsets[Int(i) + 1])], as: UTF16.self)
        }

        private func string(_ i: UInt32, equals text: [UInt16]) -> Bool {
            let start = Int(stringOffsets[Int(i)]), end = Int(stringOffsets[Int(i) + 1])
            guard end - start == text.count else { return false }
            for j in 0..<text.count where stringUnits[start + j] != text[j] { return false }
            return true
        }

        /// The entry as an object (nil if the group does not have it).
        func entry(_ seq: Int, posByIndex: [Int: String]) -> (entry: VirtualEntry, new: Bool)? {
            let position = seq - firstSeq
            if generating { return position >= 0 && position < entries.count ? (entries[position], false) : nil }
            if let e = unpacked[seq] { return (e, false) }
            guard position >= 0, position < offsets.count else { return nil }
            let e = unpack(position, posByIndex: posByIndex)
            unpacked[seq] = e
            return (e, true)
        }

        func unpack(_ position: Int, posByIndex: [Int: String]) -> VirtualEntry {
            func flag(_ v: UInt32) -> Bool? { v == 0 ? nil : v == 2 }
            let e = VirtualEntry(seq: firstSeq + position)
            var i = Int(offsets[position])
            let counts = words[i], firstString = words[i + 1]
            i += 2
            let conjugateP = counts >> 31 == 1
            let nKanji = counts & 0xff, nKana = counts >> 8 & 0xff
            let texts = (0..<(nKanji + nKana)).map { string(firstString + $0) }
            for t in texts.prefix(Int(nKanji)) { e.addReading(.kanji, t, conjugateP: conjugateP) }
            for t in texts.suffix(Int(nKana)) { e.addReading(.kana, t, conjugateP: conjugateP) }
            var sources: [UInt32: String] = [:]
            for _ in 0..<Int(counts >> 16 & 0x7fff) {
                let from = Int(words[i]), via = words[i + 1], n = words[i + 2]
                i += 3
                let ci = e.conjugation(from: from, via: via == 0 ? nil : (via >> 31 == 1 ? firstSeq + Int(via & 0x7fff_ffff) : Int(via)))
                let conjId = e.conjs[ci].id
                for _ in 0..<Int(n & 0xffff) {
                    let p = words[i]
                    i += 1
                    e.conjProps[ci].append(ConjProp(id: 0, conjId: conjId, conjType: Int(p & 0xff), pos: posByIndex[Int(p >> 8 & 0xff)] ?? "",
                                                    neg: flag(p >> 16 & 3), fml: flag(p >> 18 & 3)))
                }
                for _ in 0..<Int(n >> 16) {
                    let w = words[i]
                    i += 1
                    let source = sources[w >> 8] ?? string(w >> 8)
                    sources[w >> 8] = source
                    e.conjSrc[ci].append((texts[Int(w & 0xff)], source))
                }
            }
            return e
        }

        /// Readings with the given text, in generation order (with the position of their entry).
        func readings(_ text: String, hash: UInt64, units: [UInt16], _ body: (ReadingRow, Int) -> Void) {
            let h = (hash & 0xffff_ffff) << 32
            var lo = 0, hi = index.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if index[mid] < h { lo = mid + 1 } else { hi = mid }
            }
            while lo < index.count, index[lo] & ~0xffff_ffff == h {
                let position = Int(index[lo] >> 10 & 0x3f_ffff), local = Int(index[lo] & 0x3ff)
                lo += 1
                let offset = Int(offsets[position])
                let counts = words[offset]
                let kanji = local < VirtualEntry.kanaBase
                let ord = kanji ? local : local - VirtualEntry.kanaBase
                guard string(words[offset + 1] + UInt32(kanji ? ord : Int(counts & 0xff) + ord), equals: units) else { continue }
                let seq = firstSeq + position
                body(ReadingRow(table: kanji ? .kanji : .kana, id: VirtualEntry.id(seq, local), seq: seq, text: text, ord: ord, common: nil,
                                commonTags: "", conjugateP: counts >> 31 == 1, nokanji: false, best: nil), position)
            }
        }
    }

    var groups: [Int: Group] = [:]
    /// text -> the groups with generated readings of it
    var resolved: [TextKey: [Int]] = [:]
    /// texts that are not a conjugated form of any word
    var noForms = Set<TextKey>()
    var posiCache: [Int: [String]?] = [:]
    var storedText: [TextKey: Bool] = [:]
    /// entries referenced by long-lived caches (the suffix cache) are never trimmed
    var pinned = Set<Int>()
    /// groups with unpacked entries
    var unpackedGroups: [Group] = []
    /// entries in memory
    var entryCount = 0
    var tick = 0

    /// Called before a group is generated.
    func begin(key: Int, froms: [Int]) -> Group {
        if let old = groups[key] { entryCount -= old.count }
        let g = Group(key: key, froms: froms)
        g.generating = true
        groups[key] = g
        return g
    }

    func register(_ g: Group, fromLists: [Int: [Int]], posIndex: [String: Int]) {
        tick += 1
        g.pack(fromLists: fromLists, posIndex: posIndex)
        g.lastUse = tick
        entryCount += g.count
    }

    /// Releases the entries that were unpacked during a call.
    func releaseUnpacked() {
        for g in unpackedGroups { g.unpacked = [:] }
        unpackedGroups = []
    }

    /// Removes the least recently used groups until at most 3/4 of `limit` generated entries remain.
    /// Must only be called between top-level calls.
    func trim(limit: Int) {
        guard entryCount > limit else { return }
        let target = limit / 4 * 3
        let lru = groups.values.filter { g in !g.froms.contains(where: pinned.contains) }.sorted { $0.lastUse < $1.lastUse }
        for g in lru {
            if entryCount <= target { break }
            entryCount -= g.count
            groups[g.key] = nil
        }
    }

    /// Bounds the caches of facts that never become invalid.
    func trimFacts(limit: Int) {
        if noForms.count > limit { noForms = [] }
        if resolved.count > limit { resolved = [:] }
        if storedText.count > limit { storedText = [:] }
        if posiCache.count > limit { posiCache = [:] }
    }
}

/// FNV-1a over UTF-8
func textHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01b3
    }
    return h
}

struct DBMeta {
    static func value(_ db: SQLiteDB, _ key: String) -> String? {
        guard !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'meta'").isEmpty else { return nil }
        return db.single("SELECT value FROM meta WHERE key = ?", [key]).text
    }
}

extension Ichiran {

    func isVirtual(_ seq: Int) -> Bool { seq >= VirtualStore.seqBase }

    /// The generated entry `seq`; its group is generated again if it is no longer in memory.
    func virtualEntry(_ seq: Int) -> VirtualEntry? {
        guard seq >= VirtualStore.seqBase, virtualMode, let conjugator else { return nil }
        let key = VirtualStore.groupKey(seq)
        if vstore.groups[key] == nil { _ = generateConjugations(key) }
        guard let group = vstore.groups[key], let (e, new) = group.entry(seq, posByIndex: conjugator.posByIndex) else { return nil }
        if new && group.unpacked.count == 1 { vstore.unpackedGroups.append(group) }
        group.lastUse = vstore.tick
        return e
    }

    func virtualEntry(id: Int) -> VirtualEntry? { virtualEntry(VirtualEntry.decode(id).seq) }

    func virtualReading(id: Int) -> ReadingRow? {
        let (seq, local) = VirtualEntry.decode(id)
        return virtualEntry(seq)?.reading(local)
    }

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
            c.addEnding(r[2].text!, pos: r[0].int!, length: r[1].int!)
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

    func allReadingTexts(_ seq: Int) -> [String] {
        if let e = virtualEntry(seq) { return e.kanjiTexts + e.kanaTexts }
        return db.column("SELECT text FROM kanji_text WHERE seq = ? UNION SELECT text FROM kana_text WHERE seq = ?", [seq, seq])
            .compactMap(\.text)
    }

    /// Stored (non-materialized) entries containing all the readings (`insert-conjugation` candidates).
    func storedCandidates(kanji: [String], kana: [String]) -> [Int] {
        // most conjugated forms are not readings of any stored entry: check one reading first
        func exists(_ table: ReadingTable, _ text: String) -> Bool {
            if let bloom = textBloom, !bloom.mayContain(text) { return false }
            let key = TextKey(table.rawValue + "|" + text)
            if let e = vstore.storedText[key] { return e }
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
            ($0.element.ord, $0.element.onum, $0.offset) < ($1.element.ord, $1.element.onum, $1.offset)
        }.map(\.element)
        // the lists are short: linear search beats hashing
        var kanjiReadings: [String] = [], kanaReadings: [String] = []
        var sourceReadings: [(String, String)] = []
        for item in sorted {
            if item.kanjiFlag {
                if !kanjiReadings.containsText(item.text) { kanjiReadings.append(item.text) }
            } else if !kanaReadings.containsText(item.text) {
                kanaReadings.append(item.text)
            }
            if !sourceReadings.contains(where: { sameText($0.0, item.text) && sameText($0.1, item.reading) }) {
                sourceReadings.append((item.text, item.reading))
            }
        }
        if kanaReadings.isEmpty { return }

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
            for (t, s) in sourceReadings where !src.contains(where: { sameText($0.text, t) && sameText($0.sourceText, s) }) {
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
            entry = VirtualEntry(seq: pool.nextSeq)
            let conjugateP = ConjugationConstants.secondaryConjugationTypesFrom.contains(conjType)
            for t in kanjiReadings { entry.addReading(.kanji, t, conjugateP: conjugateP) }
            for t in kanaReadings { entry.addReading(.kana, t, conjugateP: conjugateP) }
            pool.append(entry)
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
                let readings = m[ii].filter { !original.containsText($0.text) }
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
    /// The entries are kept packed in the store; the result holds them as objects.
    @discardableResult
    func generateConjugations(_ seq: Int) -> GeneratedConjugations {
        guard conjugatedPosi(seq) != nil, let conjugator else { return GeneratedConjugations() }
        let group = conjugationGroup(seq)
        let stored = vstore.begin(key: group[0], froms: group)
        var gens: [Int: GeneratedConjugations] = [:]
        for g in group {
            gens[g] = GeneratedConjugations()
        }
        let pool = EntryPool(stored)
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
        let first = stored.firstSeq
        vstore.register(stored, fromLists: gens.mapValues { $0.entries.map { $0.seq - first } }, posIndex: conjugator.posIndex)
        return gens[seq]!
    }

    /// The conjugation group of a dictionary entry, generated if it is not in memory (nil for words that are not conjugated).
    func conjugationGroupKey(_ seq: Int) -> Int? {
        guard conjugatedPosi(seq) != nil else { return nil }
        let key = conjugationGroup(seq)[0]
        if vstore.groups[key] == nil { generateConjugations(seq) }
        return key
    }

    // MARK: - Lookup

    /// Dictionary entries that may have `text` as a conjugated form.
    func deinflectionCandidates(_ text: String) -> Set<Int> {
        guard let conjugator else { return [] }
        // dictionary forms are looked up among the stored readings
        let stored: ((String) -> Bool)? = textBloom.map { bloom in { bloom.mayContain($0) } }
        var bases = conjugator.baseCandidates(text, accept: stored)
        // secondary conjugations: conjugate potential/passive/causative forms again
        var intermediates: [TextKey] = []
        if let v1 = conjugator.posIndex["v1"], let v5s = conjugator.posIndex["v5s"] {
            intermediates = Array(conjugator.baseCandidates(text, conjTypes: ConjugationConstants.secondaryConjugationTypesSet, posIds: [v1, v5s]).keys)
            for m in intermediates {
                for (base, pos) in conjugator.baseCandidates(m.text, conjTypes: ConjugationConstants.secondaryConjugationTypesFromSet, accept: stored) {
                    bases[base, default: []].append(contentsOf: pos)
                }
            }
        }
        let posByText = bases.mapValues { $0.compactMap { conjugator.posByIndex[$0] } }
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
        for (seq, base) in lookup(posByText.keys.map(\.text)) {
            if let posi = conjugatedPosi(seq), let wanted = posByText[TextKey(base)], wanted.contains(where: posi.contains) { seqs.insert(seq) }
        }
        // secondary conjugations of stored entries (conjugations linked to existing words)
        if !intermediates.isEmpty {
            for (target, _) in lookup(intermediates.map(\.text)) {
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
        let key = TextKey(text)
        if vstore.noForms.contains(key) { return [] }
        var groupKeys = vstore.resolved[key]
        if let keys = groupKeys, keys.contains(where: { vstore.groups[$0] == nil }) { groupKeys = nil }
        if groupKeys == nil {
            let cands = deinflectionCandidates(text).sorted()
            if cands.isEmpty {
                vstore.noForms.insert(key)
                return []
            }
            var keys: [Int] = []
            for seq in cands {
                if let k = conjugationGroupKey(seq), !keys.contains(k) { keys.append(k) }
            }
            keys.sort()
            vstore.resolved[key] = keys
            groupKeys = keys
        }
        var result: [ReadingRow] = []
        let hash = textHash(text), units = Array(text.utf16)
        vstore.tick += 1
        for k in groupKeys! {
            guard let g = vstore.groups[k] else { continue }
            g.lastUse = vstore.tick
            g.readings(text, hash: hash, units: units) { r, _ in result.append(r) }
        }
        return result
    }

    /// Generated readings with the given text of entries conjugated from `from` (in generation order).
    func virtualReadings(_ text: String, from: Int) -> [ReadingRow] {
        guard virtualMode, let key = conjugationGroupKey(from), let g = vstore.groups[key], let list = g.fromLists[from] else { return [] }
        var found: [(ReadingRow, Int)] = []
        g.readings(text, hash: textHash(text), units: Array(text.utf16)) { r, position in
            if let i = list.firstIndex(of: position) { found.append((r, i)) }
        }
        return found.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.ord < $1.0.ord }.map(\.0)
    }

    /// Generated readings of a virtual entry.
    func virtualReadings(seq: Int, _ table: ReadingTable) -> [ReadingRow] {
        virtualEntry(seq)?.readings(table) ?? []
    }

    /// Generated entries derived from `from` (as temporary objects).
    func virtualEntries(from: Int) -> [VirtualEntry] {
        guard virtualMode, let conjugator, let key = conjugationGroupKey(from), let g = vstore.groups[key] else { return [] }
        return (g.fromLists[from] ?? []).map { g.unpack($0, posByIndex: conjugator.posByIndex) }
    }


    func maybeTrimVirtual() {
        if virtualMode { vstore.releaseUnpacked() }
        if virtualMode && vstore.entryCount > virtualCacheLimit {
            vstore.trim(limit: virtualCacheLimit)
            conjDataCache.removeAll()
        }
        if virtualMode { vstore.trimFacts(limit: 50_000) }
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

    static func == (a: TextKey, b: TextKey) -> Bool { sameText(a.text, b.text) }
}

/// Byte-wise string equality (`==` on strings compares normalized forms, which is slow for Japanese).
@inline(__always)
func sameText(_ a: String, _ b: String) -> Bool {
    var a = a, b = b
    return a.withUTF8 { pa in
        b.withUTF8 { pb in
            pa.count == pb.count && (pa.count == 0 || memcmp(pa.baseAddress!, pb.baseAddress!, pa.count) == 0)
        }
    }
}

extension Array where Element == String {
    func containsText(_ t: String) -> Bool { contains { sameText($0, t) } }
}
