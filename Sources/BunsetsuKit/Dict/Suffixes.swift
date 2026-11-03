// Port of the suffix part of dict-grammar.lisp

import Foundation

struct SuffixVal {
    let key: String
    let kf: DictText?
}

struct SuffixMatch {
    let substr: String
    let key: String
    let kf: DictText?
}

/// An element of a primary word list: a word with an optional score base (see pair-words-by-conj)
struct PrimaryWord {
    let word: Word
    let scoreBase: Word?
    init(_ word: Word, scoreBase: Word? = nil) { self.word = word; self.scoreBase = scoreBase }
}

typealias SuffixFn = (Ichiran, String, String, DictText?) -> [Word]

enum SuffixUnique {
    case always
    case test((Ichiran, [Word]) -> Bool)
}

let suffixDescription: [String: String] = [
    "chau": "indicates completion (to finish ...)",
    "ha": "topic marker particle",
    "tai": "want to... / would like to...",
    "iru": "indicates continuing action (to be ...ing)",
    "oru": "indicates continuing action (to be ...ing) (humble)",
    "aru": "indicates completion / finished action",
    "kuru": "indicates action that had been continuing up till now / came to be ",
    "oku": "to do in advance / to leave in the current state expecting a later change",
    "kureru": "(asking) to do something for one",
    "morau": "(asking) to get somebody to do something",
    "itadaku": "(asking) to get somebody to do something (polite)",
    "iku": "is becoming / action starting now and continuing",
    "suru": "makes a verb from a noun",
    "itasu": "makes a verb from a noun (humble)",
    "sareru": "makes a verb from a noun (honorific or passive)",
    "saseru": "let/make someone/something do ...",
    "rou": "probably / it seems that... / I guess ...",
    "ii": "it's ok if ... / is it ok if ...?",
    "mo": "even if ...",
    "sugiru": "to be too (much) ...",
    "nikui": "difficult to...",
    "gatai": "difficult to...",
    "sa": "-ness (degree or condition of adjective)",
    "tsutsu": "while ... / in the process of ...",
    "tsutsuaru": "to be doing ... / to be in the process of doing ...",
    "uru": "can ... / to be able to ...",
    "sou": "looking like ... / seeming ...",
    "nai": "negative suffix",
    "ra": "pluralizing suffix (not polite)",
    "kudasai": "please do ...",
    "yagaru": "indicates disdain or contempt",
    "naru": "to become ...",
    "desu": "formal copula",
    "desho": "it seems/perhaps/don't you think?",
    "tosuru": "to try to .../to be about to...",
    "garu": "to feel .../have a ... impression of someone",
    "me": "somewhat/-ish",
    "gai": "worth it to ...",
    "tasou": "seem to want to... (tai+sou)",
    // these are used for splitsegs
    "2826528": "polite prefix", // お
    "2028980": "at / in / by", // で
    "2028970": "or / questioning particle", // か
    "2028990": "to / at / in", // に
    "2029010": "indicates direct object of action", // を
    "1469800": "indicates possessive (...'s)",
    "2086960": "quoting particle",
    "1002980": "from / because",
]

extension Ichiran {
    func getSuffixDescription(_ seq: Int?) -> String? {
        guard let seq else { return nil }
        return suffixDescription[suffixClass[seq] ?? String(seq)]
    }

    // MARK: kana forms

    func getKanaFormsStar(_ seq: Int) -> [DictText] {
        let rows = db.query("""
            SELECT \(ReadingRow.select(.kana, alias: "kt")) FROM kana_text kt WHERE kt.seq = ?
            UNION
            SELECT \(ReadingRow.select(.kana, alias: "kt")) FROM kana_text kt
            LEFT JOIN conjugation conj ON conj.seq = kt.seq WHERE conj."from" = ?
            ORDER BY 1
            """, [seq, seq]).map { DictText(ReadingRow(table: .kana, row: $0)) }
        var result: [DictText] = []
        for kt in rows {
            if kt.seq == seq {
                kt.conjugations = .root
                result.append(kt)
            } else {
                let cd = getConjData(kt.seq, .from(seq))
                if !Errata.skipByConjData(cd) {
                    let ids = cd.filter { !Errata.testConjProp($0.prop, Errata.weakConjForms) }.map(\.prop.conjId)
                    if !ids.isEmpty {
                        kt.conjugations = .ids(ids)
                        result.append(kt)
                    }
                }
            }
        }
        return result
    }

    func getKanaForms(_ seq: Int) -> [DictText] { getKanaFormsStar(seq) }

