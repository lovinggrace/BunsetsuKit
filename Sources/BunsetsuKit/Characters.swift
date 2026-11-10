// Port of ichiran/characters (characters.lisp)
//
// Strings are indexed by Unicode scalars throughout BunsetsuKit, mirroring
// Common Lisp's character indexing, so that offsets match ichiran's.

import Foundation

// MARK: - Scalar based string helpers

extension String {
    /// Length in Unicode scalars (the equivalent of Lisp's `length` on strings).
    @inlinable var len: Int { unicodeScalars.count }

    @inlinable var scalars: [Unicode.Scalar] { Array(unicodeScalars) }

    init<S: Sequence>(scalars: S) where S.Element == Unicode.Scalar {
        // encoding to UTF-8 first is much faster than appending to a UnicodeScalarView
        var utf8: [UInt8] = []
        utf8.reserveCapacity(scalars.underestimatedCount * 3)
        for scalar in scalars { UTF8.encode(scalar) { utf8.append($0) } }
        self = String(decoding: utf8, as: UTF8.self)
    }

    /// `subseq` by scalar offsets.
    func sub(_ start: Int, _ end: Int? = nil) -> String {
        let s = unicodeScalars
        let e = end ?? s.count
        let si = s.index(s.startIndex, offsetBy: start)
        let ei = s.index(si, offsetBy: e - start)
        return String(s[si..<ei])
    }

    /// `safe-subseq`: returns nil instead of trapping when out of bounds.
    func safeSub(_ start: Int, _ end: Int? = nil) -> String? {
        let l = len
        guard start >= 0, start <= l else { return nil }
        if let end, !(start <= end && end <= l) { return nil }
        return sub(start, end)
    }

    func scalar(at i: Int) -> Unicode.Scalar {
        let s = unicodeScalars
        return s[s.index(s.startIndex, offsetBy: i)]
    }

    var firstScalar: Unicode.Scalar? { unicodeScalars.first }
    var lastScalar: Unicode.Scalar? { unicodeScalars.last }

    func startsWith(_ c: Unicode.Scalar) -> Bool { unicodeScalars.first == c }
    func endsWith(_ c: Unicode.Scalar) -> Bool { unicodeScalars.last == c }

    func hasScalarPrefix(_ p: String) -> Bool { unicodeScalars.starts(with: p.unicodeScalars) }
    func hasScalarSuffix(_ p: String) -> Bool { unicodeScalars.reversed().starts(with: p.unicodeScalars.reversed()) }

    func containsScalar(_ c: Unicode.Scalar) -> Bool { unicodeScalars.contains(c) }

    /// Position of the first occurrence of `c` (Lisp `position`).
    func position(of c: Unicode.Scalar) -> Int? {
        var i = 0
        for x in unicodeScalars {
            if x == c { return i }
            i += 1
        }
        return nil
    }

    /// Scalar offset where `self` and `other` first differ, or nil if equal (Lisp `mismatch`).
    func mismatch(_ other: String) -> Int? {
        let a = scalars, b = other.scalars
        let n = min(a.count, b.count)
        for i in 0..<n where a[i] != b[i] { return i }
        return a.count == b.count ? nil : n
    }

    /// Lisp `search`: substring test by scalars.
    func scalarSearch(_ needle: String) -> Bool {
        if needle.isEmpty { return true }
        let h = scalars, n = needle.scalars
        if n.count > h.count { return false }
        for i in 0...(h.count - n.count) where h[i] == n[0] {
            if Array(h[i..<(i + n.count)]) == n { return true }
        }
        return false
    }
}

func join(_ separator: String, _ list: [String]) -> String { list.joined(separator: separator) }

// MARK: - Character classes

/// Character class identifiers use ichiran's keyword names (e.g. "ka", "+ya", "sokuon").
public typealias CharClassName = String

enum Characters {
    static let sokuonCharacters: [(CharClassName, String)] = [("sokuon", "っッ")]

    static let iterationCharacters: [(CharClassName, String)] = [("iter", "ゝヽ"), ("iter-v", "ゞヾ")]

    static let modifierCharacters: [(CharClassName, String)] = [
        ("+a", "ぁァ"), ("+i", "ぃィ"), ("+u", "ぅゥ"), ("+e", "ぇェ"), ("+o", "ぉォ"),
        ("+ya", "ゃャ"), ("+yu", "ゅュ"), ("+yo", "ょョ"), ("+wa", "ゎヮ"),
        ("long-vowel", "ー"),
    ]

