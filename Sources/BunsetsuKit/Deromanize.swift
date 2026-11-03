// Port of the detransliteration module (deromanize.lisp)

import Foundation

struct RMapEntry {
    let text: String
    let kana: String
    let next: String?
}

enum Deromanize {
    static let romajiKana: [String: RMapEntry] = {
        guard let url = DictionaryBuilder.resourceURL?.appendingPathComponent("romaji-map.csv"),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var d: [String: RMapEntry] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            d[f[0]] = RMapEntry(text: f[0], kana: f[1], next: f.count > 2 && !f[2].isEmpty ? f[2] : nil)
        }
        return d
    }()

    static let romajiKanaNext: Set<String> = {
        var s = Set<String>()
        for k in romajiKana.keys where k.len > 1 {
            for end in 1..<k.len { s.insert(k.sub(0, end)) }
        }
        return s
    }()

    struct KanaRepresentation {
        var canonical = ""
        var pattern = ""
        var rest = ""
        var branch = 0
    }

    static func concat(_ a: KanaRepresentation, _ b: KanaRepresentation) -> KanaRepresentation {
        KanaRepresentation(canonical: a.canonical + b.canonical, pattern: a.pattern + b.pattern, rest: b.rest, branch: a.branch)
    }

    static func apply(_ s: String, _ rmi: RMapEntry) -> KanaRepresentation {
        let longVowel = rmi.text.lastScalar == "o" || rmi.text.lastScalar == "u"
        return KanaRepresentation(canonical: rmi.kana, pattern: longVowel ? rmi.kana + "う?" : rmi.kana,
                                  rest: (rmi.next ?? "") + s.sub(rmi.text.len))
    }

    static func romajiNext(_ s: String) -> [KanaRepresentation] {
        var result: [KanaRepresentation] = []
        guard s.len > 0 else { return result }
        for end in 1...s.len {
            let ss = s.sub(0, end)
            if let rmi = romajiKana[ss] { result.append(apply(s, rmi)) }
            if !romajiKanaNext.contains(ss) { break }
        }
        return result
    }

    static func joinBranches(_ branches: [KanaRepresentation]) -> KanaRepresentation {
        let b0 = branches[0]
        let tails = branches.map { $0.pattern.sub(min($0.branch, $0.pattern.len)) }
        let head = b0.pattern.sub(0, min(b0.branch, b0.pattern.len))
        let joined = head + "(" + tails.joined(separator: "|") + ")"
        let canonical = branches.map(\.canonical).reduce(branches[0].canonical) { $0.len <= $1.len ? $0 : $1 }
        return KanaRepresentation(canonical: canonical, pattern: joined, rest: b0.rest, branch: joined.len)
    }

    static func branchesNext(_ branches: [KanaRepresentation]) -> [KanaRepresentation] {
        let kr = branches[0]
        var nb = lispStableSort(romajiNext(kr.rest).map { concat(kr, $0) } + branches.dropFirst()) { $0.rest.len > $1.rest.len }
        if nb.count == 1 { nb[0].branch = nb[0].pattern.len }
        if nb.count > 1, nb[0].rest.len == nb[nb.count - 1].rest.len { return [joinBranches(nb)] }
        return nb
    }

    /// Converts romaji to (canonical kana, regex pattern of possible kana spellings).
    static func romajiToKana(_ s: String) -> (canonical: String, pattern: String)? {
        var branches = [KanaRepresentation(rest: s.lowercased())]
        while !branches.isEmpty {
            branches = branchesNext(branches)
            if let f = branches.first, f.rest.isEmpty {
                return (f.canonical, "^" + f.pattern + "$")
            }
        }
        return nil
    }
}

/// Converts romaji to kana (`romaji-kana`).
public func romajiToKana(_ romaji: String) -> (canonical: String, pattern: String)? {
    Deromanize.romajiToKana(romaji)
}

extension Ichiran {
    /// `find-kanji-for-pattern`
    func findKanjiForPattern(_ pattern: String) -> (kanji: [String], kana: [String]) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return ([], []) }
        // narrow the search with the first fixed characters of the pattern
        let body = pattern.dropFirst()
        var fixed = String(body.prefix { !"(|)?$".contains($0) })
        if body.dropFirst(fixed.count).first == "?", !fixed.isEmpty { fixed.removeLast() }
        let rows = words(.kana, where: "text LIKE ?", [fixed + "%"])
            .filter { re.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
        let sorted = lispStableSort(rows) { compareCommon($0.common, $1.common) }
        var kanji: [String] = [], kana: [String] = []
        for r in sorted {
            if let k = getKanji(r), !kanji.contains(k) { kanji.append(k) }
            if !kana.contains(r.text) { kana.append(r.text) }
        }
        return (kanji, kana)
    }

    /// Suggests kana and kanji spellings for romaji input (`romaji-suggest`).
    public func romajiSuggest(_ romaji: String) -> (hiragana: [String], katakana: [String], kanji: [String])? {
        synchronized {
            guard let (canon, pattern) = Deromanize.romajiToKana(romaji) else { return nil }
            let (pkanji, pkana) = findKanjiForPattern(pattern)
            var hira: [String] = []
            for h in [canon] + pkana where !hira.contains(h) { hira.append(h) }
            return (hira, hira.map(asKatakana), pkanji)
        }
    }
}
