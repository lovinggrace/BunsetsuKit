// Port of ichiran/dict counters (dict-counters.lisp)

import Foundation

let counterSuffixes: [String: (text: String, kana: String, desc: String)] = [
    "kan": ("間", "かん", "[duration]"),
    "kango": ("間後", "かんご", "[after ...]"),
    "chuu": ("中", "ちゅう", "[among/out of ...]"),
]

let counterAccepts: [Int: [String]] = [1194480: ["kan"], 1490430: ["kan"], 1333450: ["kan", "kango"]]

let counterForeign: [Int] = [1120410]

let extraCounterIds: [Int] = [
    1255430, // 月
    1606800, // 割
]

let skipCounterIds: Set<Int> = [
    2426510, // 一個当り
    2220370, // 歳 （とせ）
    2248360, // 入 （しお）
    2423450, // 差し
    2671670, // 幅 （の）
    2735690, // 種 （くさ）
    2838543, // 杯 （はた）
    // mahjong stuff - need some research on how to say these
    2249290, // 荘
    2833260, // 翻
    2833465, // 萬
    2833466, // 索
    2833467, // 筒
]

/// One `args` call of a def-special-counter. `texts` can contain several spellings.
struct SpecialCounter {
    var kind: CounterKind
    var texts: [String]
    var kana: String
    /// args-suffix: text parts and kana parts (kana + suffix)
    var suffixParts: (texts: [String], kana: [String])? = nil
    var digitOpts: [(Int?, [DigitOpt])] = []
    var ordinalp = false
    var accepts: [String] = []
    var common: Int?? = nil
    var allowed: [Int]? = nil
    var suffixDescriptions: [String] = []
    var foreign = false
}

private func sc(_ kind: CounterKind, _ text: String, _ kana: String, _ opts: [(Int?, [DigitOpt])] = [],
                ordinalp: Bool = false, accepts: [String] = [], common: Int?? = nil, allowed: [Int]? = nil,
                suffixDescriptions: [String] = [], foreign: Bool = false) -> SpecialCounter {
    SpecialCounter(kind: kind, texts: [text], kana: kana, digitOpts: opts, ordinalp: ordinalp, accepts: accepts,
                   common: common, allowed: allowed, suffixDescriptions: suffixDescriptions, foreign: foreign)
}

private func sc(_ kind: CounterKind, _ texts: [String], _ kana: String, _ opts: [(Int?, [DigitOpt])] = []) -> SpecialCounter {
    SpecialCounter(kind: kind, texts: texts, kana: kana, digitOpts: opts)
}

private func hifumi(_ set: [Int]) -> CounterKind { .hifumi(digitSet: set) }

private let yo: DigitOpt = .str("よ")
private let shichi: DigitOpt = .str("しち")
private let ku: DigitOpt = .str("く")
private let off: [(Int?, [DigitOpt])] = [(nil, [])]

