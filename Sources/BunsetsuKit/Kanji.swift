// Port of ichiran/kanji (kanji.lisp): kanji readings and reading matching

import Foundation

/// A kanji reading candidate: (reading, type, rendaku, geminated original char)
struct KanjiReading {
    let text: String
    let type: String
    let rendaku: Bool
    let geminated: String?
}

/// Element of `make-rmap`: either a literal character or a list of reading candidates.
enum RMapItem {
    case char(Unicode.Scalar)
    case readings([KanjiReading])
}

/// Result element of `match-readings`.
public enum ReadingMatch: Equatable, Sendable {
    case kana(String)
    case kanji(kanji: String, reading: String, type: String, rendaku: Bool, geminated: String?)
}

extension Ichiran {
    var hasKanjiTable: Bool {
        !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'kanji'").isEmpty
    }

    func getReadingsCache(_ str: String, names: Bool) -> [(String, String)] {
        let key = "\(str)|\(names)"
        if let c = kanjiReadingCache[key] { return c }
        let r = db.query("""
            SELECT r.text, r.type FROM kanji k INNER JOIN reading r ON r.kanji_id = k.id
            WHERE k.text = ? \(names ? "" : "AND r.type <> 'ja_na'") ORDER BY r.id
            """, [str]).map { ($0[0].text!, $0[1].text!) }
        kanjiReadingCache[key] = r
        return r
    }

    func getReadingAlternatives(_ reading: String, _ type: String, rendaku doRendaku: Bool) -> [KanjiReading] {
        let end = reading.len - 1
        var lst = [KanjiReading(text: reading, type: type, rendaku: false, geminated: nil)]
        if end > 0, type == "ja_on", let last = reading.lastScalar, "つくきち".unicodeScalars.contains(last) {
            lst.append(KanjiReading(text: geminate(reading), type: type, rendaku: false, geminated: String(last)))
        }
        if doRendaku {
            var extra: [KanjiReading] = []
            for r in lst {
                extra.append(KanjiReading(text: rendaku(r.text), type: type, rendaku: true, geminated: r.geminated))
                extra.append(KanjiReading(text: rendaku(r.text, handakuten: true), type: type, rendaku: true, geminated: r.geminated))
            }
            lst += extra
        }
        return lst
    }

    func getNormalReadings(_ char: String, rendaku: Bool) -> [KanjiReading] {
        var main: [KanjiReading] = [], alt: [KanjiReading] = []
        for (reading, type) in getReadingsCache(char, names: false) {
            let a = getReadingAlternatives(reading, type, rendaku: rendaku)
            main.append(a[0])
            alt += a.dropFirst()
        }
        var seen = Set<String>()
        return (main + alt).filter { seen.insert($0.text).inserted }
    }

    func makeRMap(_ str: String) -> [RMapItem] {
        var prevKanji: String? = nil
        var result: [RMapItem] = []
        for (start, c) in str.unicodeScalars.enumerated() {
            if isKanji(c) {
                switch c {
                case "々":
                    result.append(.readings(prevKanji.map { getNormalReadings($0, rendaku: true) } ?? []))
                    prevKanji = nil
                case "ヶ":
                    prevKanji = nil
                    result.append(.readings([KanjiReading(text: "か", type: "ja_on", rendaku: false, geminated: nil),
                                             KanjiReading(text: "が", type: "abbr", rendaku: false, geminated: nil)]))
                case "〆":
                    prevKanji = "締"
                    result.append(.readings([KanjiReading(text: "しめ", type: "ja_kun", rendaku: false, geminated: nil),
                                             KanjiReading(text: "じめ", type: "ja_kun", rendaku: true, geminated: nil)]))
                default:
                    prevKanji = String(c)
                    result.append(.readings(getNormalReadings(String(c), rendaku: start > 0)))
                }
            } else {
                result.append(.char(c))
            }
        }
        return result
    }

    enum MatchElem {
        case char(Unicode.Scalar)
        case reading(KanjiReading)
    }

    /// `match-readings*`: returns nil for :none
    func matchReadingsStar(_ rmap: ArraySlice<RMapItem>, _ reading: [Unicode.Scalar], start: Int = 0) -> (match: [MatchElem], score: Int)? {
        guard let item = rmap.first else {
            return start >= reading.count ? ([], 0) : nil
        }
        if start >= reading.count { return nil }
        let rest = rmap.dropFirst()
        switch item {
        case .readings(let readings):
            var best: (match: [MatchElem], score: Int)? = nil
            // matches are collected with push and scanned in reverse: ties go to the latest end
            var candidates: [(match: [MatchElem], score: Int)] = []
            for end in (start + 1)...reading.count {
                guard let (match, score) = matchReadingsStar(rest, reading, start: end) else { continue }
                let piece = String(scalars: reading[start..<end])
                if let r = readings.first(where: { $0.text == piece }) {
                    candidates.append(([.reading(r)] + match, score))
                } else {
                    candidates.append(([.reading(KanjiReading(text: piece, type: "irr", rendaku: false, geminated: nil))] + match,
                                       score - (end - start)))
                }
            }
            for c in candidates.reversed() where best == nil || c.score > best!.score { best = c }
            return best
        case .char(let c):
            guard reading[start] == c, let (match, score) = matchReadingsStar(rest, reading, start: start + 1) else { return nil }
            return ([.char(c)] + match, score)
        }
    }

