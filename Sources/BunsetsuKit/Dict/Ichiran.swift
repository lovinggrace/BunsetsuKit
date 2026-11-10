// Port of the core of ichiran/dict (dict.lisp)

import Foundation

/// The main entry point: a Japanese segmenter / romanizer backed by a JMdict SQLite database.
///
/// Instances are safe to use from multiple threads; calls are serialized internally.
public final class Ichiran: @unchecked Sendable {
    let db: SQLiteDB
    let lock = NSRecursiveLock()

    /// Maximum word length considered during segmentation.
    static let maxWordLength = 50

    // dynamically bound variables of the Lisp code
    var substringHash: [String: [ReadingRow]]? = nil
    var suffixMapTemp: [Int: [SuffixMatch]]? = nil
    var suffixNextEnd: Int? = nil
    var disableHints = false
    /// `*original-text-reading-only*`
    public var originalTextReadingOnly = false

    // caches (defcache)
    lazy var noConjDataSet: Set<Int> = loadNoConjData()
    lazy var archBase: Set<Int> = loadArchBase()
    lazy var isArchSet: Set<Int> = loadIsArch()
    var counterCacheStorage: [String: [CounterArgs]]? = nil
    var suffixCache: [String: [SuffixVal]]? = nil
    var suffixClass: [Int: String] = [:]

    // memoization of immutable data
    var entryCache: [Int: EntryRow?] = [:]
    var conjDataCache: [String: [ConjData]] = [:]
    var nonArchPosiCache: [[Int]: [String]] = [:]
    var conjPropCache: [Int: [ConjProp]] = [:]
    var kanjiReadingCache: [String: [(String, String)]] = [:]
    var conjDescriptionStorage: [Int: String]? = nil

    // conjugations computed at lookup time (compact databases)
    let virtualMode: Bool
    lazy var conjugator: Conjugator? = virtualMode ? loadConjugator() : nil
    lazy var materializedFrom: Set<Int> = virtualMode
        ? Set(db.column("SELECT seq FROM materialized_from").compactMap(\.int)) : []
    var vstore = VirtualStore()
    lazy var textBloom: BloomFilter? = virtualMode ? BloomFilter.load(db) : nil
    /// Maximum number of generated conjugated entries kept in memory (compact databases).
    /// An entry takes about 130 bytes; a verb has about 200 of them.
    public var virtualCacheLimit = 150_000
    private var callDepth = 0

    /// Opens a database built with `DictionaryBuilder` (or `bunsetsu build`).
    public init(databasePath: String) throws {
        db = try SQLiteDB(path: databasePath, readOnly: true)
        virtualMode = DBMeta.value(db, "format") == "compact"
    }