let specialCounters: [Int: [SpecialCounter]] = [
    1203020: [sc(.normal, "階", "かい", [(3, [.r])])],
    2020680: [sc(.normal, "時", "じ", [(4, [yo]), (7, [shichi]), (9, [ku])])],
    1315920: [sc(.normal, "時間", "じかん", [(4, [yo]), (9, [ku])])],
    1658480: [sc(.halfhour, "時半", "じはん", [(4, [yo]), (9, [ku])])],
    1356740: [sc(.normal, "畳", "じょう", [(4, [yo]), (7, [shichi])])],
    2258110: [sc(.normal, "帖", "じょう", [(4, [yo]), (7, [shichi])])],
    1396490: [sc(.normal, "膳", "ぜん", [(4, [yo]), (7, [shichi])])],
    1427240: [sc(.normal, "丁", "ちょう"),
              SpecialCounter(kind: .normal, texts: [], kana: "", suffixParts: (["丁", "目"], ["ちょう", "め"]), ordinalp: true)],
    1427420: [sc(.normal, "丁目", "ちょうめ", ordinalp: true)],
    1514050: [sc(.normal, "舗", "ほ", [(4, [.h])])],
    1522150: [sc(.normal, "本", "ほん", [(3, [.r])])],
    1583370: [sc(.normal, ["匹", "疋"], "ひき", [(3, [.r])])],
    1607310: [sc(.normal, "羽", "わ", [(3, [.c, .str("ば")]), (6, [.g, .c, .str("ぱ")]), (10, [.g, .c, .str("ぱ")]),
                                         (100, [.g, .c, .str("ぱ")]), (1000, [.c, .str("ば")]), (10000, [.c, .str("ば")])])],
    1607320: [sc(.normal, "把", "わ", [(3, [.c, .str("ば")]), (7, [shichi]), (10, [.g, .c, .str("ぱ")])])],
    1633690: [sc(.normal, "段", "だん", [(7, [shichi])])],
    1901390: [sc(.normal, "敗", "はい", [(4, [.h])])],
    1919550: [sc(.normal, "泊", "はく", [(4, [.h])])],
    1994890: [sc(.normal, "首", "しゅ", [(10, [])])],
    1351270: [sc(.normal, "章", "しょう", [(10, [])])],
    2019640: [sc(.normal, ["杯", "盃"], "はい", [(3, [.r])])],
    2078550: [sc(.normal, "条", "じょう", [(7, [shichi])])],
    2078590: [sc(.normal, "軒", "けん", [(3, [.r])])],
    2081610: [sc(.normal, ["立て", "たて", "タテ"], "たて", off)],
    2084840: [sc(.normal, "年", "ねん", [(4, [yo]), (7, [shichi]), (9, [ku])], accepts: ["kan"])],
    1468900: [sc(.normal, "年生", "ねんせい", [(4, [yo]), (7, [shichi]), (9, [ku])])],
    1502840: [sc(.normal, "分", "ふん", [(4, [.h])])],
    2386360: [sc(.normal, "分間", "ふんかん", [(4, [.h])])],
    1373990: [sc(.normal, "世紀", "せいき", [(10, [.str("じっ")])])],
    2836694: [sc(.normal, "傑", "けつ", [(10, [.str("じっ")])])],
    2208060: [sc(.normal, "遍", "へん", [(3, [.r])])],
    1511870: [sc(.normal, ["編", "篇"], "へん", [(3, [.r])])],
    2271620: [sc(.normal, "口", "こう")],
    2412230: [sc(.normal, "足", "そく", [(3, [.r])])],
    1175570: [sc(.normal, "円", "えん", [(4, [yo])])],
    1315130: [sc(.normal, "字", "じ", [(4, [yo])])],
    1487770: [sc(.normal, "筆", "ひつ", [(4, [.h])])],
    2220330: [sc(.tsu, "つ", "つ")],
    1208920: [sc(hifumi([1, 2]), "株", "かぶ")],
    1214060: [sc(hifumi([1, 2, 3, 4, 5]), ["竿", "棹"], "さお", [(4, [yo]), (10, [])])],
    1260670: [sc(hifumi([1, 2, 3]), "本", "もと")], // uncertain
    1275640: [sc(hifumi([1, 2, 3]), "口", "くち")],
    1299680: [sc(hifumi([1, 2, 3]), ["皿", "盤"], "さら")],
    1302680: [sc(hifumi([1, 2, 3]), "山", "やま")], // uncertain
    1335810: [sc(hifumi([1, 2, 3]), ["重ね", "襲"], "かさね")], // uncertain
    1361130: [sc(hifumi([1, 2]), ["振り", "風"], "ふり", off)], // uncertain
    1366210: [sc(hifumi([1, 2]), ["針", "鉤", "鈎"], "はり", off)],
    1379650: [sc(hifumi([1, 2]), ["盛り", "盛"], "もり")],
    1383800: [sc(hifumi([1, 2, 3]), ["切り", "限り", "限"], "きり", [(4, [yo]), (8, [])])],
    1384840: [sc(hifumi([1, 2, 3]), "切れ", "きれ", [(4, [yo]), (8, [])])],
    1385780: [sc(hifumi([1, 2]), "折", "おり")],
    1404450: [sc(hifumi([1, 2]), "束", "たば")],
    1426480: [sc(hifumi([1, 2]), "柱", "はしら", off)],
    1432920: [sc(hifumi([1, 2]), "通り", "とおり", [(100, [.g])])],
    1445150: [sc(hifumi([1, 2]), "度", "たび", off, common: .some(nil))],
    1448350: [sc(hifumi([1, 2]), "棟", "むね")],
    1335730: [sc(hifumi([1, 2, 3, 5, 7, 8, 9, 10]), "重", "え", allowed: [1, 2, 3, 5, 7, 8, 9, 10])],
    2108240: [sc(.normal, "重", "じゅう", [(4, [.str("し")]), (7, [shichi]), (9, [ku])])],
    1482110: [sc(hifumi([1, 2, 3]), "晩", "ばん", [(4, [yo])])],
    1501110: [sc(hifumi([1, 2]), ["腹", "肚"], "はら", off)],
    1397450: [sc(hifumi([1, 2, 3]), "組", "くみ", allowed: [1, 2, 3], suffixDescriptions: ["(sets or pairs only)"]),
              sc(.normal, "組", "くみ", [(1, [])])],
    1519300: [sc(hifumi([1, 2]), ["房", "総"], "ふさ", off)],
    1552890: [sc(hifumi([1, 2, 3]), "粒", "つぶ", [(6, [.g])])],
    1564410: [sc(hifumi([1, 2, 3]), "一刎", "はね", off)],
    1585650: [sc(hifumi([1, 2]), ["箱", "函", "匣", "筥", "筐", "凾"], "はこ", [(4, [yo]), (1000, []), (10000, [])])],
    1602800: [sc(hifumi([1, 2, 3]), ["船", "舟"], "ふね", off)], // uncertain
    1853450: [sc(hifumi([1, 2]), ["締め", "〆"], "しめ")], // uncertain
    1215240: [sc(hifumi([1, 2, 3, 4, 9]), "間", "ま", [(4, [yo])])],
    2243700: [sc(hifumi([1, 2, 3]), "咫", "あた")],
    2414730: [sc(hifumi([1, 2]), "梱", "こり")],
    1583470: [sc(hifumi([1, 2, 3]), "品", "しな", [(4, [yo])])],
    1411070: [sc(hifumi([1, 2, 3]), "袋", "ふくろ", [(4, [yo]), (10, [.str("じっ"), .h])])],
    2707020: [sc(.normal, "袋", "たい", [(10, [.str("じっ")])])],
    2800530: [sc(hifumi([1, 2]), ["回り", "廻り"], "まわり")],
    1047880: [sc(hifumi([1, 2]), "ケース", "ケース", foreign: true)],
    1214540: [sc(hifumi([1, 2]), "缶", "かん")],
    1575510: [sc(hifumi([1, 2]), ["齣", "コマ"], "こま")],
    1253800: [sc(hifumi([1, 2, 3]), "桁", "けた")],
    1241750: [sc(hifumi([1, 2, 3]), "筋", "すじ")],
    1515340: [sc(hifumi([1, 2, 3]), "包み", "つつみ")],
    2452360: [sc(hifumi([1, 2, 3]), "片", "ひら")],
    2844070: [sc(hifumi([1, 2, 3]), "腰", "こし")],
    2844196: [sc(hifumi([1, 2, 3]), "緡", "さし")],
    1175140: [sc(hifumi([1, 2]), "駅", "えき")],
    2855028: [sc(hifumi([1, 2]), "揃え", "そろえ")],
    2083110: [sc(.daysKun, "日", "か", accepts: ["kan"], common: .some(0))],
    2083100: [sc(.daysOn, "日", "にち")],
    1255430: [sc(.months, "月", "がつ")],
    2149890: [sc(.people, "人", "にん", [(4, [yo]), (7, [shichi])], accepts: ["chuu"])],
    1606800: [sc(.wari, "割", "わり")],
    1606950: [sc(.wari, "割引", "わりびき")],
    1294940: [sc(.age, ["歳", "才"], "さい")],
]