    func getKanaForm(_ seq: Int, _ text: String, conj: Conjugations? = nil) -> DictText? {
        let res = words(.kana, where: "text = ? AND seq = ?", [text, seq]).first
        if let res, let conj { res.conjugations = conj }
        return res
    }

    /// `find-word-with-conj-prop`
    func findWordWithConjProp(_ wordstr: String, allowRoot: Bool = false, _ filter: (ConjData) -> Bool) -> [Word] {
        var result: [Word] = []
        for word in findWordFull(wordstr) {
            let conjData = wordConjData(word)
            let filtered = conjData.filter(filter)
            if !filtered.isEmpty || (conjData.isEmpty && allowRoot) {
                setConjugations(word, .list(filtered.map(\.prop.conjId)))
                result.append(word)
            }
        }
        return result
    }

    func findWordWithConjType(_ word: String, _ types: Int...) -> [Word] {
        findWordWithConjProp(word) { types.contains($0.prop.conjType) }
    }

    func pairWordsByConj(_ groups: [[Word]]) -> [[Word?]] {
        func key(_ w: Word) -> [[Int]] {
            conjugations(w).ids.compactMap { id -> [Int]? in
                guard let c = conjugation(id) else { return nil }
                return [c.from, c.via ?? 0]
            }.sorted { $0.lexicographicallyPrecedes($1) }
        }
        var bag: [[[Int]]: [Word?]] = [:]
        var order: [[[Int]]] = []
        for (idx, wg) in groups.enumerated() {
            for w in wg {
                let k = key(w)
                var arr = bag[k] ?? { order.append(k); return Array(repeating: nil, count: groups.count) }()
                arr[idx] = w
                bag[k] = arr
            }
        }
        return order.map { bag[$0]! }
    }

    func orAsHiragana(_ fn: (String) -> [Word], _ word: String) -> [Word] {
        let r = fn(word)
        return r.isEmpty ? findWordAsHiragana(word, finder: fn) : r
    }

    func findWordWithSuffix(_ wordstr: String, _ classes: [String]) -> [Word] {
        findWordFull(wordstr).filter { w in
            guard let seqs = seqList(w), let last = seqs.last, let cls = suffixClass[last] else { return false }
            return classes.contains(cls)
        }
    }

    // MARK: init-suffixes

