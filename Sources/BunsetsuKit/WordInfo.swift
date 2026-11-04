// word-info and dictionary output (dict.lisp)

import Foundation

/// The kana of a word: a single reading, or several (for alternative segmentations).
public enum WordKana: Equatable, Sendable {
    case single(String)
    case multiple([String])

    public var values: [String] {
        switch self {
        case .single(let s): return [s]
        case .multiple(let l): return l
        }
    }

    var json: JSONValue {
        switch self {
        case .single(let s): return .string(s)
        case .multiple(let l): return .array(l.map { .string($0) })
        }
    }
}

/// A segmented word (ichiran's `word-info`).
public final class WordInfo: @unchecked Sendable {
    public var type: WordType
    public var text: String
    public var trueText: String?
    public var kana: WordKana
    public var seq: WordSeq = .none
    var conjugations: Conjugations = .none
    public var score: Int = 0
    public var components: [WordInfo] = []
    public var alternative = false
    public var primary = true
    public var start: Int?
    public var end: Int?
    public var counter: (value: String, ordinal: Bool)?
    public var skipped = 0

    init(type: WordType, text: String, kana: WordKana) {
        self.type = type
        self.text = text
        self.kana = kana
    }

    /// true when the word has conjugation data attached (`:root` counts as none)
    public var isConjugated: Bool { conjugations.isConjOnly }

    /// `word-info-json`
    public var json: JSONValue {
        func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .nilValue }
        func seqJSON(_ s: WordSeq) -> JSONValue {
            switch s {
            case .none: return .nilValue
            case .int(let i): return .int(i)
            case .list(let l): return .array(l.map(seqJSON))
            }
        }
        let conj: JSONValue
        switch conjugations {
        case .none: conj = .nilValue
        case .root: conj = "ROOT"
        case .ids(let l): conj = .array(l.map { .int($0) })
        }
        return .object([
            ("type", .string(type.rawValue)),
            ("text", .string(text)),
            ("truetext", opt(trueText)),
            ("kana", kana.json),
            ("seq", seqJSON(seq)),
            ("conjugations", conj),
            ("score", .int(score)),
            ("components", .array(components.map(\.json))),
            ("alternative", alternative ? true : .nilValue),
            ("primary", primary ? true : .nilValue),
            ("start", start.map { .int($0) } ?? .nilValue),
            ("end", end.map { .int($0) } ?? .nilValue),
            ("counter", counter.map { .array([.string($0.value), $0.ordinal ? true : .nilValue]) } ?? .nilValue),
            ("skipped", .int(skipped)),
        ])
    }
}

/// A sense of a dictionary entry.
struct SenseRaw {
    let ord: Int
    let gloss: String
    var props: [(String, [String])]

    func prop(_ tag: String) -> [String]? { props.first { $0.0 == tag }?.1 }
}

extension Ichiran {
    // MARK: senses

    func getSensesRaw(_ seq: Int) -> [SenseRaw] {
        let tags = ["pos", "s_inf", "stagk", "stagr", "field"]
        let glossRows = db.query("""
            SELECT sense.ord, (SELECT group_concat(text, '; ') FROM (SELECT text FROM gloss WHERE gloss.sense_id = sense.id ORDER BY ord))
            FROM sense WHERE sense.seq = ? ORDER BY sense.ord
            """, [seq])
        var senses = glossRows.map { SenseRaw(ord: $0[0].int!, gloss: $0[1].text ?? "", props: []) }
        let props = db.query("""
            SELECT sense.ord, sense_prop.tag, sense_prop.text FROM sense, sense_prop
            WHERE sense.seq = ? AND sense_prop.sense_id = sense.id AND sense_prop.tag IN \(placeholders(tags.count))
            ORDER BY sense.ord, sense_prop.tag, sense_prop.ord
            """, [seq] + tags.map { $0 as SQLBindable })
        var curOrd: Int? = nil, curTag: String? = nil
        var curIdx: Int? = nil
        var bag: [String] = []
        for row in props {
            let sord = row[0].int!, tag = row[1].text!, text = row[2].text!
            if sord != curOrd || tag != curTag {
                if let i = curIdx, let t = curTag { senses[i].props.insert((t, bag), at: 0) }
                curOrd = sord
                curTag = tag
                bag = []
                curIdx = senses.firstIndex { $0.ord == sord }
            }
            bag.append(text)
        }
        // (the last group keeps its reversed order in ichiran)
        if let i = curIdx, let t = curTag { senses[i].props.insert((t, bag.reversed()), at: 0) }
        return senses
    }