    static let kanaCharacters: [(CharClassName, String)] = [
        ("a", "あア"), ("i", "いイ"), ("u", "うウ"), ("e", "えエ"), ("o", "おオ"),
        ("ka", "かカ"), ("ki", "きキ"), ("ku", "くク"), ("ke", "けケ"), ("ko", "こコ"),
        ("sa", "さサ"), ("shi", "しシ"), ("su", "すス"), ("se", "せセ"), ("so", "そソ"),
        ("ta", "たタ"), ("chi", "ちチ"), ("tsu", "つツ"), ("te", "てテ"), ("to", "とト"),
        ("na", "なナ"), ("ni", "にニ"), ("nu", "ぬヌ"), ("ne", "ねネ"), ("no", "のノ"),
        ("ha", "はハ"), ("hi", "ひヒ"), ("fu", "ふフ"), ("he", "へヘ"), ("ho", "ほホ"),
        ("ma", "まマ"), ("mi", "みミ"), ("mu", "むム"), ("me", "めメ"), ("mo", "もモ"),
        ("ya", "やヤ"), ("yu", "ゆユ"), ("yo", "よヨ"),
        ("ra", "らラ"), ("ri", "りリ"), ("ru", "るル"), ("re", "れレ"), ("ro", "ろロ"),
        ("wa", "わワ"), ("wi", "ゐヰ"), ("we", "ゑヱ"), ("wo", "をヲ"),
        ("n", "んン"),
        ("ga", "がガ"), ("gi", "ぎギ"), ("gu", "ぐグ"), ("ge", "げゲ"), ("go", "ごゴ"),
        ("za", "ざザ"), ("ji", "じジ"), ("zu", "ずズ"), ("ze", "ぜゼ"), ("zo", "ぞゾ"),
        ("da", "だダ"), ("dji", "ぢヂ"), ("dzu", "づヅ"), ("de", "でデ"), ("do", "どド"),
        ("ba", "ばバ"), ("bi", "びビ"), ("bu", "ぶブ"), ("be", "べベ"), ("bo", "ぼボ"),
        ("pa", "ぱパ"), ("pi", "ぴピ"), ("pu", "ぷプ"), ("pe", "ぺペ"), ("po", "ぽポ"),
        ("vu", "ゔヴ"),
    ]

    static let allCharacters: [(CharClassName, String)] =
        sokuonCharacters + iterationCharacters + modifierCharacters + kanaCharacters

    static let kanaClassSet: Set<CharClassName> = Set(kanaCharacters.map { $0.0 })
    static let modifierClassSet: Set<CharClassName> = Set(modifierCharacters.map { $0.0 })
    static let iterationClassSet: Set<CharClassName> = Set(iterationCharacters.map { $0.0 })

    /// class -> characters ("あア")
    static let charsByClass: [CharClassName: [Unicode.Scalar]] = {
        var d: [CharClassName: [Unicode.Scalar]] = [:]
        for (c, s) in allCharacters where d[c] == nil { d[c] = s.scalars }
        return d
    }()

    static let charClassHash: [Unicode.Scalar: CharClassName] = {
        var d: [Unicode.Scalar: CharClassName] = [:]
        for (c, s) in allCharacters {
            for ch in s.unicodeScalars { d[ch] = c }
        }
        return d
    }()

    static let dakutenHash: [CharClassName: CharClassName] = pairs([
        "ka", "ga", "ki", "gi", "ku", "gu", "ke", "ge", "ko", "go",
        "sa", "za", "shi", "ji", "su", "zu", "se", "ze", "so", "zo",
        "ta", "da", "chi", "dji", "tsu", "dzu", "te", "de", "to", "do",
        "ha", "ba", "hi", "bi", "fu", "bu", "he", "be", "ho", "bo",
        "u", "vu",
    ])

    static let handakutenHash: [CharClassName: CharClassName] = pairs([
        "ha", "pa", "hi", "pi", "fu", "pu", "he", "pe", "ho", "po",
    ])

    static let undakutenHash: [CharClassName: CharClassName] = pairs([
        "ga", "ka", "gi", "ki", "gu", "ku", "ge", "ke", "go", "ko",
        "za", "sa", "ji", "shi", "zu", "su", "ze", "se", "zo", "so",
        "da", "ta", "dji", "chi", "dzu", "tsu", "de", "te", "do", "to",
        "ba", "ha", "bi", "hi", "bu", "fu", "be", "he", "bo", "ho",
        "pa", "ha", "pi", "hi", "pu", "fu", "pe", "he", "po", "ho",
        "vu", "u",
    ])