    /// Opens a database read-write (used by the builder).
    init(database: SQLiteDB) {
        db = database
        virtualMode = DBMeta.value(db, "format") == "compact"
    }

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        // one read transaction per call saves locking the file for every query
        let transaction = callDepth == 0 && db.readOnly
        if callDepth == 0 { maybeTrimVirtual() }
        if transaction { db.query("BEGIN") }
        callDepth += 1
        defer {
            callDepth -= 1
            if transaction { db.query("COMMIT") }
            lock.unlock()
        }
        return try body()
    }

    /// Clears in-memory caches (needed after the database was modified).
    func resetCaches() {
        noConjDataSet = loadNoConjData()
        archBase = loadArchBase()
        isArchSet = loadIsArch()
        counterCacheStorage = nil
        suffixCache = nil
        suffixClass = [:]
        entryCache = [:]
        conjDataCache = [:]
        nonArchPosiCache = [:]
        conjPropCache = [:]
        kanjiReadingCache = [:]
        conjDescriptionStorage = nil
        vstore = VirtualStore()
        conjugator = virtualMode ? loadConjugator() : nil
        materializedFrom = virtualMode ? Set(db.column("SELECT seq FROM materialized_from").compactMap(\.int)) : []
    }

    /// Initializes all caches up front (otherwise they are built lazily on first use).
    public func warmUp() {
        synchronized {
            _ = noConjDataSet
            _ = isArchSet
            _ = counterCache
            initSuffixes()
        }
    }

    // MARK: - Entries and readings

    func getEntry(_ seq: Int) -> EntryRow? {
        if isVirtual(seq) {
            return virtualEntry(seq).map { EntryRow(seq: $0.seq, rootP: false, nKanji: $0.kanji.count, nKana: $0.kana.count, primaryNokanji: false) }
        }
        if let e = entryCache[seq] { return e }
        let r = db.query("SELECT seq, root_p, n_kanji, n_kana, primary_nokanji FROM entry WHERE seq = ?", [seq]).first
        let e = r.map { EntryRow(seq: $0[0].int!, rootP: $0[1].bool ?? false, nKanji: $0[2].int ?? 0,
                                 nKana: $0[3].int ?? 0, primaryNokanji: $0[4].bool ?? false) }
        entryCache[seq] = e
        return e
    }

    func readings(_ table: ReadingTable, where cond: String, _ params: [SQLBindable] = [], order: String = "id") -> [ReadingRow] {
        db.query("SELECT \(ReadingRow.select(table)) FROM \(table.rawValue) WHERE \(cond) ORDER BY \(order)", params)
            .map { ReadingRow(table: table, row: $0) }
    }

    func words(_ table: ReadingTable, where cond: String, _ params: [SQLBindable] = [], order: String = "id") -> [DictText] {
        readings(table, where: cond, params, order: order).map(DictText.init)
    }

    func readingById(_ table: ReadingTable, _ id: Int) -> DictText? {
        if id < 0 { return virtualReading(id: id).map(DictText.init) }
        return words(table, where: "id = ?", [id]).first
    }

    /// Readings of an entry (stored or generated)
    func readingsOf(_ seq: Int, _ table: ReadingTable, text: String? = nil, orderByOrd: Bool = false) -> [ReadingRow] {
        if isVirtual(seq) {
            let r = virtualReadings(seq: seq, table)
            return text.map { t in r.filter { $0.text == t } } ?? r
        }
        if let text { return readings(table, where: "seq = ? AND text = ?", [seq, text], order: orderByOrd ? "ord" : "id") }
        return readings(table, where: "seq = ?", [seq], order: orderByOrd ? "ord" : "id")
    }

    /// `find-word`
    func findWord(_ word: String, rootOnly: Bool = false) -> [DictText] {
        guard word.len <= Ichiran.maxWordLength else { return [] }
        if !rootOnly, let hash = substringHash, let inits = hash[word] {
            return inits.map(DictText.init)
        }
        let table = ReadingTable.forText(word)
        if rootOnly {
            return db.query("""
                SELECT \(ReadingRow.select(table, alias: "wt")) FROM \(table.rawValue) wt
                INNER JOIN entry ON wt.seq = entry.seq WHERE wt.text = ? AND entry.root_p ORDER BY wt.id
                """, [word]).map { DictText(ReadingRow(table: table, row: $0)) }
        }
        return words(table, where: "text = ?", [word]) + virtualReadings(word).filter { $0.table == table }.map(DictText.init)
    }

    /// `find-substring-words`
    func findSubstringWords(_ str: String, sticky: Set<Int>) -> [String: [ReadingRow]] {
        var hash: [String: [ReadingRow]] = [:]
        var kanaKeys = Set<String>(), kanjiKeys = Set<String>()
        let s = str.scalars
        for start in 0..<s.count where !sticky.contains(start) {
            var end = start + 1
            while end <= min(s.count, start + Ichiran.maxWordLength) {
                if !sticky.contains(end) {
                    let part = String(scalars: s[start..<end])
                    hash[part] = []
                    if testWord(part, .kana) { kanaKeys.insert(part) } else { kanjiKeys.insert(part) }
                }
                end += 1
            }
        }
        for (table, keys) in [(ReadingTable.kana, kanaKeys), (.kanji, kanjiKeys)] where !keys.isEmpty {
            for chunk in chunked(Array(keys)) {
                for r in readings(table, where: "text IN \(placeholders(chunk.count))", chunk) {
                    // Lisp pushes rows, reversing the query order
                    hash[r.text, default: []].insert(r, at: 0)
                }
            }
        }
        if virtualMode {
            for key in Array(hash.keys) {
                let table = ReadingTable.forText(key)
                for r in virtualReadings(key) where r.table == table { hash[key]!.insert(r, at: 0) }
            }
        }
        return hash
    }

    /// `find-words-seqs`
    func findWordsSeqs(_ words: [String], _ seqs: [Int]) -> [DictText] {
        let kana = words.filter { testWord($0, .kana) }
        let kanji = words.filter { !testWord($0, .kana) }
        var result: [DictText] = []
        if !kanji.isEmpty, !seqs.isEmpty {
            result += self.words(.kanji, where: "text IN \(placeholders(kanji.count)) AND seq IN \(placeholders(seqs.count))",
                                 kanji + seqs.map { $0 as SQLBindable })
        }
        if !kana.isEmpty, !seqs.isEmpty {
            result += self.words(.kana, where: "text IN \(placeholders(kana.count)) AND seq IN \(placeholders(seqs.count))",
                                 kana + seqs.map { $0 as SQLBindable })
        }
        for seq in seqs where isVirtual(seq) {
            result += readingsOf(seq, .kanji).filter { kanji.contains($0.text) }.map(DictText.init)
            result += readingsOf(seq, .kana).filter { kana.contains($0.text) }.map(DictText.init)
        }
        return result
    }

    /// `find-word-seq`
    func findWordSeq(_ word: String, _ seqs: [Int]) -> [DictText] {
        guard !seqs.isEmpty else { return [] }
        let table = ReadingTable.forText(word)
        return words(table, where: "text = ? AND seq IN \(placeholders(seqs.count))", [word] + seqs.map { $0 as SQLBindable })
            + seqs.filter(isVirtual).flatMap { readingsOf($0, table, text: word) }.map(DictText.init)
    }

    /// `find-word-conj-of`
    func findWordConjOf(_ word: String, _ seqs: [Int]) -> [DictText] {
        let table = ReadingTable.forText(word)
        var result = findWordSeq(word, seqs)
        guard !seqs.isEmpty else { return result }
        let more = db.query("""
            SELECT \(ReadingRow.select(table, alias: "kt")) FROM \(table.rawValue) kt, conjugation conj
            WHERE kt.seq = conj.seq AND conj."from" IN \(placeholders(seqs.count)) AND kt.text = ?
            ORDER BY kt.id
            """, seqs.map { $0 as SQLBindable } + [word]).map { DictText(ReadingRow(table: table, row: $0)) }
        let generated = seqs.flatMap { virtualReadings(word, from: $0) }.filter { $0.table == table }.map(DictText.init)
        // union by id
        var ids = Set(result.map(\.id))
        for w in more + generated where !ids.contains(w.id) {
            ids.insert(w.id)
            result.append(w)
        }
        return result
    }

    /// `find-word-with-pos`
    func findWordWithPos(_ word: String, _ posi: [String]) -> [DictText] {
        let table = ReadingTable.forText(word)
        return db.query("""
            SELECT DISTINCT \(ReadingRow.select(table, alias: "kt")) FROM \(table.rawValue) kt
            INNER JOIN sense_prop sp ON sp.seq = kt.seq AND sp.tag = 'pos'
            WHERE kt.text = ? AND sp.text IN \(placeholders(posi.count)) ORDER BY kt.id
            """, [word] + posi.map { $0 as SQLBindable }).map { DictText(ReadingRow(table: table, row: $0)) }
    }

    // MARK: - Conjugation data

    /// Full databases: entries without conjugation data. Compact databases: stored entries with conjugation data.
    private func loadNoConjData() -> Set<Int> {
        if virtualMode {
            return Set(db.column("SELECT DISTINCT seq FROM conjugation").compactMap(\.int))
        }
        return Set(db.column("""
            SELECT entry.seq FROM entry LEFT JOIN conjugation c ON entry.seq = c.seq WHERE c.seq IS NULL
            """).compactMap(\.int))
    }

    func noConjData(_ seq: Int) -> Bool {
        if virtualMode { return !isVirtual(seq) && !noConjDataSet.contains(seq) }
        return noConjDataSet.contains(seq)
    }

    func conjProps(_ conjId: Int) -> [ConjProp] {
        if conjId < 0 { return virtualEntry(id: conjId)?.props(conjId) ?? [] }
        if let c = conjPropCache[conjId] { return c }
        let props = db.query("SELECT id, conj_id, conj_type, pos, neg, fml FROM conj_prop WHERE conj_id = ? ORDER BY id", [conjId])
            .map { ConjProp(id: $0[0].int!, conjId: $0[1].int!, conjType: $0[2].int!, pos: $0[3].text ?? "",
                            neg: $0[4].bool, fml: $0[5].bool) }
        conjPropCache[conjId] = props
        return props
    }

    func conjugationRows(where cond: String, _ params: [SQLBindable]) -> [ConjugationRow] {
        db.query("SELECT id, seq, \"from\", via FROM conjugation WHERE \(cond) ORDER BY id", params)
            .map { ConjugationRow(id: $0[0].int!, seq: $0[1].int!, from: $0[2].int!, via: $0[3].int) }
    }

    func conjugation(_ id: Int) -> ConjugationRow? {
        if id < 0 { return virtualEntry(id: id)?.conjs.first { $0.id == id } }
        return conjugationRows(where: "id = ?", [id]).first
    }

    /// Conjugation rows of an entry (stored or generated)
    func conjRows(seq: Int, ids: [Int]? = nil, from: Int? = nil, viaNull: Bool = false) -> [ConjugationRow] {
        if isVirtual(seq) {
            return (virtualEntry(seq)?.conjs ?? []).filter { c in
                (ids == nil || ids!.contains(c.id)) && (from == nil || c.from == from) && (!viaNull || c.via == nil)
            }
        }
        var cond = "seq = ?"
        var params: [SQLBindable] = [seq]
        if let ids { cond += " AND id IN \(placeholders(ids.count))"; params += ids.map { $0 as SQLBindable } }
        if let from { cond += " AND \"from\" = ?"; params.append(from) }
        if viaNull { cond += " AND via IS NULL" }
        return conjugationRows(where: cond, params)
    }

    func sourceReadings(_ conjId: Int, texts: [String]? = nil) -> [(text: String, sourceText: String)] {
        if conjId < 0 {
            let all = virtualEntry(id: conjId)?.src(conjId) ?? []
            return texts.map { t in all.filter { t.contains($0.text) } } ?? all
        }
        if let texts {
            return db.query("SELECT text, source_text FROM conj_source_reading WHERE conj_id = ? AND text IN \(placeholders(texts.count)) ORDER BY id",
                            [conjId] + texts.map { $0 as SQLBindable }).map { ($0[0].text!, $0[1].text!) }
        }
        return db.query("SELECT text, source_text FROM conj_source_reading WHERE conj_id = ? ORDER BY id", [conjId])
            .map { ($0[0].text!, $0[1].text!) }
    }

    enum ConjFilter: Hashable {
        case all, root, ids([Int]), from(Int)

        init(_ c: Conjugations) {
            switch c {
            case .none: self = .all
            case .root: self = .root
            case .ids(let l): self = .ids(l)
            }
        }
    }

    /// `get-conj-data`
    func getConjData(_ seq: Int, _ filter: ConjFilter = .all, texts: [String]? = nil) -> [ConjData] {
        if filter == .root || noConjData(seq) { return [] }
        let key = "\(seq)|\(filter)|\(texts?.joined(separator: "\u{1}") ?? "\u{2}")"
        if let c = conjDataCache[key] { return c }
        let conjs: [ConjugationRow]
        switch filter {
        case .all, .root: conjs = conjRows(seq: seq)
        case .ids(let ids): conjs = conjRows(seq: seq, ids: ids)
        case .from(let from): conjs = conjRows(seq: seq, from: from)
        }
        var result: [ConjData] = []
        for conj in conjs {
            let srcMap = sourceReadings(conj.id, texts: texts)
            if texts == nil || !srcMap.isEmpty {
                for prop in conjProps(conj.id) {
                    result.append(ConjData(seq: conj.seq, from: conj.from, via: conj.via, prop: prop, srcMap: srcMap))
                }
            }
        }
        if conjDataCache.count > 200_000 { conjDataCache.removeAll() }
        conjDataCache[key] = result
        return result
    }

    func getOriginalTextOnce(_ conjDatas: [ConjData], _ texts: [String]) -> [String] {
        conjDatas.flatMap { cd in cd.srcMap.filter { texts.contains($0.text) }.map(\.sourceText) }
    }

    /// `get-original-text*`: returns (text, seq) pairs
    func getOriginalTextStar(_ conjDatas: [ConjData], _ texts: [String]) -> [(String, Int)] {
        conjDatas.flatMap { cd -> [(String, Int)] in
            let src = cd.srcMap.filter { texts.contains($0.text) }.map(\.sourceText)
            if let via = cd.via {
                let newCd = getConjData(via, .from(cd.from))
                return getOriginalTextStar(newCd, src)
            }
            return src.map { ($0, cd.from) }
        }
    }

    /// `get-original-text`: unconjugated reading objects
    func getOriginalText(_ reading: SimpleText, conjData: [ConjData]? = nil) -> [DictText] {
        if let p = reading as? ProxyText { return getOriginalText(p.source, conjData: conjData) }
        let orig = getOriginalTextStar(conjData ?? wordConjData(reading), [reading.text])
        let table: ReadingTable = reading.wordType == .kanji ? .kanji : .kana
        return orig.flatMap { (txt, seq) in readingsOf(seq, table, text: txt).map(DictText.init) }
    }

    // MARK: - Best readings

    private func parents(_ table: ReadingTable, _ seq: Int, _ text: String) -> [(Int, Int)] {
        if isVirtual(seq) {
            return conjRows(seq: seq).flatMap { conj in
                sourceReadings(conj.id, texts: [text]).flatMap { src in
                    readingsOf(conj.via ?? conj.from, table, text: src.sourceText).map { ($0.id, conj.id) }
                }
            }
        }
        return db.query("""
            SELECT kt.id, conj.id FROM \(table.rawValue) kt, conj_source_reading csr, conjugation conj
            WHERE conj.seq = ? AND conj.id = csr.conj_id AND csr.text = ?
              AND kt.seq = (CASE WHEN conj.via IS NOT NULL THEN conj.via ELSE conj."from" END)
              AND kt.text = csr.source_text
            """, [seq, text]).map { ($0[0].int!, $0[1].int!) }
    }

    private func sourceReadingTexts(_ conjId: Int, _ sourceText: String) -> [String] {
        sourceReadings(conjId).filter { $0.sourceText == sourceText }.map(\.text)
    }

    /// `best-kana-conj` (nil means :null)
    func bestKanaConj(_ obj: DictText) -> String? {
        let wc = obj.conjugations
        if (wc == .none || wc == .root), let b = obj.row.best { return b }
        for (pid, cid) in parents(.kanji, obj.seq, obj.text) {
            guard let parentKt = readingById(.kanji, pid) else { continue }
            guard let parentBk = bestKanaConj(parentKt) else { continue }
            if case .root = wc { continue }
            if case .ids(let ids) = wc, !ids.contains(cid) { continue }
            let readings = sourceReadingTexts(cid, parentBk)
            if readings.isEmpty { continue }
            if readings.count == 1 { return readings[0] }
            let km = kanjiCrossMatch(parentKt.text, parentBk, obj.text)
            if let km, readings.contains(km) { return km }
            let pattern = KanjiPattern(obj.text)
            let lenKm = km?.len ?? 0
            // try to find the same length as km first, this allows to match 来れる to これる instead of こられる
            let sorted = readings.enumerated().sorted {
                let a = abs($0.element.len - lenKm), b = abs($1.element.len - lenKm)
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
            return sorted.first(where: pattern.matches) ?? readings[0]
        }
        return nil
    }

    /// `best-kanji-conj` (nil means :null)
    func bestKanjiConj(_ obj: DictText) -> String? {
        let wc = obj.conjugations
        if (wc == .none || wc == .root), let b = obj.row.best { return b }
        if obj.nokanji || (getEntry(obj.seq)?.nKanji ?? 0) == 0 { return nil }
        for (pid, cid) in parents(.kana, obj.seq, obj.text) {
            guard let parent = readingById(.kana, pid), let parentBk = bestKanjiConj(parent) else { continue }
            if case .root = wc { continue }
            if case .ids(let ids) = wc, !ids.contains(cid) { continue }
            let readings = sourceReadingTexts(cid, parentBk)
            if let m = readings.first(where: { kanjiMatch($0, obj.text) }) { return m }
        }
        return nil
    }

    /// old get-kana, used when everything else fails
    func getKanjiKanaOld(_ obj: DictText) -> String {
        let pattern = KanjiPattern(obj.text)
        let kts = readingsOf(obj.seq, .kana, orderByOrd: true)
        return kts.first(where: { pattern.matches($0.text) })?.text ?? kts.first?.text ?? ""
    }

    // MARK: - Generic functions on words

    /// `get-kana`
    func getKana(_ w: Word) -> String {
        switch w {
        case let s as SimpleText:
            if !(disableHints || s.hinted) {
                let saved = disableHints
                disableHints = true
                let hint = getHint(s)
                disableHints = saved
                if let hint { return hint }
            }
            return simpleKana(s)
        case let c as CompoundText:
            return c.kana
        case let c as CounterText:
            return counterKana(c)
        default:
            return ""
        }
    }

    private func simpleKana(_ s: SimpleText) -> String {
        switch s {
        case let p as ProxyText: return p.kana
        case let d as DictText:
            if d.row.table == .kana { return d.text }
            return bestKanaConj(d) ?? getKanjiKanaOld(d)
        default: return ""
        }
    }

    /// `get-kanji`
    func getKanji(_ w: Word) -> String? {
        switch w {
        case let d as DictText:
            return d.row.table == .kanji ? d.text : bestKanjiConj(d)
        case let p as ProxyText:
            return getKanji(p.source)
        case let c as CounterText:
            return Numbers.numberToKanji(c.numberValue) + c.counterText
        default:
            return nil
        }
    }

    /// `get-text` / `text`
    func getText(_ w: Word) -> String {
        switch w {
        case let s as SimpleText: return s.text
        case let c as CompoundText: return c.text
        case let c as CounterText: return c.text
        default: return ""
        }
    }

    func getText(_ s: Segment) -> String {
        if let t = s.text { return t }
        let t = getText(s.word)
        s.text = t
        return t
    }

    func trueText(_ w: Word) -> String {
        if let s = w as? SimpleText { return s.trueText }
        return getText(w)
    }

    func trueKana(_ w: Word) -> String {
        if let p = w as? ProxyText { return trueKana(p.source) }
        return getKana(w)
    }

    func trueKanji(_ w: Word) -> String? {
        if let p = w as? ProxyText { return trueKanji(p.source) }
        return getKanji(w)
    }

    func wordType(_ w: Word) -> WordType {
        switch w {
        case let s as SimpleText: return s.wordType
        case let c as CompoundText: return wordType(c.primary)
        case let c as CounterText: return c.wordType
        default: return .gap
        }
    }

    /// `seq` of a non-compound word
    func seqOf(_ w: Word) -> Int? {
        switch w {
        case let s as SimpleText: return s.seq
        case let c as CounterText: return c.seq
        default: return nil
        }
    }

    /// `seq` of a compound word (list of the component seqs)
    func seqList(_ w: Word) -> [Int]? {
        guard let c = w as? CompoundText else { return nil }
        return c.words.compactMap(seqOf)
    }

    func wordSeq(_ w: Word) -> WordSeq {
        if let l = seqList(w) { return .list(l.map { .int($0) }) }
        if let s = seqOf(w) { return .int(s) }
        return .none
    }

    func common(_ w: Word) -> Int? {
        switch w {
        case let s as SimpleText: return s.common
        case let c as CompoundText: return common(c.primary)
        case let c as CounterText: return c.common
        default: return nil
        }
    }

    func ord(_ w: Word) -> Int {
        switch w {
        case let s as SimpleText: return s.ord
        case let c as CompoundText: return ord(c.primary)
        case let c as CounterText: return c.ord
        default: return 0
        }
    }

    func nokanji(_ w: Word) -> Bool {
        switch w {
        case let s as SimpleText: return s.nokanji
        case let c as CounterText: return c.nokanji
        default: return false
        }
    }

    func conjugations(_ w: Word) -> Conjugations {
        switch w {
        case let s as SimpleText: return s.conjugations
        case let c as CompoundText: return conjugations(c.lastWord)
        default: return .none
        }
    }

    func setConjugations(_ w: Word, _ value: Conjugations) {
        switch w {
        case let s as SimpleText: s.conjugations = value
        case let c as CompoundText: setConjugations(c.lastWord, value)
        default: break
        }
    }

    /// `word-conj-data`
    func wordConjData(_ w: Word) -> [ConjData] {
        switch w {
        case let s as SimpleText:
            return getConjData(s.seq, ConjFilter(s.conjugations), texts: [s.trueText])
        case let c as CompoundText:
            return wordConjData(c.lastWord)
        default:
            return []
        }
    }

    // MARK: - Proxy and compound words

    /// `find-word-as-hiragana`
    func findWordAsHiragana(_ str: String, exclude: [Int] = [], finder: ((String) -> [Word])? = nil) -> [Word] {
        let hira = asHiragana(str)
        guard str != hira else { return [] }
        let found: [Word] = finder.map { $0(hira) } ?? findWord(hira, rootOnly: true)
        return found.compactMap { w in
            guard let s = w as? SimpleText, !exclude.contains(s.seq) else { return nil }
            return ProxyText(source: s, text: str, kana: str)
        }
    }

    /// `adjoin-word`
    func adjoinWord(_ w1: Word, _ w2: Word, text: String? = nil, kana: String? = nil,
                    scoreMod: ScoreMod? = nil, scoreBase: Word? = nil) -> Word {
        let text = text ?? (getText(w1) + getText(w2))
        let kana = kana ?? (getKana(w1) + getKana(w2))
        let scoreMod = scoreMod ?? .int(0)
        if let c = w1 as? CompoundText {
            c.text = text
            c.kana = kana
            c.words.append(w2)
            if case .list(let old) = c.scoreMod {
                c.scoreMod = .list([scoreMod] + old)
            } else {
                c.scoreMod = .list([scoreMod, c.scoreMod])
            }
            return c
        }
        return CompoundText(text: text, kana: kana, primary: w1, words: [w1, w2], scoreMod: scoreMod, scoreBase: scoreBase)
    }
}

/// The `seq` of a word: an integer, a list (compound words / alternatives), or nil.
public indirect enum WordSeq: Equatable, Sendable {
    case none
    case int(Int)
    case list([WordSeq])

    public var value: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
}