    func initSuffixes() {
        if suffixCache != nil { return }
        var cache: [String: [SuffixVal]] = [:]
        suffixClass = [:]

        func update(_ text: String, _ new: SuffixVal, join: Bool = false) {
            if let old = cache[text], join {
                cache[text] = [new] + old
            } else {
                cache[text] = [new]
            }
        }
        func loadKf(_ key: String, _ kf: DictText?, cls: String? = nil, text: String? = nil, join: Bool = false) {
            guard let kf else { return }
            update(text ?? kf.text, SuffixVal(key: key, kf: kf), join: join)
            suffixClass[kf.seq] = cls ?? key
        }
        func loadConjs(_ key: String, _ seq: Int, _ cls: String? = nil, join: Bool = false) {
            for kf in getKanaForms(seq) { loadKf(key, kf, cls: cls, join: join) }
        }
        func loadAbbr(_ key: String, _ text: String, join: Bool = false) {
            update(text, SuffixVal(key: key, kf: nil), join: join)
        }

        loadConjs("chau", 2013800) // ちゃう
        loadConjs("chau", 2210750) // ちまう
        loadKf("chau", getKanaForm(2028920, "は"), cls: "ha", text: "ちゃ")
        loadKf("chau", getKanaForm(2028920, "は"), cls: "ha", text: "じゃ")

        loadConjs("tai", 2017560)

        // because suffix た is used up by いる this combination cannot occur, so I add it separately
        loadKf("tai", getKanaForm(900000, "たそう"), cls: "tasou")

        loadConjs("ren-", 2772730, "nikui")
        loadConjs("ren-", 2867504, "gatai")

        loadConjs("te", 1577985, "oru") // おる

        loadConjs("te", 1296400, "aru") // ある

        for kf in getKanaForms(1577980) { // いる (る)
            let tkf = kf.text
            cache[tkf] = [SuffixVal(key: tkf.len > 1 ? "teiru+" : "teiru", kf: kf)]
            suffixClass[kf.seq] = "iru"
            if tkf.len > 1 { cache[tkf.sub(1)] = [SuffixVal(key: "teiru", kf: kf)] }
        }

        loadConjs("te", 1547720, "kuru") // くる

        loadConjs("te", 1421850, "oku") // おく
        loadConjs("to", 2108590, "oku") // とく

        loadConjs("te", 1305380, "chau") // しまう

        loadConjs("te+space", 1269130, "kureru") // くれる
        loadConjs("te+space", 1535910, "morau") // もらう
        loadConjs("te+space", 1587290, "itadaku") // いただく

        for kf in getKanaForms(1578850) { // いく / く
            let tkf = kf.text
            let val = SuffixVal(key: "te", kf: kf)
            if tkf.startsWith("い") {
                cache[tkf] = [val]
                suffixClass[kf.seq] = "iku"
                let short = tkf.sub(1)
                if cache[short] == nil { cache[short] = [val] }
            }
        }

        loadKf("teii", getKanaForm(2820690, "いい"), cls: "ii")
        loadKf("teii", getKanaForm(900001, "もいい"), cls: "ii", text: "もいい")
        loadKf("te", getKanaForm(2028940, "も"), cls: "mo")

        loadKf("kudasai", getKanaForm(1184270, "ください", conj: .root))

        loadConjs("suru", 1157170) // する
        loadConjs("suru", 1421900, "itasu") // いたす
        // because suru isn't conjugated twice, this is added separately
        loadConjs("suru", 2269820, "sareru") // される
        loadConjs("suru", 1005160, "saseru") // させる

        loadConjs("sou", 1006610) // そう
        loadConjs("sou+", 2141080) // そうにない

        loadKf("rou", getKanaForm(1928670, "だろう"), text: "ろう")

        loadConjs("sugiru", 1195970) // すぎる

        loadKf("sa", getKanaForm(2029120, "さ"))

        loadKf("ren", getKanaForm(1008120, "つつ"), cls: "tsutsu")
        loadConjs("ren", 2027910, "tsutsuaru")

        loadKf("ren", getKanaForm(1454500, "うる"), cls: "uru")
        loadKf("neg", findWordConjOf("なく", [1529520]).first, cls: "nai")

        loadConjs("adv", 1375610, "naru") // なる

        loadConjs("teren", 1012740, "yagaru")

        loadKf("ra", getKanaForm(2067770, "ら"))

        loadConjs("rashii", 1013240) // らしい

        loadKf("desu", getKanaForm(1628500, "です"))

        loadKf("desho", getKanaForm(1008420, "でしょう"))
        loadKf("desho", getKanaForm(1008420, "でしょ"))

        loadConjs("tosuru", 2136890) // とする

        loadKf("kurai", getKanaForm(1154340, "くらい"))
        loadKf("kurai", getKanaForm(1154340, "ぐらい"))

        loadConjs("garu", 1631750) // がる

        loadKf("ren", getKanaForm(2016470, "がち"), cls: "gachi")

        loadKf("iadj", getKanaForm(2006580, "げ"))
        loadKf("iadj", getKanaForm(1604890, "め"), cls: "me")

        loadKf("ren-", getKanaForm(2606690, "がい"), cls: "gai")

        loadAbbr("nai", "ねえ")
        loadAbbr("nai", "ねぇ")
        loadAbbr("nai", "ねー")
        loadAbbr("nai-x", "ず")
        loadAbbr("nai-x", "ざる")
        loadAbbr("nai-x", "ぬ")
        loadAbbr("nai-n", "ん")

        loadAbbr("nakereba", "なきゃ")
        loadAbbr("nakereba", "なくちゃ")
        loadAbbr("nakereba", "ねば")

        loadAbbr("teba", "ちゃ", join: true) // つ
        loadAbbr("reba", "りゃ") // る
        loadAbbr("keba", "きゃ") // く
        loadAbbr("geba", "ぎゃ") // ぐ
        loadAbbr("neba", "にゃ") // ぬ
        loadAbbr("beba", "びゃ") // ぶ
        loadAbbr("meba", "みゃ") // む
        loadAbbr("seba", "しゃ") // す

        loadAbbr("shimashou", "しましょ")
        loadAbbr("dewanai", "じゃない")

        loadAbbr("ii", "ええ")

        suffixCache = cache
    }

    // MARK: suffix map

    func parseSuffixVal(_ substr: String, _ vals: [SuffixVal]?) -> [SuffixMatch] {
        (vals ?? []).map { SuffixMatch(substr: substr, key: $0.key, kf: $0.kf) }
    }