    private static func pairs(_ l: [String]) -> [String: String] {
        var d: [String: String] = [:]
        var i = 0
        while i + 1 < l.count { d[l[i]] = l[i + 1]; i += 2 }
        return d
    }

    static let punctuationMarks: [(String, String)] = [
        ("【", " ["), ("】", "] "),
        ("、", ", "), ("，", ", "),
        ("。", ". "), ("・・・", "... "), ("・", " "), ("　", " "),
        ("「", " \""), ("」", "\" "), ("゛", "\""),
        ("『", " «"), ("』", "» "),
        ("〜", " - "), ("：", ": "), ("！", "! "), ("？", "? "), ("；", "; "),
    ]

    /// Joins a kana followed by a separate (han)dakuten mark into the voiced kana.
    private static func dakutenJoin(_ hash: [CharClassName: CharClassName], _ mark: Unicode.Scalar) -> [(String, String)] {
        var result: [(String, String)] = []
        // Lisp iterates the hash table; order does not matter because the keys never overlap.
        for (cc, ccd) in hash.sorted(by: { $0.key < $1.key }) {
            var kc = charsByClass[cc] ?? []
            let kcd = charsByClass[ccd] ?? []
            let offset = kc.count - kcd.count
            if offset > 0 { kc = Array(kc[offset...]) }
            for idx in 0..<kc.count {
                result.append((String(scalars: [kc[idx], mark]), String(scalars: [kcd[idx]])))
            }
        }
        return result
    }

    static let dakutenJoinMap: [(String, String)] = dakutenJoin(dakutenHash, "゛") + dakutenJoin(handakutenHash, "゜")

    static let halfWidthKana = "･ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝﾞﾟ".scalars
    static let fullWidthKana = "・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン゛゜".scalars

    static let abnormalChars = "０１２３４５６７８９ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ＃＄％＆（）＊＋／〈＝〉？＠［］＾＿‘｛｜｝～".scalars + halfWidthKana
    static let normalChars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ#$%&()*+/<=>?@[]^_`{|}~".scalars + fullWidthKana

    static let abnormalIndex: [Unicode.Scalar: Int] = indexMap(abnormalChars)
    static let halfWidthIndex: [Unicode.Scalar: Int] = indexMap(halfWidthKana)

    private static func indexMap(_ s: [Unicode.Scalar]) -> [Unicode.Scalar: Int] {
        var d: [Unicode.Scalar: Int] = [:]
        for (i, c) in s.enumerated() where d[c] == nil { d[c] = i }
        return d
    }
}

/// Result of `get-char-class`: either a class keyword or the character itself.
enum CharClassItem: Equatable {
    case cls(CharClassName)
    case char(Unicode.Scalar)

    var className: CharClassName? {
        if case .cls(let c) = self { return c }
        return nil
    }
}

func getCharClass(_ c: Unicode.Scalar) -> CharClassItem {
    if let cls = Characters.charClassHash[c] { return .cls(cls) }
    return .char(c)
}

func charClassName(_ c: Unicode.Scalar?) -> CharClassName? {
    guard let c else { return nil }
    return Characters.charClassHash[c]
}

func longVowelModifierP(_ modifier: CharClassName, _ prevChar: Unicode.Scalar) -> Bool {
    let vowels: [CharClassName: Character] = ["+a": "a", "+i": "i", "+u": "u", "+e": "e", "+o": "o"]
    guard let vowel = vowels[modifier], let cls = Characters.charClassHash[prevChar] else { return false }
    return cls.last == vowel
}

func voiceChar(_ cc: CharClassName) -> CharClassName {
    Characters.dakutenHash[cc] ?? cc
}

// MARK: - Character class predicates (the regexes of characters.lisp)

public enum CharClass: Sendable {
    case katakana, katakanaUniq, hiragana, kanji, kanjiChar, kana, traditional, nonword, number
}

@inline(__always) func isKatakanaUniq(_ c: Unicode.Scalar) -> Bool {
    let v = c.value
    return (0x30A1...0x30FA).contains(v) || v == 0x30FD || v == 0x30FE
}

@inline(__always) func isKatakana(_ c: Unicode.Scalar) -> Bool { isKatakanaUniq(c) || c.value == 0x30FC }

@inline(__always) func isHiragana(_ c: Unicode.Scalar) -> Bool {
    let v = c.value
    return (0x3041...0x3094).contains(v) || v == 0x309D || v == 0x309E || v == 0x30FC
}