private let kaRow: Set<String> = ["ka", "ki", "ku", "ke", "ko"]
private let saRow: Set<String> = ["sa", "shi", "su", "se", "so"]
private let taRow: Set<String> = ["ta", "chi", "tsu", "te", "to"]
private let haRow: Set<String> = ["ha", "hi", "fu", "he", "ho"]
private let paRow: Set<String> = ["pa", "pi", "pu", "pe", "po"]

func getDigit(_ n: Int) -> Int {
    let digit = n % 10
    if digit != 0 { return digit }
    let powers = [10, 100, 1000, 10000, 100_000_000]
    for i in 0..<(powers.count - 1) where n % powers[i + 1] != 0 {
        return powers[i]
    }
    return 0
}

extension Ichiran {
    /// `counter-join`
    func counterJoin(_ c: CounterText, _ n: Int, _ numberKana: String, _ counterKana: String) -> String {
        var numberKana = numberKana, counterKana = counterKana
        let digit = getDigit(n)
        let head = charClassName(counterKana.firstScalar) ?? ""
        let digitOpts = c.digitOpts.first { $0.0 == digit }
        let offOpt = c.digitOpts.first { $0.0 == nil }
        if digitOpts != nil || offOpt != nil {
            var modCounter = false
            for opt in digitOpts?.1 ?? [] {
                switch opt {
                case .str(let s):
                    if modCounter {
                        counterKana = s
                    } else {
                        let stemKana = digit < 10 ? Numbers.digitToKana[digit] : Numbers.powerToKana[Int((log10(Double(digit))).rounded())]
                        let stem = stemKana?.len ?? 0
                        numberKana = numberKana.sub(0, numberKana.len - stem) + s
                    }
                case .g: numberKana = geminate(numberKana)
                case .r: counterKana = rendaku(counterKana)
                case .h: counterKana = rendaku(counterKana, handakuten: true)
                case .c: modCounter = true
                }
            }
            return numberKana + counterKana
        }
        if c.args.foreign {
            switch digit {
            case 6: if kaRow.contains(head) || paRow.contains(head) { numberKana = geminate(numberKana) }
            case 8, 10: if kaRow.contains(head) || saRow.contains(head) || taRow.contains(head) || paRow.contains(head) {
                numberKana = geminate(numberKana)
            }
            case 100: if kaRow.contains(head) { numberKana = geminate(numberKana) }
            default: break
            }
            return numberKana + counterKana
        }
        let hGem = { numberKana = geminate(numberKana); counterKana = rendaku(counterKana, handakuten: true) }
        switch digit {
        case 1:
            if kaRow.contains(head) || saRow.contains(head) || taRow.contains(head) { numberKana = geminate(numberKana) }
            else if haRow.contains(head) { hGem() }
        case 3:
            if haRow.contains(head) { counterKana = rendaku(counterKana, handakuten: true) }
        case 6:
            if kaRow.contains(head) || paRow.contains(head) { numberKana = geminate(numberKana) }
            else if haRow.contains(head) { hGem() }
        case 8, 10:
            if kaRow.contains(head) || saRow.contains(head) || taRow.contains(head) || paRow.contains(head) { numberKana = geminate(numberKana) }
            else if haRow.contains(head) { hGem() }
        case 100:
            if kaRow.contains(head) { numberKana = geminate(numberKana) }
            else if haRow.contains(head) { hGem() }
        case 1000, 10000:
            if haRow.contains(head) { counterKana = rendaku(counterKana, handakuten: true) }
        default: break
        }
        return numberKana + counterKana
    }

