// Port of ichiran/custom (dict-custom.lisp): extra entries, municipalities and wards

import Foundation

private let municipalityTypes: [Unicode.Scalar: [String]] = [
    "都": ["ﾄ", "と"],
    "道": ["ﾄﾞｳ", "どう"],
    "府": ["ﾌ", "ふ"],
    "県": ["ｹﾝ", "けん"],
    "市": ["ｼ", "し"],
    "町": ["ﾁｮｳ", "ﾏﾁ", "ちょう", "まち"],
    "村": ["ｿﾝ", "ﾑﾗ", "そん", "むら"],
    "区": ["ｸ", "く"],
]

private let municipalityTypesDescription: [Unicode.Scalar: String] = [
    "都": "Metropolis", "府": "Prefecture", "県": "Prefecture", "市": "(city)",
    "町": "(town)", "村": "(village)", "区": "Ward",
]

private let municipalityTypesOrder = "都道府県市区町村".scalars

func municipalityShort(_ text: String, _ reading: String) -> (String, String?) {
    if text.endsWith("道") { return (text, reading) }
    guard let type = text.lastScalar else { return (text, reading) }
    let shortText = text.sub(0, text.len - 1)
    let shortReading = (municipalityTypes[type] ?? []).lazy
        .compactMap { tpr in reading.hasScalarSuffix(tpr) ? reading.sub(0, reading.len - tpr.len) : nil }.first
    return (shortText, shortReading)
}

func romanizeMunicipality(_ text: String, _ reading: String, includeType: Bool = true) -> String {
    let short = municipalityShort(text, reading).1 ?? ""
    var s = romanizeWordGeo(short)
    if includeType, let t = text.lastScalar, let d = municipalityTypesDescription[t] { s += " " + d }
    return s
}

func normalizeGeo(_ word: String) -> String {
    simplifyNgrams(word.lowercased(), [("ū", "u"), ("ō", "o")])
}

/// Simple CSV parsing (no quoted fields in the bundled files)
func readCSV(_ url: URL) throws -> [[String]] {
    try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { $0.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) } }
}

private struct GeoEntry {
    let text: String
    let reading: String
    let definition: String
    let type: Unicode.Scalar
    let prefecture: String?
    let words: [String]
    let isWard: Bool
}

extension DictionaryBuilder {
    static var resourceURL: URL? { Bundle.module.url(forResource: "Resources", withExtension: nil) }

    func resource(_ name: String) throws -> URL {
        guard let base = DictionaryBuilder.resourceURL else { throw DatabaseError(message: "Missing resources") }
        return base.appendingPathComponent(name)
    }

    /// `load-custom-data`
    func loadCustomData(_ keys: [String]?) throws {
        if keys == nil || keys!.contains("extra") { try loadExtraXML() }
        if keys == nil || keys!.contains("municipality") { try insertGeo(try municipalityEntries()) }
        if keys == nil || keys!.contains("ward") { try insertGeo(try wardEntries()) }
    }

    func loadExtraXML() throws {
        let data = try Data(contentsOf: try resource("extra.xml"))
        var entries: [XNode] = []
        try StreamingXMLReader(target: "entry") { entries.append($0) }.parse(data)
        for e in entries {
            let seqText = e.first("ent_seq")?.nodeText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let n = Int(seqText) {
                loadEntry(e, seq: n, ifExists: .skip, conjugateP: true)
            } else {
                loadEntry(e, seqText: seqText, ifExists: .skip, conjugateP: true)
            }
        }
    }

    private func municipalityEntries() throws -> [GeoEntry] {
        var entries: [GeoEntry] = []
        for row in try readCSV(try resource("jichitai.csv")) where row.count >= 5 {
            let (pref, muni, rpref, rmuni) = (row[1], row[2], row[3], row[4])
            let prefectureP = muni.isEmpty
            let text = prefectureP ? pref : muni
            guard let type = text.lastScalar else { continue }
            let reading = prefectureP ? rpref : rmuni
            let short = municipalityShort(text, reading)
            let prefecture = prefectureP ? nil : romanizeMunicipality(pref, rpref)
            let definition = romanizeMunicipality(text, reading) + (prefecture.map { ", " + $0 } ?? "")
            func words() -> [String] {
                var typeword = municipalityTypesDescription[type]
                if let t = typeword, t.hasSuffix(")") { typeword = String(t.dropLast()) }
                let name = definition.components(separatedBy: " ").first ?? ""
                return [name, typeword, prefecture].compactMap { $0 }
            }
            entries.append(GeoEntry(text: text, reading: asHiragana(normalize(reading)), definition: definition, type: type,
                                    prefecture: prefecture, words: words(), isWard: false))
            if type != "道" {
                entries.append(GeoEntry(text: short.0, reading: asHiragana(normalize(short.1 ?? "")), definition: definition, type: type,
                                        prefecture: prefecture, words: words(), isWard: false))
            }
        }
        return lispStableSort(entries) { a, b in
            (municipalityTypesOrder.firstIndex(of: a.type) ?? 99) < (municipalityTypesOrder.firstIndex(of: b.type) ?? 99)
        }
    }