@inline(__always) func isKanjiChar(_ c: Unicode.Scalar) -> Bool { (0x4E00...0x9FAF).contains(c.value) }

@inline(__always) func isKanji(_ c: Unicode.Scalar) -> Bool {
    let v = c.value
    return v == 0x3005 || v == 0x30F6 || v == 0x3006 || isKanjiChar(c)
}

@inline(__always) func isWordChar(_ c: Unicode.Scalar) -> Bool {
    isKanji(c) || isKatakanaUniq(c) || isHiragana(c) || c.value == 0x3007
}

private let numericChars: Set<Unicode.Scalar> = Set("0123456789０１２３４５６７８９〇一二三四五六七八九零壱弐参拾十百千万億兆京".unicodeScalars)

@inline(__always) func isNumericChar(_ c: Unicode.Scalar) -> Bool { numericChars.contains(c) }

@inline(__always) func isDigitChar(_ c: Unicode.Scalar) -> Bool {
    let v = c.value
    return (0x30...0x39).contains(v) || (0xFF10...0xFF19).contains(v) || v == 0x3007
}

@inline(__always) func isNumWordChar(_ c: Unicode.Scalar) -> Bool { isWordChar(c) || isDigitChar(c) }

func charMatches(_ c: Unicode.Scalar, _ cls: CharClass) -> Bool {
    switch cls {
    case .katakana: return isKatakana(c)
    case .katakanaUniq: return isKatakanaUniq(c)
    case .hiragana: return isHiragana(c)
    case .kanji: return isKanji(c)
    case .kanjiChar: return isKanjiChar(c)
    case .kana: return isKatakana(c) || isHiragana(c)
    case .traditional: return isHiragana(c) || isKanji(c)
    case .nonword: return !isWordChar(c)
    case .number: return isNumericChar(c)
    }
}

/// `test-word`: the whole (non-empty) word consists of characters of the class.
public func testWord(_ word: String, _ cls: CharClass) -> Bool {
    if word.isEmpty { return false }
    return word.unicodeScalars.allSatisfy { charMatches($0, cls) }
}

func countCharClass(_ word: String, _ cls: CharClass) -> Int {
    word.unicodeScalars.reduce(0) { $0 + (charMatches($1, cls) ? 1 : 0) }
}

func collectCharClass(_ word: String, _ cls: CharClass) -> [String] {
    word.unicodeScalars.filter { charMatches($0, cls) }.map { String($0) }
}

/// Positions between two sequential kanji (excluding ヶ〆).
func sequentialKanjiPositions(_ word: String, offset: Int = 0) -> [Int] {
    let s = word.scalars
    var positions: [Int] = []
    if s.count < 2 { return positions }
    func k(_ c: Unicode.Scalar) -> Bool { c.value == 0x3005 || isKanjiChar(c) }
    for i in 0..<(s.count - 1) where k(s[i]) && k(s[i + 1]) {
        positions.append(i + 1 + offset)
    }
    return positions
}

/// SQL LIKE mask for word: every run of kanji becomes %.
func kanjiMask(_ word: String) -> String {
    var out = String.UnicodeScalarView()
    var inKanji = false
    for c in word.unicodeScalars {
        if isKanji(c) {
            if !inKanji { out.append("%") }
            inKanji = true
        } else {
            out.append(c)
            inKanji = false
        }
    }
    return String(out)
}

/// Matcher equivalent to `kanji-regex`: kanji runs match one or more arbitrary characters.
struct KanjiPattern {
    enum Part { case lit(Unicode.Scalar), any }
    let parts: [Part]

    init(_ word: String) {
        parts = kanjiMask(word).unicodeScalars.map { $0 == "%" ? .any : .lit($0) }
    }

    func matches(_ str: String) -> Bool {
        let s = str.scalars
        // memoized backtracking
        var memo = [Int: Bool]()
        func go(_ pi: Int, _ si: Int) -> Bool {
            let key = pi * (s.count + 1) + si
            if let m = memo[key] { return m }
            var r = false
            if pi == parts.count {
                r = si == s.count
            } else {
                switch parts[pi] {
                case .lit(let c):
                    r = si < s.count && s[si] == c && go(pi + 1, si + 1)
                case .any:
                    var j = si + 1
                    while j <= s.count {
                        if go(pi + 1, j) { r = true; break }
                        j += 1
                    }
                }
            }
            memo[key] = r
            return r
        }
        return go(0, 0)
    }
}