    func counterKana(_ c: CounterText) -> String {
        let n = c.numberValue
        var kana: String
        let defaultKana = { self.counterJoin(c, n, Numbers.numberToKana(n, separator: String(kanaHintSpace)), c.args.kana) }
        switch c.kind {
        case .number:
            kana = Numbers.numberToKana(n, separator: String(kanaHintSpace))
        case .tsu:
            let t = [1: "ひとつ", 2: "ふたつ", 3: "みっつ", 4: "よっつ", 5: "いつつ", 6: "むっつ", 7: "ななつ", 8: "やっつ", 9: "ここのつ"]
            kana = t[n] ?? defaultKana()
        case .hifumi(let set):
            let t = [1: "ひと", 2: "ふた", 3: "み", 4: "よ", 5: "いつ", 6: "む", 7: "なな", 8: "や", 9: "ここの", 10: "と"]
            kana = set.contains(n) ? (t[n] ?? "") + c.args.kana : defaultKana()
        case .daysKun:
            let t = [1: "ついたち", 2: "ふつか", 3: "みっか", 4: "よっか", 5: "いつか", 6: "むいか", 7: "なのか", 8: "ようか",
                     9: "ここのか", 10: "とうか", 14: "じゅうよっか", 20: "はつか", 24: "にじゅうよっか", 30: "みそか"]
            kana = t[n] ?? ""
        case .people:
            kana = n == 1 ? "ひとり" : n == 2 ? "ふたり" : defaultKana()
        case .age:
            kana = n == 20 ? "はたち" : defaultKana()
        default:
            kana = defaultKana()
        }
        if let suffix = c.args.suffix { kana += suffix }
        return kana
    }

    // MARK: counter cache

    var counterCache: [String: [CounterArgs]] {
        if let c = counterCacheStorage { return c }
        let c = buildCounterCache()
        counterCacheStorage = c
        return c
    }