    func getSenses(_ seq: Int) -> [(pos: String, gloss: String, props: SenseRaw)] {
        getSensesRaw(seq).map { s in ("[" + (s.prop("pos") ?? []).joined(separator: ",") + "]", s.gloss, s) }
    }

    func getSensesStr(_ seq: Int) -> String {
        var lines: [String] = []
        var rpos = ""
        for (i, (pos, gloss, props)) in getSenses(seq).enumerated() {
            if i == 0 || pos != "[]" { rpos = pos }
            var line = "\(i + 1). \(rpos) "
            if let field = props.prop("field") { line += "{\(field.joined(separator: ","))} " }
            if let inf = props.prop("s_inf") { line += "《\(inf.joined(separator: "; "))》 " }
            line += gloss
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func matchKanaKanji(_ kanaReading: SimpleText, _ kanjiReading: SimpleText, _ restricted: [(String, String)]) -> Bool {
        if kanaReading.nokanji { return false }
        let restr = restricted.filter { $0.0 == kanaReading.text }.map(\.1)
        return restr.isEmpty || restr.contains(kanjiReading.text)
    }

    func matchSenseRestrictions(_ seq: Int, _ props: SenseRaw, _ reading: SimpleText) -> Bool {
        let stagk = props.prop("stagk"), stagr = props.prop("stagr")
        let wtype = reading.wordType
        if stagk == nil && stagr == nil { return true }
        if stagk?.contains(reading.text) == true || stagr?.contains(reading.text) == true { return true }
        if stagr == nil && wtype == .kanji { return false }
        if stagk == nil && wtype == .kana { return false }
        let restricted = db.query("SELECT reading, text FROM restricted_readings WHERE seq = ?", [seq]).map { ($0[0].text!, $0[1].text!) }
        switch wtype {
        case .kanji:
            let r = stagr ?? []
            let rkana = r.isEmpty ? [] : words(.kana, where: "seq = ? AND text IN \(placeholders(r.count))", [seq] + r.map { $0 as SQLBindable })
            return rkana.contains { matchKanaKanji($0, reading, restricted) }
        case .kana:
            let k = stagk ?? []
            let rkanji = k.isEmpty ? [] : words(.kanji, where: "seq = ? AND text IN \(placeholders(k.count))", [seq] + k.map { $0 as SQLBindable })
            return rkanji.contains { matchKanaKanji(reading, $0, restricted) }
        case .gap:
            return false
        }
    }

    func splitPos(_ posStr: String) -> [String] {
        posStr.sub(1, posStr.len - 1).components(separatedBy: ",")
    }

    func getSensesJSON(_ seq: Int, posList: [String] = [], reading: SimpleText? = nil,
                       readingGetter: (() -> SimpleText?)? = nil) -> [JSONValue] {
        var reading = reading
        var readp = false
        var rpos = "", lpos: [String] = []
        var result: [JSONValue] = []
        for (i, (pos, gloss, props)) in getSenses(seq).enumerated() {
            let emptyPos = pos == "[]"
            if i == 0 || !emptyPos { rpos = pos; lpos = splitPos(pos) }
            let rinf = props.prop("s_inf").map { $0.joined(separator: "; ") }
            let rfield = props.prop("field").map { "{" + $0.joined(separator: ",") + "}" }
            guard posList.isEmpty || !Set(lpos).isDisjoint(with: posList) else { continue }
            if reading != nil || readingGetter != nil, props.prop("stagk") != nil || props.prop("stagr") != nil {
                if reading == nil, !readp {
                    readp = true
                    reading = readingGetter?()
                }
                if let rr = reading, !matchSenseRestrictions(seq, props, rr) { continue }
            }
            var js: JSONValue = .object([("pos", .string(rpos)), ("gloss", .string(gloss))])
            if let rfield { js.set("field", .string(rfield)) }
            if let rinf { js.set("info", .string(rinf)) }
            result.append(js)
        }
        return result
    }

    func shortSenseStr(_ seq: Int, withPos: String? = nil) -> String? {
        let join = withPos == nil ? "" : "INNER JOIN sense_prop pos ON pos.sense_id = sense.id AND pos.tag = 'pos' AND pos.text = ?"
        var params: [SQLBindable] = []
        if let withPos { params.append(withPos) }
        params.append(seq)
        return db.query("""
            SELECT (SELECT group_concat(text, '; ') FROM (SELECT text FROM gloss WHERE gloss.sense_id = sense.id ORDER BY ord))
            FROM sense \(join) WHERE sense.seq = ? ORDER BY sense.ord LIMIT 1
            """, params).first?[0].text
    }

    func readingStrStar(_ kanji: String?, _ kana: String) -> String {
        kanji.map { "\($0) 【\(kana)】" } ?? kana
    }

    func readingStrSeq(_ seq: Int) -> String {
        let kanji = db.single("SELECT text FROM kanji_text WHERE seq = ? AND ord = 0", [seq]).text
        let kana = db.single("SELECT text FROM kana_text WHERE seq = ? AND ord = 0", [seq]).text ?? ""
        return readingStrStar(kanji, kana)
    }

    func readingStr(_ obj: SimpleText) -> String {
        originalTextReadingOnly ? obj.text : readingStrStar(getKanji(obj), getKana(obj))
    }

    func entryInfoShort(_ seq: Int, withPos: String? = nil) -> String {
        "\(readingStrSeq(seq)) : " + (shortSenseStr(seq, withPos: withPos) ?? "")
    }

    // MARK: conjugation info

    func conjInfoShort(_ p: ConjProp) -> String {
        var s = "[\(p.pos)] \(conjDescription(p.conjType))"
        if let neg = p.neg { s += neg ? " Negative" : " Affirmative" }
        if let fml = p.fml { s += fml ? " Formal" : " Plain" }
        return s
    }

    func conjDescription(_ type: Int) -> String {
        if let d = conjDescriptionTable[type] { return d }
        return ConjDescriptions.get(type)
    }

    var conjDescriptionTable: [Int: String] {
        if let t = conjDescriptionStorage { return t }
        var t: [Int: String] = [:]
        if !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'conj_description'").isEmpty {
            for r in db.query("SELECT id, description FROM conj_description") { t[r[0].int!] = r[1].text! }
        }
        for (k, v) in Errata.conjDescriptionExtra { t[k] = v }
        conjDescriptionStorage = t
        return t
    }

    func conjPropJSON(_ p: ConjProp) -> JSONValue {
        var js: JSONValue = .object([("pos", .string(p.pos)), ("type", .string(conjDescription(p.conjType)))])
        if p.neg == true { js.set("neg", true) }
        if p.fml == true { js.set("fml", true) }
        return js
    }

    func selectConjs(_ seq: Int, _ conjIds: Conjugations) -> [ConjugationRow] {
        switch conjIds {
        case .root: return []
        case .ids(let ids): return conjRows(seq: seq, ids: ids)
        case .none:
            let r = conjRows(seq: seq, viaNull: true)
            return r.isEmpty ? conjRows(seq: seq) : r
        }
    }

    func isRareru(_ text: String) -> Bool {
        ["られる", "られます", "られない", "られません"].contains { text.hasScalarSuffix($0) }
    }

    /// A hack to remove Passive conjugation on れる forms
    func filterProps(_ props: [ConjProp], _ text: [String]?) -> [ConjProp] {
        props.filter { p in
            !(text != nil && p.conjType == 6 && ["v1", "v1s", "vk"].contains(p.pos) && !text!.contains(where: isRareru))
        }
    }

    func selectConjsAndProps(_ seq: Int, _ conjIds: Conjugations, text: [String]? = nil) -> [(ConjugationRow, [ConjProp])] {
        func order(_ t: Int) -> Int { t == 10 ? 13 : t == 13 ? 10 : t }
        let items = selectConjs(seq, conjIds).map { conj -> (ConjugationRow, [ConjProp], [Int]) in
            let props = conjProps(conj.id)
            let val = props.map { order($0.conjType) }.min() ?? Int.max
            return (conj, filterProps(props, text), [conj.via == nil ? 0 : 1, val])
        }
        return lispStableSort(items) { $0.2.lexicographicallyPrecedes($1.2) }.map { ($0.0, $0.1) }
    }

    func printConjInfo(_ seq: Int, _ conjugations: Conjugations = .none, _ out: inout String) {
        var viaUsed: [Int] = []
        for (conj, props) in selectConjsAndProps(seq, conjugations) {
            if let via = conj.via, viaUsed.contains(via) { continue }
            for (i, p) in props.enumerated() {
                out += "\n" + (i == 0 ? "[" : " ") + " Conjugation: " + conjInfoShort(p)
            }
            if let via = conj.via {
                out += "\n --(via)--"
                printConjInfo(via, .none, &out)
                viaUsed.append(via)
            } else {
                out += "\n  " + entryInfoShort(conj.from)
            }
            out += " ]"
        }
    }

    func conjInfoJSONStar(_ seq: Int, conjugations: Conjugations = .none, text: [String]?, hasGloss: Bool) -> [JSONValue] {
        var viaUsed: [Int] = []
        var result: [JSONValue] = []
        for (conj, props) in selectConjsAndProps(seq, conjugations, text: text) {
            if let via = conj.via, viaUsed.contains(via) { continue }
            let origText = getOriginalTextOnce(getConjData(seq, .ids([conj.id])), text ?? [])
            var js: JSONValue = .object([("prop", .array(props.map(conjPropJSON)))])
            let conjPos = props.map(\.pos)
            if let via = conj.via {
                if origText.isEmpty { continue }
                let cij = conjInfoJSON(via, text: origText, hasGloss: hasGloss)
                if cij.isEmpty { continue }
                js.set("via", .array(cij))
                js.set("readok", cij[0]["readok"] ?? .nilValue)
                viaUsed.append(via)
            } else {
                let origReading = origText.isEmpty ? nil : findWordsSeqs(origText, [conj.from]).first
                if hasGloss && origReading == nil { continue }
                js.set("reading", .string(origReading.map(readingStr) ?? readingStrSeq(conj.from)))
                js.set("gloss", .array(getSensesJSON(conj.from, posList: conjPos, readingGetter: { origReading })))
                js.set("readok", origReading != nil ? true : .nilValue)
            }
            result.append(js)
        }
        return result
    }

    func conjInfoJSON(_ seq: Int, conjugations: Conjugations = .none, text: [String]?, hasGloss: Bool = false) -> [JSONValue] {
        let cij = conjInfoJSONStar(seq, conjugations: conjugations, text: text, hasGloss: hasGloss)
        let f = cij.filter { $0["readok"]?.lispTrue == true }
        return f.isEmpty ? cij : f
    }

    // MARK: word-info output

    func simplifyReadingList(_ readingList: [String]) -> [String] {
        var assoc: [(can: String, cnt: Int, spos: [Int])] = []
        for reading in readingList {
            var off = 0
            var can = String.UnicodeScalarView()
            var spos: [Int] = []
            for (i, c) in reading.unicodeScalars.enumerated() {
                if c == " " {
                    spos.append(i - off)
                    off += 1
                } else {
                    can.append(c)
                }
            }
            var seen = Set<Int>()
            spos = spos.reversed().filter { seen.insert($0).inserted }.reversed()
            let canS = String(can)
            if let i = assoc.firstIndex(where: { $0.can == canS }) {
                assoc[i].spos = spos + assoc[i].spos
                assoc[i].cnt += 1
            } else {
                assoc.append((canS, 1, spos))
            }
        }
        return assoc.map { (can, cnt, spos) in
            var sspos = Array(Set(spos)).sorted()
            var out = String.UnicodeScalarView()
            for (i, c) in can.unicodeScalars.enumerated() {
                if let f = sspos.first, f == i {
                    out.append(spos.filter { $0 == f }.count == cnt ? " " : "·")
                    sspos.removeFirst()
                }
                out.append(c)
            }
            return String(out)
        }
    }

    func mapWordInfoKana(_ wi: WordInfo, separator: String = "/", _ fn: (String) -> String) -> String {
        switch wi.kana {
        case .single(let s): return fn(s)
        case .multiple(let l): return simplifyReadingList(l.map(fn)).joined(separator: separator)
        }
    }

    func wordInfoReadingStr(_ wi: WordInfo) -> String {
        let kana = wi.kana.values.joined(separator: " ")
        if (wi.type == .kanji || (wi.counter != nil && wi.seq != .none)) && !originalTextReadingOnly {
            return readingStrStar(wi.text, kana)
        }
        return readingStrStar(nil, wi.text)
    }

    func wordInfoReading(_ wi: WordInfo) -> SimpleText? {
        guard let tt = wi.trueText, wi.type != .gap else { return nil }
        let table: ReadingTable = wi.type == .kanji ? .kanji : .kana
        return words(table, where: "text = ?", [tt]).first
    }

    func wordInfoStr(_ wi: WordInfo) -> String {
        var s = ""
        func inner(_ wi: WordInfo, _ suffix: Bool = false, _ marker: Bool = false) {
            if marker { s += " * " }
            s += wordInfoReadingStr(wi)
            if !wi.components.isEmpty {
                s += " Compound word: " + wi.components.map(\.text).joined(separator: " + ")
                for comp in wi.components {
                    s += "\n"
                    inner(comp, !comp.primary, true)
                }
            } else if let counter = wi.counter {
                s += "\n" + counter.value
                if let seq = wi.seq.value { s += "\n" + getSensesStr(seq) }
            } else {
                let seq = wi.seq.value
                if suffix, let desc = getSuffixDescription(seq) {
                    s += "  [suffix]: \(desc) "
                } else if wi.conjugations == .none || wi.conjugations == .root {
                    s += "\n" + (seq.map(getSensesStr) ?? "???")
                }
                if let seq { printConjInfo(seq, wi.conjugations, &s) }
            }
        }
        if wi.alternative {
            for (i, c) in wi.components.enumerated() {
                if i > 0 { s += "\n" }
                s += "<\(i + 1)>. "
                inner(c)
            }
        } else {
            inner(wi)
        }
        return s
    }

    func wordInfoGlossJSON(_ wi: WordInfo, rootOnly: Bool = false) -> JSONValue {
        func inner(_ wi: WordInfo, _ suffix: Bool = false) -> JSONValue {
            var js: JSONValue = .object([("reading", .string(wordInfoReadingStr(wi))), ("text", .string(wi.text)), ("kana", wi.kana.json)])
            js.set("score", .int(wi.score))
            if !wi.components.isEmpty {
                js.set("compound", .array(wi.components.map { .string($0.text) }))
                js.set("components", .array(wi.components.map { inner($0, !$0.primary) }))
            } else if let counter = wi.counter {
                js.set("counter", .object([("value", .string(counter.value)), ("ordinal", counter.ordinal ? true : .nilValue)]))
                if let seq = wi.seq.value {
                    js.set("seq", .int(seq))
                    let gloss = getSensesJSON(seq, posList: ["ctr"], readingGetter: { self.wordInfoReading(wi) })
                    if !gloss.isEmpty { js.set("gloss", .array(gloss)) }
                }
            } else {
                let seq = wi.seq.value
                var hasGloss = false
                if let seq { js.set("seq", .int(seq)) }
                if rootOnly {
                    js.set("gloss", .array(seq.map { getSensesJSON($0, readingGetter: { self.wordInfoReading(wi) }) } ?? []))
                    return js
                }
                if suffix, let desc = getSuffixDescription(seq) {
                    js.set("suffix", .string(desc))
                } else if let seq, wi.conjugations == .none || wi.conjugations == .root {
                    let gloss = getSensesJSON(seq, readingGetter: { self.wordInfoReading(wi) })
                    if !gloss.isEmpty {
                        hasGloss = true
                        js.set("gloss", .array(gloss))
                    }
                }
                if let seq {
                    js.set("conj", .array(conjInfoJSON(seq, conjugations: wi.conjugations,
                                                       text: wi.trueText.map { [$0] }, hasGloss: hasGloss)))
                }
            }
            return js
        }
        if wi.alternative {
            return .object([("alternative", .array(wi.components.map { inner($0) }))])
        }
        return inner(wi)
    }
}