    private func wardEntries() throws -> [GeoEntry] {
        var entries: [GeoEntry] = []
        var cityText = "", cityReading = "", cityRomanized = ""
        for row in try readCSV(try resource("gyoseiku.csv")) where row.count >= 3 {
            let text = row[1], reading = row[2]
            if text.endsWith("区") {
                let wardText = text.sub(min(cityText.len, text.len))
                let wardReading = reading.sub(min(cityReading.len, reading.len))
                let definition = romanizeMunicipality(wardText, wardReading) + ", " + cityRomanized
                let name = definition.components(separatedBy: " ").first ?? ""
                entries.append(GeoEntry(text: wardText, reading: wardReading, definition: definition, type: "区",
                                        prefecture: cityRomanized, words: [name, "Ward", cityRomanized], isWard: true))
            } else {
                cityText = text
                cityReading = reading
                cityRomanized = romanizeMunicipality(text, reading, includeType: false)
            }
        }
        return entries
    }

    private func updateGlossRegex(_ e: GeoEntry) -> NSRegularExpression? {
        guard !e.isWard, let name = e.words.first else { return nil }
        let q = NSRegularExpression.escapedPattern(for: name)
        let pattern: String
        switch e.type {
        case "市":
            let pref = NSRegularExpression.escapedPattern(for: e.prefecture?.components(separatedBy: " ").first ?? "")
            pattern = "^\(q) \\(city(| in \(pref))\\)$"
        case "県":
            pattern = "^\(q) \\((|city, )prefecture\\)$"
        default:
            return nil
        }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func getCandidates(_ text: String, _ reading: String) -> [Int] {
        if testWord(text, .kana) {
            return db.column("""
                SELECT e.seq FROM entry e LEFT JOIN kana_text r ON e.seq = r.seq LEFT JOIN kanji_text k ON e.seq = k.seq
                WHERE e.root_p AND k.text IS NULL AND r.text = ? AND r.ord = 0 ORDER BY e.seq
                """, [text]).compactMap(\.int)
        }
        return db.column("""
            SELECT e.seq FROM entry e LEFT JOIN kana_text r ON e.seq = r.seq LEFT JOIN kanji_text k ON e.seq = k.seq
            WHERE k.text = ? AND k.ord = 0 AND r.text = ? AND r.ord = 0 ORDER BY e.seq
            """, [text, reading]).compactMap(\.int)
    }

    enum GlossMatch {
        case seq(Int)
        case gloss(Int, String)
    }

    /// `match-glosses`
    func matchGlosses(_ text: String, _ reading: String, _ words: [String], normalize norm: (String) -> String,
                      updateGloss: NSRegularExpression?) -> (GlossMatch, Bool)? {
        let candidates = getCandidates(text, reading)
        guard let first = candidates.first else { return nil }
        let nwords = words.map(norm)
        for seq in candidates {
            let glosses = db.column("SELECT gloss.text FROM gloss, sense WHERE sense.seq = ? AND gloss.sense_id = sense.id ORDER BY sense.id, gloss.id",
                                    [seq]).compactMap(\.text)
            for gloss in glosses {
                let ngloss = norm(gloss)
                if let re = updateGloss, re.firstMatch(in: ngloss, range: NSRange(ngloss.startIndex..., in: ngloss)) != nil {
                    return (.gloss(seq, gloss), true)
                }
                if nwords.allSatisfy({ ngloss.scalarSearch($0) }) { return (.seq(seq), true) }
            }
        }
        return (.seq(first), false)
    }

    private func insertGeo(_ entries: [GeoEntry]) throws {
        var curSeq = nextSeq()
        for e in entries {
            let m = matchGlosses(e.text, e.reading, e.words, normalize: normalizeGeo, updateGloss: updateGlossRegex(e))
            switch m {
            case nil:
                loadEntry(asXMLSimple(e.text, e.reading, e.definition), seq: curSeq)
                curSeq += 1
            case (.gloss(let seq, let gloss), _)?:
                if !e.isWard {
                    db.run("UPDATE gloss SET text = ? WHERE text = ? AND sense_id IN (SELECT id FROM sense WHERE seq = ?)",
                           [e.definition, gloss, seq])
                }
            case (.seq, true)?:
                break
            case (.seq(let seq), false)?:
                addNewSense(seq, ["n"], [e.definition])
            }
        }
    }

    func asXMLSimple(_ text: String, _ reading: String, _ definition: String) -> XNode {
        func el(_ name: String, _ text: String = "", _ children: [XNode] = []) -> XNode {
            let n = XNode(name: name, attributes: [:])
            n.text = text
            n.children = children
            return n
        }
        var children = [el("ent_seq")]
        if testWord(text, .kana) {
            children.append(el("r_ele", "", [el("reb", text)]))
        } else {
            children.append(el("k_ele", "", [el("keb", text)]))
            children.append(el("r_ele", "", [el("reb", reading)]))
        }
        children.append(el("sense", "", [el("pos", "n"), el("gloss", definition)]))
        return el("entry", "", children)
    }
}