    func getCounterReadings() -> [Int: (kanji: [DictText], kana: [DictText])] {
        var ids = db.column("SELECT DISTINCT seq FROM sense_prop WHERE tag = 'pos' AND text = 'ctr' ORDER BY seq").compactMap(\.int)
        ids += extraCounterIds
        ids = ids.filter { !skipCounterIds.contains($0) }
        var stagks: [Int: [String]] = [:], stagrs: [Int: [String]] = [:]
        for (tag, target) in [("stagk", 0), ("stagr", 1)] {
            for chunk in chunked(ids) {
                for row in db.query("""
                    SELECT sp.seq, sp.text FROM sense_prop sp, sense_prop sp1
                    WHERE sp.seq = sp1.seq AND sp.sense_id = sp1.sense_id AND sp.tag = ? AND sp1.tag = 'pos'
                      AND sp1.text = 'ctr' AND sp.seq IN \(placeholders(chunk.count))
                    """, [tag] + chunk.map { $0 as SQLBindable }) {
                    if target == 0 { stagks[row[0].int!, default: []].append(row[1].text!) }
                    else { stagrs[row[0].int!, default: []].append(row[1].text!) }
                }
            }
        }
        var hash: [Int: (kanji: [DictText], kana: [DictText])] = [:]
        for chunk in chunked(ids) {
            let p = placeholders(chunk.count)
            for r in words(.kanji, where: "seq IN \(p)", chunk) {
                if let st = stagks[r.seq], !st.contains(r.text) { continue }
                hash[r.seq, default: ([], [])].kanji.append(r)
            }
            for r in words(.kana, where: "seq IN \(p)", chunk) {
                if let st = stagrs[r.seq], !st.contains(r.text) { continue }
                hash[r.seq, default: ([], [])].kana.append(r)
            }
        }
        for (k, v) in hash {
            hash[k] = (v.kanji.sorted { $0.ord < $1.ord }, v.kana.sorted { $0.ord < $1.ord })
        }
        return hash
    }

    func buildCounterCache() -> [String: [CounterArgs]] {
        var cache: [String: [CounterArgs]] = [:]
        func addArgsStar(_ text: String, _ args: CounterArgs) {
            cache[text, default: []].insert(args, at: 0)
            for suf in args.accepts {
                guard let (sufText, sufKana, sufDesc) = counterSuffixes[suf] else { continue }
                var newArgs = args
                let newText = text + sufText
                newArgs.text = newText
                newArgs.suffix = (args.suffix ?? "") + sufKana
                newArgs.suffixDescriptions.insert(sufDesc, at: 0)
                cache[newText, default: []].insert(newArgs, at: 0)
            }
        }
        addArgsStar("", CounterArgs(kind: .number, text: "", kana: "", source: nil))
        let readingsHash = getCounterReadings()
        for seq in readingsHash.keys.sorted() {
            let (kanji, kana) = readingsHash[seq]!
            if let specials = specialCounters[seq] {
                let all = kanji + kana
                for sp in specials {
                    if let (texts, kanas) = sp.suffixParts {
                        let text = texts.joined()
                        let args = CounterArgs(kind: sp.kind, text: text, kana: kanas[0], source: all.first { $0.text == texts[0] },
                                               ordinalp: sp.ordinalp, suffix: kanas.count > 1 ? kanas[1] : nil, accepts: sp.accepts,
                                               suffixDescriptions: sp.suffixDescriptions, digitOpts: sp.digitOpts,
                                               common: sp.common, allowed: sp.allowed, foreign: sp.foreign)
                        addArgsStar(text, args)
                        continue
                    }
                    for text in sp.texts {
                        let args = CounterArgs(kind: sp.kind, text: text, kana: sp.kana, source: all.first { $0.text == text },
                                               ordinalp: sp.ordinalp, accepts: sp.accepts, suffixDescriptions: sp.suffixDescriptions,
                                               digitOpts: sp.digitOpts, common: sp.common, allowed: sp.allowed, foreign: sp.foreign)
                        addArgsStar(text, args)
                    }
                }
            } else {
                let foreign = kanji.isEmpty || counterForeign.contains(seq)
                let kts = foreign ? kanji + kana.filter { testWord($0.text, .katakana) } : kanji
                guard let firstKana = kana.first else { continue }
                for kt in kts {
                    let text = kt.text
                    addArgsStar(text, CounterArgs(kind: .normal, text: text, kana: firstKana.text, source: kt,
                                                  ordinalp: text.len > 1 && text.endsWith("目"),
                                                  accepts: counterAccepts[kt.seq] ?? [], foreign: foreign))
                }
            }
        }
        for counter in cache.keys.sorted() {
            let cord = counter + "目"
            if counter.isEmpty || (counter.len > 1 && counter.endsWith("目")) || cache[cord] != nil { continue }
            for old in cache[counter]! where !old.ordinalp {
                var args = old
                args.text = cord
                args.suffix = (old.suffix ?? "") + "め"
                args.ordinalp = true
                addArgsStar(cord, args)
            }
        }
        return cache
    }

    /// `find-counter`
    func findCounter(_ number: String, _ counter: String, unique: Bool = true) -> [CounterText] {
        guard let argsList = counterCache[counter] else { return [] }
        return argsList.compactMap { args in
            guard let c = try? CounterText(args: args, numberText: number), c.verify(unique) else { return nil }
            return c
        }
    }
}