func kanjiMatch(_ word: String, _ reading: String) -> Bool {
    KanjiPattern(word).matches(reading)
}

func kanjiCrossMatch(_ word: String, _ reading: String, _ newWord: String) -> String? {
    guard let m = word.mismatch(newWord) else { return nil }
    let rCut = m + (reading.len - word.len)
    if m > 0, rCut >= 0, rCut <= reading.len {
        return reading.sub(0, rCut) + newWord.sub(m)
    }
    return nil
}

/// `simplify-ngrams`: replaces the leftmost occurrences, trying alternatives in order.
func simplifyNgrams(_ str: String, _ map: [(String, String)]) -> String {
    if map.isEmpty { return str }
    let s = str.scalars
    let alts = map.map { ($0.0.scalars, $0.1) }
    var out = ""
    var i = 0
    outer: while i < s.count {
        for (from, to) in alts where !from.isEmpty && i + from.count <= s.count {
            var ok = true
            for j in 0..<from.count where s[i + j] != from[j] { ok = false; break }
            if ok {
                out += to
                i += from.count
                continue outer
            }
        }
        out.unicodeScalars.append(s[i])
        i += 1
    }
    return out
}

enum NormalizeContext { case kana, other }

func toNormalChar(_ c: Unicode.Scalar, context: NormalizeContext = .other) -> Unicode.Scalar? {
    if context == .kana {
        if let p = Characters.halfWidthIndex[c] { return Characters.fullWidthKana[p] }
        return nil
    }
    if let p = Characters.abnormalIndex[c] { return Characters.normalChars[p] }
    return nil
}

func normalize(_ str: String, context: NormalizeContext = .other) -> String {
    let mapped = String(scalars: str.unicodeScalars.map { toNormalChar($0, context: context) ?? $0 })
    return simplifyNgrams(mapped, context == .kana ? Characters.dakutenJoinMap
                                                   : Characters.punctuationMarks + Characters.dakutenJoinMap)
}

public enum SplitType: Sendable { case word, misc }

/// `basic-split`: splits string into segments of Japanese and misc characters.
func basicSplit(_ str: String) -> [(SplitType, String)] {
    let s = str.scalars
    var pieces: [String] = []
    var last = 0
    var i = 0
    // Emulates the regex ((?:(?<![.,]|DIGIT)DIGIT+|WORD)NUMWORD*WORD|WORD)
    func matchAt(_ start: Int) -> Int? {
        var ends: [Int] = []
        // first alternative head
        var heads: [Int] = []
        let prevOK: Bool = {
            if start == 0 { return true }
            let p = s[start - 1]
            return !(p == "." || p == "," || isDigitChar(p))
        }()
        if prevOK, isDigitChar(s[start]) {
            var j = start
            while j < s.count, isDigitChar(s[j]) { j += 1 }
            heads.append(contentsOf: stride(from: j, to: start, by: -1)) // greedy, backtracking order
        }
        if isWordChar(s[start]) { heads.append(start + 1) }
        for h in heads {
            // NUMWORD* WORD, greedy with backtracking: find the longest run, then last word char inside it
            var j = h
            while j < s.count, isNumWordChar(s[j]) { j += 1 }
            var k = j
            while k > h {
                if isWordChar(s[k - 1]) { ends.append(k); break }
                k -= 1
            }
            if !ends.isEmpty { return ends[0] }
        }
        if isWordChar(s[start]) { return start + 1 }
        return nil
    }
    while i < s.count {
        if let e = matchAt(i) {
            pieces.append(String(scalars: s[last..<i]))
            pieces.append(String(scalars: s[i..<e]))
            last = e
            i = e
        } else {
            i += 1
        }
    }
    pieces.append(String(scalars: s[last..<s.count]))
    pieces = pieces.filter { !$0.isEmpty }
    var result: [(SplitType, String)] = []
    var misc = false
    for (idx, seg) in pieces.enumerated() {
        misc = idx == 0 ? testWord(seg, .nonword) : !misc
        result.append((misc ? .misc : .word, seg))
    }
    return result
}

private let moraModifiers: Set<Unicode.Scalar> = Set("っッぁァぃィぅゥぇェぉォゃャゅュょョー".unicodeScalars)

/// Like length but doesn't count modifier characters.
func moraLength(_ str: String) -> Int {
    str.unicodeScalars.reduce(0) { $0 + (moraModifiers.contains($1) ? 0 : 1) }
}

