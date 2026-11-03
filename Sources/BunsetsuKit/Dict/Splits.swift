// Port of the split and hint machinery of dict-split.lisp (definitions are in Generated/)

import Foundation

// MARK: - Splits

struct SplitCtx {
    let len: Int
    let txt: String
    let wordType: WordType
}

enum SplitSeqs {
    case seqs([Int])
    /// the seq of the first word found by find-word-conj-of
    case lookup(String, [Int])
}

enum SplitModify {
    case none, unrendaku
    case optprefix(String)

    func apply(_ s: String) -> String {
        switch self {
        case .none: return s
        case .unrendaku: return unrendaku(s)
        case .optprefix(let p): return s.hasScalarPrefix(p) ? s : p + s
        }
    }
}

enum SplitMarker { case score, pscore }

enum SplitStep {
    case part(SplitSeqs, length: ((SplitCtx) -> Int?)?, conj: Bool, modify: SplitModify)
    case test((SplitCtx) -> Bool, newScore: Int?, marker: SplitMarker?)
    case marker(SplitMarker)
}

enum SplitScore {
    case score(Int)
    /// segsplit attributes: (score &key primary connector root)
    case attrs(score: Int, primary: Int, connector: String, root: [Int])

    var score: Int {
        switch self {
        case .score(let s): return s
        case .attrs(let s, _, _, _): return s
        }
    }
}

struct SplitDef {
    let seq: Int
    let score: SplitScore
    let steps: [SplitStep]
}

struct SplitResult {
    var parts: [Word] = []
    var hasScore = false
    var hasPscore = false
    var score: Int
    var attrs: SplitScore
}

let splitMap: [Int: SplitDef] = Dictionary(splitDefs.map { ($0.seq, $0) }, uniquingKeysWith: { _, b in b })
let segsplitMap: [Int: SplitDef] = Dictionary(segsplitDefs.map { ($0.seq, $0) }, uniquingKeysWith: { _, b in b })

extension Ichiran {
    /// Runs a `def-simple-split`; nil parts are missing words.
    func runSplit(_ def: SplitDef, _ reading: SimpleText) -> (parts: [Word?], hasScore: Bool, hasPscore: Bool, score: SplitScore) {
        let text = reading.trueText
        let ctx = SplitCtx(len: text.len, txt: text, wordType: reading.wordType)
        var offset = 0
        var parts: [Word?] = []
        var hasScore = false, hasPscore = false
        var score = def.score
        func mark(_ m: SplitMarker) { if m == .score { hasScore = true } else { hasPscore = true } }
        loop: for step in def.steps {
            switch step {
            case .test(let test, let newScore, let marker):
                if !test(ctx) {
                    if let newScore { score = .score(newScore) }
                    if let marker { mark(marker) }
                    break loop
                }
            case .marker(let m):
                mark(m)
            case .part(let seqSpec, let lengthFn, let conj, let modify):
                var pseq: [Int]? = nil
                switch seqSpec {
                case .seqs(let s): pseq = s
                case .lookup(let w, let s): pseq = findWordConjOf(w, s).first.map { [$0.seq] }
                }
                let partLength = lengthFn.flatMap { $0(ctx) }
                let partTxt = text.safeSub(offset, partLength.map { offset + $0 })
                var word: Word? = nil
                if let pseq, !pseq.contains(def.seq), let partTxt {
                    let t = modify.apply(partTxt)
                    word = (conj ? findWordConjOf(t, pseq) : findWordSeq(t, pseq)).first
                }
                parts.append(word)
                if let partLength { offset += partLength }
            }
        }
        return (parts, hasScore, hasPscore, score)
    }

    func getSplitStar(_ reading: SimpleText, _ conjOf: [Int], map: [Int: SplitDef]) -> SplitResult? {
        var def = map[reading.seq]
        if def == nil {
            for seq in conjOf {
                if let d = map[seq] { def = d; break }
            }
        }
        guard let def else { return nil }
        let r = runSplit(def, reading)
        // safety check if one of split words is missing
        guard r.parts.allSatisfy({ $0 != nil }) else { return nil }
        if r.parts.isEmpty && !r.hasScore && !r.hasPscore { return nil }
        return SplitResult(parts: r.parts.map { $0! }, hasScore: r.hasScore, hasPscore: r.hasPscore,
                           score: r.score.score, attrs: r.score)
    }

    /// `get-split`
    func getSplit(_ reading: SimpleText, _ conjOf: [Int] = []) -> SplitResult? {
        getSplitStar(reading, conjOf, map: splitMap)
    }

    /// `get-segsplit`: expands one segment into several, e.g. "ところが" -> "ところ+が"
    func getSegsplit(_ segment: Segment) -> Segment? {
        guard let word = segment.word as? SimpleText else { return nil }
        guard let split = getSplitStar(word, Array(segment.info.seqSet.dropFirst()), map: segsplitMap),
              !split.parts.isEmpty,
              case .attrs(let score, let primary, let connector, let root) = split.attrs else { return nil }
        let parts = split.parts
        let compound = CompoundText(text: parts.map(getText).joined(),
                                    kana: parts.map(getKana).joined(separator: connector),
                                    primary: parts[primary], words: parts, scoreMod: .int(score))
        let newSeg = segment.copy()
        for (i, w) in parts.enumerated() where root.contains(i) { setConjugations(w, .root) }
        newSeg.word = compound
        newSeg.text = compound.text
        newSeg.score = segment.score + score
        newSeg.info = calcScore(compound.primary).info ?? SegInfo()
        newSeg.info.conj = wordConjData(compound)
        return newSeg
    }
}

