// Data model of ichiran/dict (dict.lisp, dict-counters.lisp)

import Foundation

// MARK: - Database rows

struct EntryRow {
    let seq: Int
    var rootP: Bool
    var nKanji: Int
    var nKana: Int
    var primaryNokanji: Bool
}

enum ReadingTable: String {
    case kanji = "kanji_text"
    case kana = "kana_text"

    /// column holding the best opposite reading
    var bestColumn: String { self == .kanji ? "best_kana" : "best_kanji" }

    static func forText(_ text: String) -> ReadingTable { testWord(text, .kana) ? .kana : .kanji }
}

struct ReadingRow {
    let table: ReadingTable
    let id: Int
    let seq: Int
    let text: String
    let ord: Int
    let common: Int?
    let commonTags: String
    let conjugateP: Bool
    let nokanji: Bool
    /// best_kana for kanji_text, best_kanji for kana_text
    let best: String?

    static func columns(_ alias: String? = nil) -> String {
        let p = alias.map { "\($0)." } ?? ""
        return ["id", "seq", "text", "ord", "common", "common_tags", "conjugate_p", "nokanji"]
            .map { p + $0 }.joined(separator: ",")
    }

    static func select(_ table: ReadingTable, alias: String? = nil) -> String {
        let p = alias.map { "\($0)." } ?? ""
        return columns(alias) + ",\(p)\(table.bestColumn)"
    }

    init(table: ReadingTable, row: Row) {
        self.table = table
        id = row[0].int!
        seq = row[1].int!
        text = row[2].text ?? ""
        ord = row[3].int ?? 0
        common = row[4].int
        commonTags = row[5].text ?? ""
        conjugateP = row[6].bool ?? true
        nokanji = row[7].bool ?? false
        best = row[8].text
    }
}

struct ConjProp: Equatable {
    let id: Int
    let conjId: Int
    let conjType: Int
    let pos: String
    let neg: Bool?
    let fml: Bool?
}

struct ConjugationRow {
    let id: Int
    let seq: Int
    let from: Int
    let via: Int?
}

struct ConjData {
    let seq: Int
    let from: Int
    let via: Int?
    let prop: ConjProp
    let srcMap: [(text: String, sourceText: String)]
}

// MARK: - Words

public enum WordType: String, Sendable {
    case kanji = "KANJI"
    case kana = "KANA"
    case gap = "GAP"
}

/// The value of `word-conjugations`: nil, :root, or a list of conjugation ids.
enum Conjugations: Equatable {
    case none
    case root
    case ids([Int])

    static func list(_ ids: [Int]) -> Conjugations { ids.isEmpty ? .none : .ids(ids) }

    var isNone: Bool { self == .none }

    /// `(and wc (not (eql wc :root)))`
    var isConjOnly: Bool {
        if case .ids = self { return true }
        return false
    }

    var ids: [Int] {
        if case .ids(let l) = self { return l }
        return []
    }
}

/// Base class of all word objects (the Lisp generic function protocol is implemented on `Ichiran`).
class Word {}

class SimpleText: Word {
    private var storedConjugations: Conjugations = .none
    var hinted: Bool

    init(hinted: Bool = false) { self.hinted = hinted }

    var conjugations: Conjugations {
        get { storedConjugations }
        set { storedConjugations = newValue }
    }

    var seq: Int { fatalError("abstract") }
    var text: String { fatalError("abstract") }
    var ord: Int { fatalError("abstract") }
    var common: Int? { fatalError("abstract") }
    var nokanji: Bool { fatalError("abstract") }
    var wordType: WordType { fatalError("abstract") }

    /// `true-text`
    var trueText: String { text }
}

/// kanji-text or kana-text
final class DictText: SimpleText {
    let row: ReadingRow

    init(_ row: ReadingRow) {
        self.row = row
        super.init()
    }