    func getSuffixMap(_ str: String) -> [Int: [SuffixMatch]] {
        initSuffixes()
        var result: [Int: [SuffixMatch]] = [:]
        let s = str.scalars
        for start in 0..<s.count {
            for end in (start + 1)...s.count {
                let substr = String(scalars: s[start..<end])
                for item in parseSuffixVal(substr, suffixCache![substr]) {
                    result[end, default: []].insert(item, at: 0)
                }
            }
        }
        return result
    }

    func getSuffixes(_ word: String) -> [SuffixMatch] {
        initSuffixes()
        let s = word.scalars
        guard s.count > 1 else { return [] }
        var result: [SuffixMatch] = []
        for start in stride(from: s.count - 1, through: 1, by: -1) {
            let substr = String(scalars: s[start...])
            result += parseSuffixVal(substr, suffixCache![substr])
        }
        return result
    }

    func matchUnique(_ suffixClass: String?, _ matches: [Word]) -> Bool {
        guard let suffixClass, let u = suffixUniqueOnly[suffixClass] else { return false }
        switch u {
        case .always: return true
        case .test(let f): return f(self, matches)
        }
    }

    /// `find-word-suffix`
    func findWordSuffix(_ word: String, matches: [Word] = []) -> [Word] {
        let suffixes: [SuffixMatch]
        if let map = suffixMapTemp {
            suffixes = suffixNextEnd.flatMap { map[$0] } ?? []
        } else {
            suffixes = getSuffixes(word)
        }
        var result: [Word] = []
        for m in suffixes {
            guard let fn = suffixFunctions[m.key] else { continue }
            let cls = m.kf.map { suffixClass[$0.seq] } ?? m.key
            let offset = word.len - m.substr.len
            guard offset > 0 else { continue }
            if !matches.isEmpty && matchUnique(cls, matches) { continue }
            let saved = suffixNextEnd
            suffixNextEnd = suffixNextEnd.map { $0 - m.substr.len }
            result += fn(self, word.sub(0, offset), m.substr, m.kf)
            suffixNextEnd = saved
        }
        return result
    }

    // MARK: suffix definitions helpers

    /// `def-simple-suffix`
    func simpleSuffix(root: String, suf: String, kf: DictText?, stem: Int = 0, score: ScoreMod, connector: String = "",
                      _ body: (inout (String, String)?) -> [PrimaryWord]) -> [Word] {
        guard let kf else { return [] }
        let saved = suffixMapTemp
        if stem != 0 { suffixMapTemp = nil }
        var patch: (String, String)? = nil
        let primaryWords = body(&patch)
        suffixMapTemp = saved
        return primaryWords.map { pw in
            let k = getKana(pw.word)
            let base = patch.map { destem(k, $0.0.len) + $0.1 } ?? destem(k, stem)
            return adjoinWord(pw.word, kf, text: root + suf, kana: base + connector + suf,
                              scoreMod: score, scoreBase: pw.scoreBase)
        }
    }

    /// `def-abbr-suffix`
    func abbrSuffix(root: String, suf: String, stem: Int, _ body: (inout (String, String)?) -> [Word]) -> [Word] {
        let saved = suffixMapTemp
        suffixMapTemp = nil
        var patch: (String, String)? = nil
        let primaryWords = body(&patch)
        suffixMapTemp = saved
        return primaryWords.compactMap { pw in
            let text = root + suf
            let k = getKana(pw)
            let kana = (patch.map { destem(k, $0.0.len) + $0.1 } ?? destem(k, stem)) + suf
            switch pw {
            case let s as SimpleText:
                return ProxyText(source: s, text: text, kana: kana, hinted: true)
            case let c as CompoundText:
                c.text = text
                c.kana = kana
                return c
            default:
                return nil
            }
        }
    }
}

func applyPatch(_ root: String, _ patch: (String, String)) -> String {
    root.sub(0, root.len - patch.1.len) + patch.0
}

private func pws(_ words: [Word]) -> [PrimaryWord] { words.map { PrimaryWord($0) } }

private func teCheck(_ ich: Ichiran, _ root: String) -> [Word] {
    guard root != "で", let l = root.lastScalar, "てで".unicodeScalars.contains(l) else { return [] }
    return ich.findWordWithConjType(root, 3)
}

private func teiruCheck(_ ich: Ichiran, _ root: String) -> [Word] {
    root == "いて" ? [] : teCheck(ich, root)
}