// MARK: - Kana hints (indicate when to romanize は as わ etc.)

let kanaHintMod: Unicode.Scalar = "\u{200C}"
let kanaHintSpace: Unicode.Scalar = "\u{200B}"

enum HintChar {
    case space, mod

    var scalar: Unicode.Scalar { self == .space ? kanaHintSpace : kanaHintMod }
}

typealias HintList = [(HintChar, Int)]

enum HintDef {
    case simple((Int, String) -> HintList?)
    case easy(String)
}

let hintSimplifyMap: [(String, String)] = [
    (String(kanaHintSpace), " "),
    (String(scalars: [kanaHintMod, "は"]), "わ"),
    (String(scalars: [kanaHintMod, "ハ"]), "ワ"),
    (String(scalars: [kanaHintMod, "へ"]), "え"),
    (String(scalars: [kanaHintMod, "ヘ"]), "エ"),
    (String(kanaHintMod), ""),
]

/// Applies kana hints (the hint characters are replaced by their effect).
public func processHints(_ word: String) -> String { simplifyNgrams(word, hintSimplifyMap) }

/// Removes kana hint characters.
public func stripHints(_ word: String) -> String {
    String(scalars: word.unicodeScalars.filter { $0 != kanaHintMod && $0 != kanaHintSpace })
}

func insertHints(_ str: String, _ hints: HintList) -> String {
    if hints.isEmpty { return str }
    let s = str.scalars
    var positions = Array(repeating: [Unicode.Scalar](), count: s.count + 1)
    for (h, pos) in hints where pos >= 0 && pos <= s.count {
        positions[pos].append(h.scalar)
    }
    var out = String.UnicodeScalarView()
    for i in 0...s.count {
        out.append(contentsOf: positions[i])
        if i < s.count { out.append(s[i]) }
    }
    return String(out)
}

func translateHintPosition(_ match: [DiffPart], _ position: Int) -> Int? {
    var off = 0, rem = position
    for part in match {
        switch part {
        case .same(let s):
            let len = s.len
            if rem <= len { return off + rem }
            rem -= len
            off += len
        case .diff(let a, let b):
            let len = a.len, clen = b.len
            if rem < len { return off + min(1, max(clen, rem)) }
            if rem == len { return off + clen }
            rem -= len
            off += clen
        }
    }
    return nil
}

func translateHints(_ match: [DiffPart], _ hints: HintList) -> HintList {
    hints.compactMap { (h, pos) in translateHintPosition(match, pos).map { (h, $0) } }
}

/// Hint positions of a def-easy-hint text ("郷 に 入って は 郷 に 従え")
func easyHintPositions(_ kanjiSplit: String) -> (text: String, hints: HintList) {
    let parts = kanjiSplit.components(separatedBy: " ")
    var hints: HintList = []
    var pos = 0
    for part in parts {
        if pos != 0 {
            hints.append((.space, pos))
            if ["は", "へ", "には", "とは"].contains(part) { hints.append((.mod, pos + part.len - 1)) }
        }
        pos += part.len
    }
    return (parts.joined(), hints)
}

let hintMap: [Int: HintDef] = {
    var d: [Int: HintDef] = [:]
    for (seqs, def) in hintDefs {
        for s in seqs { d[s] = def }
    }
    return d
}()

extension String {
    /// Lisp `search` returning the scalar position.
    func searchPos(_ needle: String, fromEnd: Bool = false) -> Int? {
        let h = scalars, n = needle.scalars
        guard n.count <= h.count else { return nil }
        let range = Array(0...(h.count - n.count))
        for i in (fromEnd ? range.reversed() : range) where Array(h[i..<(i + n.count)]) == n {
            return i
        }
        return nil
    }
}

extension Ichiran {
    func runHint(_ def: HintDef, _ reading: SimpleText) -> String? {
        switch def {
        case .simple(let fn):
            let kana = trueKana(reading)
            guard let hints = fn(kana.len, kana) else { return nil }
            return insertHints(getKana(reading), hints)
        case .easy(let kanjiSplit):
            guard let rtext = trueKanji(reading) else { return nil }
            let (text, hints) = easyHintPositions(kanjiSplit)
            guard let match = matchDiff(text, rtext)?.parts,
                  let kr = matchReadings(rtext, trueKana(reading)) else { return nil }
            return insertHints(getKana(reading), translateHints(kr, translateHints(match, hints)))
        }
    }

    /// `get-hint`
    func getHint(_ reading: SimpleText) -> String? {
        if let def = hintMap[reading.seq] { return runHint(def, reading) }
        for cd in wordConjData(reading) {
            if let def = hintMap[cd.from] { return runHint(def, reading) }
        }
        return nil
    }
}