    override var seq: Int { row.seq }
    override var text: String { row.text }
    override var ord: Int { row.ord }
    override var common: Int? { row.common }
    override var nokanji: Bool { row.nokanji }
    override var wordType: WordType { row.table == .kanji ? .kanji : .kana }
    var id: Int { row.id }
}

/// kanji-text or kana-text with changed spelling
final class ProxyText: SimpleText {
    let proxyText: String
    let kana: String
    let source: SimpleText

    init(source: SimpleText, text: String, kana: String, hinted: Bool = false) {
        self.source = source
        self.proxyText = text
        self.kana = kana
        super.init(hinted: hinted)
    }

    override var conjugations: Conjugations {
        get { source.conjugations }
        set { source.conjugations = newValue }
    }

    override var seq: Int { source.seq }
    override var text: String { proxyText }
    override var ord: Int { source.ord }
    override var common: Int? { source.common }
    override var nokanji: Bool { source.nokanji }
    override var wordType: WordType { source.wordType }
    override var trueText: String { source.trueText }
}

/// Score modifier of compound words: an integer, a function, or a list of those.
indirect enum ScoreMod {
    case int(Int)
    case fn((Int) -> Int)
    case list([ScoreMod])

    func apply(_ score: Int, _ len: Int) -> Int {
        switch self {
        case .int(let m): return score * m * len
        case .fn(let f): return f(score)
        case .list(let l): return l.reduce(0) { $0 + $1.apply(score, len) }
        }
    }
}

/// Compound words (2 or more words squished together)
final class CompoundText: Word {
    var text: String
    var kana: String
    let primary: Word
    var words: [Word]
    var scoreBase: Word?
    var scoreMod: ScoreMod

    init(text: String, kana: String, primary: Word, words: [Word], scoreMod: ScoreMod, scoreBase: Word? = nil) {
        self.text = text
        self.kana = kana
        self.primary = primary
        self.words = words
        self.scoreMod = scoreMod
        self.scoreBase = scoreBase
    }

    var lastWord: Word { words[words.count - 1] }

    /// `score-base`
    var effectiveScoreBase: Word { scoreBase ?? primary }
}

// MARK: - Counters

enum CounterKind {
    case normal
    case number
    case halfhour
    case tsu
    case hifumi(digitSet: [Int])
    case daysKun
    case daysOn
    case months
    case people
    case wari
    case age
}

enum DigitOpt: Equatable {
    case g, r, h, c
    case str(String)
}

/// Arguments to construct counters (an entry of the counter cache).
struct CounterArgs {
    var kind: CounterKind
    var text: String
    var kana: String
    var source: DictText?
    var ordinalp: Bool = false
    var suffix: String? = nil
    var accepts: [String] = []
    var suffixDescriptions: [String] = []
    /// key is a digit, or nil for `:off`
    var digitOpts: [(Int?, [DigitOpt])] = []
    /// `common` slot: nil means unset; `.some(nil)` means :null
    var common: Int?? = nil
    var allowed: [Int]? = nil
    var foreign: Bool = false
}

final class CounterText: Word {
    let args: CounterArgs
    let numberText: String
    let numberValue: Int

    init(args: CounterArgs, numberText: String) throws {
        self.args = args
        self.numberText = numberText
        self.numberValue = try Numbers.parseNumber(numberText)
    }

    var kind: CounterKind { args.kind }
    var counterText: String { args.text }
    var text: String { numberText + args.text }
    var source: DictText? { args.source }
    var ordinalp: Bool { args.ordinalp }
    var seq: Int? { source?.seq }
    var ord: Int { source?.ord ?? 0 }
    var nokanji: Bool { source?.nokanji ?? false }
    var wordType: WordType { countCharClass(text, .kanjiChar) > 0 ? .kanji : .kana }

    var common: Int? {
        if let c = args.common { return c }
        return source != nil ? source!.common : 0
    }