/// Converts katakana to hiragana.
public func asHiragana(_ str: String) -> String {
    String(scalars: str.unicodeScalars.map { c in
        let c = toNormalChar(c) ?? c
        if let cls = Characters.charClassHash[c], let chars = Characters.charsByClass[cls] { return chars[0] }
        return c
    })
}

/// Converts hiragana to katakana.
public func asKatakana(_ str: String) -> String {
    String(scalars: str.unicodeScalars.map { c in
        let c = toNormalChar(c) ?? c
        if let cls = Characters.charClassHash[c], let chars = Characters.charsByClass[cls] { return chars[chars.count - 1] }
        return c
    })
}

/// Ranges (start, end) of consecutive characters of a class.
func consecutiveCharGroups(_ cls: CharClass, _ str: String) -> [(Int, Int)] {
    let s = str.scalars
    var result: [(Int, Int)] = []
    var i = 0
    while i < s.count {
        if charMatches(s[i], cls) {
            let st = i
            while i < s.count, charMatches(s[i], cls) { i += 1 }
            result.append((st, i))
        } else {
            i += 1
        }
    }
    return result
}

/// Everything up to and including the last kanji.
func kanjiPrefix(_ word: String) -> String {
    let s = word.scalars
    guard let idx = s.lastIndex(where: isKanji) else { return "" }
    return String(scalars: s[0...idx])
}

private func replaceFirst(_ txt: String, using hash: [CharClassName: CharClassName]) -> String {
    let s = txt.scalars
    guard let first = s.first, let cc = Characters.charClassHash[first], let to = hash[cc],
          let from = Characters.charsByClass[cc], let pos = from.firstIndex(of: first),
          let target = Characters.charsByClass[to] else { return txt }
    var r = s
    r[0] = target[pos]
    return String(scalars: r)
}

func unrendaku(_ txt: String) -> String { replaceFirst(txt, using: Characters.undakutenHash) }

func rendaku(_ txt: String, handakuten: Bool = false) -> String {
    replaceFirst(txt, using: handakuten ? Characters.handakutenHash : Characters.dakutenHash)
}

func geminate(_ txt: String) -> String {
    var s = txt.scalars
    if s.isEmpty { return txt }
    s[s.count - 1] = "っ"
    return String(scalars: s)
}

/// Removes `stem` characters of char-class + whatever else gets in the way from the end of `word`.
func destem(_ word: String, _ stem: Int, _ cls: CharClass = .kana) -> String {
    if stem == 0 { return word }
    let s = word.scalars
    var positions: [Int] = []
    for (i, c) in s.enumerated() where charMatches(c, cls) { positions.append(i) }
    positions.reverse()
    if stem - 1 < positions.count { return String(scalars: s[0..<positions[stem - 1]]) }
    return ""
}

/// Element of a `match-diff` / `match-readings` result: either a shared part or a pair of differing parts.
enum DiffPart: Equatable {
    case same(String)
    case diff(String, String)
}

/// Match strings s1 and s2 optimally.
func matchDiff(_ s1: String, _ s2: String) -> (parts: [DiffPart], value: Int)? {
    let l1 = s1.len, l2 = s2.len
    if l1 == 0 || l2 == 0 { return nil }
    guard let m = s1.mismatch(s2) else { return ([.same(s1)], l1) }
    if l1 == 1 || l2 == 1 { return ([.diff(s1, s2)], 0) }
    if m == 0 {
        var best: [DiffPart]? = nil
        var bestValue: Int? = nil
        let a = s1.scalars, b = s2.scalars
        for i in 1..<a.count {
            for j in 1..<b.count where a[i] == b[j] {
                if let (match, value) = matchDiff(s1.sub(i), s2.sub(j)), bestValue == nil || value > bestValue! {
                    best = [.diff(s1.sub(0, i), s2.sub(0, j))] + match
                    bestValue = value
                }
            }
        }
        if let best, let bestValue { return (best, bestValue) }
        return nil
    }
    if m == l1 {
        return ([.same(s1.sub(0, l1 - 1)), .diff(s1.sub(l1 - 1), s2.sub(l1 - 1))], l1 - 1)
    }
    if m == l2 {
        return ([.same(s2.sub(0, l2 - 1)), .diff(s1.sub(l2 - 1), s2.sub(l2 - 1))], l2 - 1)
    }
    if let (match, value) = matchDiff(s1.sub(m), s2.sub(m)) {
        return ([.same(s1.sub(0, m))] + match, value + m)
    }
    return nil
}
