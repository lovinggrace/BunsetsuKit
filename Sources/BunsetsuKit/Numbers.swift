// Port of ichiran/numbers (numbers.lisp)

import Foundation

public enum Numbers {
    public static let digitKanjiDefault = "〇一二三四五六七八九"
    public static let digitKanjiLegal = "〇壱弐参四五六七八九拾"
    public static let powerKanji = "一十百千万   億   兆   京"

    enum NumClass: Equatable { case jd, p, ad }

    struct NumChar: Equatable {
        let cls: NumClass
        let val: Int
    }

    static let charNumberClass: [Unicode.Scalar: NumChar] = {
        let table: [(String, NumClass, Int)] = [
            ("〇零", .jd, 0), ("一壱", .jd, 1), ("二弐", .jd, 2), ("三参", .jd, 3),
            ("四", .jd, 4), ("五", .jd, 5), ("六", .jd, 6), ("七", .jd, 7),
            ("八", .jd, 8), ("九", .jd, 9), ("十拾", .p, 1), ("百", .p, 2),
            ("千", .p, 3), ("万", .p, 4), ("億", .p, 8), ("兆", .p, 12), ("京", .p, 16),
            ("0０", .ad, 0), ("1１", .ad, 1), ("2２", .ad, 2), ("3３", .ad, 3), ("4４", .ad, 4),
            ("5５", .ad, 5), ("6６", .ad, 6), ("7７", .ad, 7), ("8８", .ad, 8), ("9９", .ad, 9),
        ]
        var d: [Unicode.Scalar: NumChar] = [:]
        for (chars, cls, val) in table {
            for c in chars.unicodeScalars { d[c] = NumChar(cls: cls, val: val) }
        }
        return d
    }()

    static let digitToKana: [Int: String] = [
        0: "れい", 1: "いち", 2: "に", 3: "さん", 4: "よん", 5: "ご", 6: "ろく", 7: "なな", 8: "はち", 9: "きゅう",
    ]

    static let powerToKana: [Int: String] = [
        1: "じゅう", 2: "ひゃく", 3: "せん", 4: "まん", 8: "おく", 12: "ちょう", 16: "けい",
    ]

    public struct NotANumber: Error, CustomStringConvertible {
        public let text: String
        public let reason: String
        public var description: String { "\"\(text)\" is not a number: \(reason)" }
    }

    public static func numberToKanji(_ n: Int, digits: String = digitKanjiDefault, powers: String = powerKanji,
                                     oneSen: Bool = false) -> String {
        precondition(n >= 0)
        let d = digits.scalars, pw = powers.scalars
        if n == 0 { return String(d[0]) }
        var mp = 1
        var mc: Unicode.Scalar = " "
        var p = 1
        for i in 0..<pw.count {
            if i > 0 {
                let (r, overflow) = p.multipliedReportingOverflow(by: 10)
                if overflow { break }
                p = r
            }
            if p > n { break }
            let c = pw[i]
            if c != " " { mp = p; mc = c }
        }
        if mp == 1 { return String(d[n]) }
        let qt = n / mp, rem = n % mp
        let head = (qt == 1 && mp <= (oneSen ? 100 : 1000)) ? ""
            : numberToKanji(qt, digits: digits, powers: powers, oneSen: true)
        let tail = rem == 0 ? "" : numberToKanji(rem, digits: digits, powers: powers, oneSen: oneSen)
        return head + String(mc) + tail
    }

    static func parseNumber(_ na: [NumChar], start: Int = 0, end: Int? = nil) -> Int {
        let end = end ?? na.count
        var mp = 0
        var mi: Int? = nil
        for i in start..<end where na[i].cls == .p && na[i].val > mp {
            mp = na[i].val
            mi = i
        }
        func pow10(_ e: Int) -> Int { var r = 1; for _ in 0..<e { r = r &* 10 }; return r }
        guard let mi else {
            return na[start..<end].reduce(0) { $0 &* 10 &+ $1.val }
        }
        if mi == start {
            return pow10(mp) &+ (start + 1 < end ? parseNumber(na, start: start + 1, end: end) : 0)
        }
        return parseNumber(na, start: start, end: mi) &* pow10(mp)
            &+ (mi + 1 < end ? parseNumber(na, start: mi + 1, end: end) : 0)
    }

    public static func parseNumber(_ str: String) throws -> Int {
        var na: [NumChar] = []
        for c in str.unicodeScalars {
            guard let nc = charNumberClass[c] else {
                throw NotANumber(text: str, reason: "Invalid character: \(c)")
            }
            na.append(nc)
        }
        if na.isEmpty { return 0 }
        return parseNumber(na)
    }

    /// Joins s1 and s2 taking digit classes into account.
    static func numSandhi(_ c1: NumClass?, _ v1: Int?, _ c2: NumClass, _ v2: Int, _ s1: String, _ s2: String) -> String {
        var s1 = s1, s2 = s2
        switch (c1, v1, c2) {
        case (.jd?, 1?, .p):
            if [3, 12, 16].contains(v2) { s1 = geminate(s1) }
        case (.jd?, 3?, .p):
            if [2, 3].contains(v2) { s2 = rendaku(s2) }
        case (.jd?, 6?, .p):
            if v2 == 2 { s1 = geminate(s1); s2 = rendaku(s2, handakuten: true) }
            if v2 == 16 { s1 = geminate(s1) }
        case (.jd?, 8?, .p):
            if v2 == 2 { s1 = geminate(s1); s2 = rendaku(s2, handakuten: true) }
            if [3, 12, 16].contains(v2) { s1 = geminate(s1) }
        case (.p?, 1?, .p):
            if [12, 16].contains(v2) { s1 = geminate(s1) }
        case (.p?, 2?, .p):
            if v2 == 16 { s1 = geminate(s1) }
        default: break
        }
        return s1 + s2
    }

    static func groupToKana(_ group: [NumChar]) -> String {
        var result = ""
        var lastClass: NumClass? = nil
        var lastVal: Int? = nil
        for nc in group {
            let kana = (nc.cls == .p ? powerToKana[nc.val] : digitToKana[nc.val]) ?? ""
            result = numSandhi(lastClass, lastVal, nc.cls, nc.val, result, kana)
            lastClass = nc.cls
            lastVal = nc.val
        }
        return result
    }

    static func numberGroups(_ n: Int) -> [[NumChar]] {
        var groups: [[NumChar]] = []
        var cur: [NumChar] = []
        var lastClass: NumClass? = nil
        var lastVal = 0
        for k in numberToKanji(n).unicodeScalars {
            guard let nc = charNumberClass[k] else { continue }
            if lastClass == nil || (nc.cls == .p && (lastClass == .jd || (lastClass == .p && nc.val > lastVal))) {
                cur.append(nc)
            } else {
                groups.append(cur)
                cur = [nc]
            }
            lastClass = nc.cls
            lastVal = nc.val
        }
        groups.append(cur)
        return groups
    }

    public static func numberToKana(_ n: Int, separator: String = " ") -> String {
        numberGroups(n).map(groupToKana).joined(separator: separator)
    }

    public static func numberToKanaGroups(_ n: Int) -> [String] {
        numberGroups(n).map(groupToKana)
    }
}