    /// `match-readings`: matches kanji of `str` with parts of `reading`.
    func matchReadingsDetailed(_ str: String, _ reading: String) -> [ReadingMatch]? {
        guard hasKanjiTable else { return nil }
        let rmap = makeRMap(str)
        guard let (match, _) = matchReadingsStar(rmap[...], reading.scalars) else { return nil }
        var result: [ReadingMatch] = []
        var charbag = String.UnicodeScalarView()
        for (m, c) in zip(match, str.unicodeScalars) {
            switch m {
            case .reading(let r):
                if !charbag.isEmpty { result.append(.kana(String(charbag))); charbag = String.UnicodeScalarView() }
                result.append(.kanji(kanji: String(c), reading: r.text, type: r.type, rendaku: r.rendaku, geminated: r.geminated))
            case .char:
                charbag.append(c)
            }
        }
        if !charbag.isEmpty { result.append(.kana(String(charbag))) }
        return result
    }

    /// match-readings in the form used by hints
    func matchReadings(_ str: String, _ reading: String) -> [DiffPart]? {
        matchReadingsDetailed(str, reading)?.map {
            switch $0 {
            case .kana(let s): return .same(s)
            case .kanji(let k, let r, _, _, _): return .diff(k, r)
            }
        }
    }

    // MARK: kanji info

    func getOriginalReading(_ rtext: String, rendaku: Bool, geminated: String?) -> String {
        var r = rendaku ? unrendaku(rtext) : rtext
        if let g = geminated, let gc = g.firstScalar, !r.isEmpty {
            var s = r.scalars
            s[s.count - 1] = gc
            r = String(scalars: s)
        }
        return r
    }

    /// `get-kanji-words`
    func getKanjiWords(_ char: String) -> [(seq: Int, kanji: String, kana: String, common: Int)] {
        db.query("""
            SELECT e.seq, k.text, r.text, k.common FROM entry e, kanji_text k, kana_text r
            WHERE e.seq = k.seq AND e.seq = r.seq AND r.text = k.best_kana AND k.common IS NOT NULL
              AND e.root_p AND k.text LIKE ?
            """, ["%" + char + "%"]).map { ($0[0].int!, $0[1].text!, $0[2].text!, $0[3].int!) }
    }

    func kanjiWordStats(_ char: String) -> (stats: [String: Int], irregular: Int, total: Int) {
        let words = getKanjiWords(char)
        var stats: [String: Int] = [:]
        var irregular = 0
        for w in words {
            let m = matchReadingsDetailed(w.kanji, w.kana)?.first { if case .kanji(let k, _, _, _, _) = $0 { return k == char }; return false }
            if case .kanji(_, let rtext, let rtype, let rendaku, let gem)? = m {
                if rtype == "irr" { irregular += 1 }
                else { stats[getOriginalReading(rtext, rendaku: rendaku, geminated: gem) + "\u{1}" + rtype, default: 0] += 1 }
            } else {
                irregular += 1
            }
        }
        return (stats, irregular, words.count)
    }

    /// Information about a kanji (the `kanji-info-json` of ichiran).
    public func kanjiInfo(_ char: String) -> [String: Any]? {
        synchronized {
            guard hasKanjiTable, let k = db.query("""
                SELECT id, text, radical_c, radical_n, strokes, stat_common, stat_irregular, freq, grade FROM kanji WHERE text = ?
                """, [char]).first else { return nil }
            let total = k[5].int ?? 0
            var js: [String: Any] = [
                "text": k[1].text ?? "", "rc": k[2].int as Any, "rn": k[3].int as Any, "strokes": k[4].int as Any,
                "total": total, "irr": k[6].int ?? 0, "irr_perc": calculatePerc(k[6].int ?? 0, total),
            ]
            js["readings"] = db.query("""
                SELECT id, text, type, stat_common, prefixp, suffixp FROM reading
                WHERE kanji_id = ? AND type <> 'ja_na' ORDER BY type DESC, stat_common DESC
                """, [k[0].int!]).map { r -> [String: Any] in
                var rj: [String: Any] = [
                    "text": r[1].text!, "rtext": RomanizationMethod.hepburnBasic.romanizeWord(r[1].text!, originalSpelling: ""),
                    "type": r[2].text!,
                    "okuri": db.column("SELECT DISTINCT text FROM okurigana WHERE reading_id = ?", [r[0].int!]).compactMap(\.text),
                    "sample": r[3].int ?? 0, "perc": calculatePerc(r[3].int ?? 0, total),
                ]
                if r[4].bool == true { rj["prefixp"] = true }
                if r[5].bool == true { rj["suffixp"] = true }
                return rj
            }
            js["meanings"] = db.column("SELECT text FROM meaning WHERE kanji_id = ? ORDER BY id", [k[0].int!]).compactMap(\.text)
            if let f = k[7].int { js["freq"] = f }
            if let g = k[8].int { js["grade"] = g }
            return js
        }
    }

    /// Matches the kanji of `str` with the parts of `reading` (`match-readings`).
    public func matchKanjiReadings(_ str: String, _ reading: String) -> [ReadingMatch]? {
        synchronized { matchReadingsDetailed(str, reading) }
    }
}

func calculatePerc(_ sample: Int, _ total: Int) -> String {
    if total == 0 { return "--.--%" }
    return String(format: "%.2f%%", 100.0 * Double(sample) / Double(total))
}