private func suffixSouBase(_ ich: Ichiran, _ root: String, _ patch: inout (String, String)?) -> [Word] {
    if root.hasScalarSuffix("なさ") {
        patch = ("い", "さ")
        let r = applyPatch(root, patch!)
        let saved = ich.suffixMapTemp
        ich.suffixMapTemp = nil
        defer { ich.suffixMapTemp = saved }
        return ich.findWordWithConjProp(r) { $0.prop.neg == true }
    }
    if !["な", "よ", "よさ", "に", "き"].contains(root) {
        return ich.findWordWithConjType(root, 13, Conj.adjectiveStem, Conj.adverbial)
    }
    return []
}

private func negConjFilter(_ cd: ConjData) -> Bool { cd.prop.neg == true }

let suffixFunctions: [String: SuffixFn] = [
    "tai": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(5)) { _ in
            root == "い" ? [] : pws(ich.findWordWithConjType(root, 13))
        }
    },
    "ren": { ich, root, suf, kf in
        // generic ren'youkei suffix
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(5)) { _ in pws(ich.findWordWithConjType(root, 13)) }
    },
    "ren-": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(0)) { _ in pws(ich.findWordWithConjType(root, 13)) }
    },
    "neg": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(5)) { _ in
            pws(ich.findWordWithConjType(root, 13, Conj.negativeStem))
        }
    },
    "te": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(0)) { _ in pws(teCheck(ich, root)) }
    },
    "teiru": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(3)) { _ in pws(teiruCheck(ich, root)) }
    },
    "teiru+": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(6)) { _ in pws(teiruCheck(ich, root)) }
    },
    "te+space": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(3), connector: " ") { _ in pws(teCheck(ich, root)) }
    },
    "kudasai": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .fn { _ in 360 }, connector: " ") { _ in pws(teCheck(ich, root)) }
    },
    "teren": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(4)) { _ in
            guard root != "で" else { return [] }
            if let l = root.lastScalar, "てで".unicodeScalars.contains(l) {
                return pws(ich.findWordWithConjType(root, 3))
            } else if root != "い" {
                return pws(ich.findWordWithConjType(root, 13))
            }
            return []
        }
    },
    "teii": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(1), connector: " ") { _ in
            guard let l = root.lastScalar, "てで".unicodeScalars.contains(l) else { return [] }
            return pws(ich.findWordWithConjType(root, 3))
        }
    },
    "chau": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, stem: 1, score: .int(5)) { _ in
            let te: String? = suf.firstScalar == "じ" ? "で" : suf.firstScalar == "ち" ? "て" : nil
            guard let te else { return [] }
            return pws(ich.findWordWithConjType(root + te, 3))
        }
    },
    "to": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, stem: 1, score: .int(0)) { _ in
            let te: String? = suf.firstScalar == "と" ? "て" : suf.firstScalar == "ど" ? "で" : nil
            guard let te else { return [] }
            return pws(ich.findWordWithConjType(root + te, 3))
        }
    },
    "suru": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(5), connector: " ") { _ in
            pws(ich.findWordWithPos(root, ["vs"]))
        }
    },
    "sou": { ich, root, suf, kf in
        let score: Int = root == "から" ? 40 : root == "い" ? 0 : root == "出来" ? 100 : 70
        return ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .fn { _ in score }) { patch in
            pws(suffixSouBase(ich, root, &patch))
        }
    },
    "sou+": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(1)) { patch in pws(suffixSouBase(ich, root, &patch)) }
    },
    "rou": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(1)) { _ in pws(ich.findWordWithConjType(root, 2)) }
    },
    "adv": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(1)) { _ in pws(ich.findWordWithConjType(root, Conj.adverbial)) }
    },
    "sugiru": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, stem: 1, score: .int(5)) { patch in
            let r: String?
            if root == "い" {
                r = nil
            } else if root.hasScalarSuffix("なさ") || root.hasScalarSuffix("無さ") {
                patch = ("い", "さ")
                r = applyPatch(root, patch!)
            } else {
                r = root + "い"
            }
            guard let r else { return [] }
            if patch != nil && r.len > 2 {
                return pws(ich.findWordWithConjProp(r, negConjFilter))
            }
            return pws(ich.findWordWithPos(r, ["adj-i"]))
        }
    },
    "sa": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(2)) { _ in
            pws(ich.findWordWithConjType(root, Conj.adjectiveStem) + ich.findWordWithPos(root, ["adj-na"]))
        }
    },
    "iadj": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(1)) { _ in pws(ich.findWordWithConjType(root, Conj.adjectiveStem)) }
    },
    "garu": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(0)) { patch in
            if ["な", "い", "よ"].contains(root) { return [] }
            let r = ich.findWordWithConjType(root, Conj.adjectiveStem)
            if !r.isEmpty { return pws(r) }
            if root.hasScalarSuffix("そ") {
                patch = ("う", "")
                let rt = applyPatch(root, patch!)
                let saved = ich.suffixMapTemp
                ich.suffixMapTemp = nil
                defer { ich.suffixMapTemp = saved }
                return pws(ich.findWordWithSuffix(rt, ["sou"]))
            }
            return []
        }
    },
    "ra": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(1)) { _ in
            if root.hasScalarSuffix("ら") { return [] }
            let r = ich.orAsHiragana({ ich.findWordWithPos($0, ["pn"]) }, root)
            return pws(r.isEmpty ? ich.findWordSeq(root, [1580640]) : r)
        }
    },
    "rashii": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(3)) { _ in
            ich.pairWordsByConj([ich.findWordWithConjType(root, 2), ich.findWordWithConjType(root + "ら", 11)])
                .compactMap { pair in pair[0].map { PrimaryWord($0, scoreBase: pair[1]) } }
        }
    },
    "desu": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .fn { _ in 200 }, connector: " ") { _ in
            guard root.hasScalarSuffix("ない") || root.hasScalarSuffix("なかった") else { return [] }
            return pws(ich.findWordWithConjProp(root, negConjFilter))
        }
    },
    "desho": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .fn { _ in 300 }, connector: " ") { _ in
            guard root.hasScalarSuffix("ない") else { return [] }
            return pws(ich.findWordWithConjProp(root, negConjFilter))
        }
    },
    "tosuru": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(3), connector: " ") { _ in pws(ich.findWordWithConjType(root, 9)) }
    },
    "kurai": { ich, root, suf, kf in
        ich.simpleSuffix(root: root, suf: suf, kf: kf, score: .int(3), connector: " ") { _ in pws(ich.findWordWithConjType(root, 2)) }
    },

    // abbreviations
    "nai": { ich, root, suf, _ in
        ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in
            ich.findWordWithConjProp(root + "ない", allowRoot: true) { cd in
                // 居ない 来ない create problems so they are blocked
                ![1577980, 1547720].contains(cd.from) && cd.prop.neg == true
            }
        }
    },
    "nai-x": { ich, root, suf, _ in
        ich.abbrSuffix(root: root, suf: suf, stem: 2) { patch in
            if root == "せ" {
                patch = ("しない", "せ")
                return ich.findWordConjOf("しない", [1157170])
            }
            return ich.findWordWithConjProp(root + "ない") { $0.from != 1157170 && $0.prop.neg == true }
        }
    },
    "nai-n": { ich, root, suf, _ in
        ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in
            ich.findWordWithConjProp(root + "ない") { cd in
                ![1577980, 1547720].contains(cd.from) && cd.prop.neg == true
            }
        }
    },
    "nakereba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 4) { _ in ich.findWordFull(root + "なければ") } },
    "shimashou": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 5) { _ in ich.findWordFull(root + "しましょう") } },
    "dewanai": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 4) { _ in ich.findWordFull(root + "ではない") } },
    "teba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "てば") } },
    "reba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "れば") } },
    "keba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "けば") } },
    "geba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "げば") } },
    "neba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "ねば") } },
    "beba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "べば") } },
    "meba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "めば") } },
    "seba": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "せば") } },
    "ii": { ich, root, suf, _ in ich.abbrSuffix(root: root, suf: suf, stem: 2) { _ in ich.findWordFull(root + "いい") } },
]

let suffixUniqueOnly: [String: SuffixUnique] = [
    "sa": .test { ich, matches in
        let seqs = matches.compactMap(ich.seqOf)
        guard !seqs.isEmpty else { return false }
        return !ich.db.query("SELECT seq FROM entry WHERE seq IN \(placeholders(seqs.count)) AND root_p", seqs).isEmpty
    },
    "ra": .always,
    "desu": .test { ich, matches in
        let seqs = matches.compactMap(ich.seqOf)
        let n = seqs.isEmpty ? 0 : ich.db.query(
            "SELECT seq FROM conjugation WHERE seq IN \(placeholders(seqs.count)) AND \"from\" = 2755350", seqs).count // じゃない
        return n < matches.count
    },
    "mo": .always, "nikui": .always, "gai": .always, "nai-n": .always, "dewanai": .always,
    "eba": .always, "teba": .always, "reba": .always, "keba": .always, "geba": .always,
    "neba": .always, "beba": .always, "meba": .always, "seba": .always, "ii": .always,
]