    var allowed: [Int]? {
        switch kind {
        case .daysKun: return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 14, 20, 24, 30]
        case .months: return Array(1...12)
        default: return args.allowed
        }
    }

    var digitOpts: [(Int?, [DigitOpt])] {
        if case .months = kind { return [(4, [.str("し")]), (7, [.str("しち")]), (9, [.str("く")])] }
        return args.digitOpts
    }

    func verify(_ unique: Bool) -> Bool {
        let n = numberValue
        switch kind {
        case .tsu:
            return (1...9).contains(n) && unique
        case .daysOn:
            guard (n > 10 || n == 1) && n != 20 else { return false }
        default: break
        }
        if let allowed, !allowed.contains(n) { return false }
        return unique
    }

    func valueString() -> String {
        let value = numberValue
        switch kind {
        case .halfhour: return "\(value):30"
        case .months:
            let months = ["January", "February", "March", "April", "May", "June", "July",
                          "August", "September", "October", "November", "December"]
            return months[value - 1]
        case .wari: return "\(10 * value)%"
        default:
            var s = "Value: " + (ordinalp ? ordinalStr(value) : String(value))
            for d in args.suffixDescriptions.reversed() { s += " " + d }
            return s
        }
    }
}

func ordinalStr(_ n: Int) -> String {
    let digit = n % 10
    let teen = (11...19).contains(n % 100)
    let suffix = teen ? "th" : (digit == 1 ? "st" : digit == 2 ? "nd" : digit == 3 ? "rd" : "th")
    return "\(n)\(suffix)"
}

// MARK: - Segments

struct SegInfo {
    var posi: [String] = []
    var seqSet: [Int] = []
    var conj: [ConjData] = []
    var common: Int? = nil
    var kpcl: (k: Bool, p: Bool, c: Bool, l: Bool) = (false, false, false, false)
}

final class Segment {
    var start: Int
    var end: Int
    var word: Word
    var score: Int = 0
    var info = SegInfo()
    var text: String?

    init(start: Int, end: Int, word: Word, text: String? = nil) {
        self.start = start
        self.end = end
        self.word = word
        self.text = text
    }

    func copy() -> Segment {
        let s = Segment(start: start, end: end, word: word, text: text)
        s.score = score
        s.info = info
        return s
    }
}

final class SegmentList {
    var segments: [Segment]
    var start: Int
    var end: Int
    var top: TopArray<[PathItem]>?
    var matches: Int

    init(segments: [Segment], start: Int, end: Int, matches: Int = 0) {
        self.segments = segments
        self.start = start
        self.end = end
        self.matches = matches
    }

    func with(_ segments: [Segment]) -> SegmentList {
        let n = SegmentList(segments: segments, start: start, end: end, matches: matches)
        n.top = top
        return n
    }

    var score: Int { segments.first?.score ?? 0 }
}

struct Synergy {
    let description: String
    let connector: String
    let score: Int
    let start: Int
    let end: Int
}

enum PathItem {
    case list(SegmentList)
    case synergy(Synergy)

    var score: Int {
        switch self {
        case .list(let l): return l.score
        case .synergy(let s): return s.score
        }
    }

    var segmentList: SegmentList? {
        if case .list(let l) = self { return l }
        return nil
    }
}

final class TopArray<Payload> {
    private(set) var array: [(score: Int, payload: Payload)?]
    private(set) var count = 0

    init(limit: Int = 5) { array = Array(repeating: nil, count: limit) }

    func register(_ score: Int, _ payload: Payload) {
        let item = (score: score, payload: payload)
        let len = array.count
        var idx = min(count, len)
        while idx >= 0 {
            let prev = idx > 0 ? array[idx - 1] : nil
            let done = prev == nil || prev!.score >= score
            if idx < len { array[idx] = done ? item : prev }
            if done { break }
            idx -= 1
        }
        count += 1
    }

    var items: [(score: Int, payload: Payload)] {
        array.prefix(min(count, array.count)).compactMap { $0 }
    }
}
