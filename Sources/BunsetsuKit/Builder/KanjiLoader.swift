// Port of the kanjidic loader of kanji.lisp

import Foundation

extension DictionaryBuilder {
    func loadKanji(_ node: XNode) {
        let literal = node.first("literal")?.nodeText ?? ""
        var radicalC: Int? = nil, radicalN: Int? = nil
        for r in node.elements("rad_value") {
            let v = Int(r.nodeText)
            if r.attributes["rad_type"] == "classical", radicalC == nil { radicalC = v }
            if r.attributes["rad_type"] == "nelson_c", radicalN == nil { radicalN = v }
        }
        if radicalN == nil { radicalN = radicalC }
        let grade = node.first("grade").flatMap { Int($0.nodeText) }
        let strokes = node.first("stroke_count").flatMap { Int($0.nodeText) }
        let freq = node.first("freq").flatMap { Int($0.nodeText) }
        db.run("INSERT INTO kanji (text, radical_c, radical_n, grade, strokes, freq) VALUES (?, ?, ?, ?, ?, ?)",
               [literal, radicalC, radicalN, grade, strokes, freq])
        let kanjiId = db.lastInsertRowID

        struct RInfo { var okuri: [String]; var type: String; var suffixp: Bool; var prefixp: Bool }
        var order: [String] = []
        var readings: [String: RInfo] = [:]
        for r in node.elements("reading") {
            guard let type = r.attributes["r_type"], type == "ja_on" || type == "ja_kun" else { continue }
            var text = asHiragana(r.nodeText)
            var suffixp = false, prefixp = false
            if text.startsWith("-") { suffixp = true; text = text.sub(1) }
            if text.endsWith("-") { prefixp = true; text = text.sub(0, text.len - 1) }
            var reading = text
            var okuri: String? = nil
            if let dot = text.position(of: ".") {
                reading = text.sub(0, dot)
                okuri = text.sub(dot + 1)
            }
            if var old = readings[reading] {
                if old.type != type { old.type = "ja_onkun" }
                if let okuri { old.okuri.insert(okuri, at: 0) }
                if suffixp { old.suffixp = true }
                if prefixp { old.prefixp = true }
                readings[reading] = old
            } else {
                order.append(reading)
                readings[reading] = RInfo(okuri: okuri.map { [$0] } ?? [], type: type, suffixp: suffixp, prefixp: prefixp)
            }
        }
        for text in order {
            let info = readings[text]!
            db.run("INSERT INTO reading (kanji_id, type, text, suffixp, prefixp) VALUES (?, ?, ?, ?, ?)",
                   [kanjiId, info.type, text, info.suffixp, info.prefixp])
            let rid = db.lastInsertRowID
            for o in info.okuri { db.run("INSERT INTO okurigana (reading_id, text) VALUES (?, ?)", [rid, o]) }
        }
        for n in node.elements("nanori") {
            db.run("INSERT INTO reading (kanji_id, type, text) VALUES (?, 'ja_na', ?)", [kanjiId, asHiragana(n.nodeText)])
        }
        for m in node.elements("meaning") {
            let lang = m.attributes["m_lang"] ?? ""
            if lang == "" || lang == "en" {
                db.run("INSERT INTO meaning (kanji_id, text) VALUES (?, ?)", [kanjiId, m.nodeText])
            }
        }
    }

    func loadKanjidic(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        var cnt = 0
        try db.transaction {
            try StreamingXMLReader(target: "character") { node in
                self.loadKanji(node)
                cnt += 1
            }.parse(data)
        }
        log("\(cnt) kanji loaded")
        ich.resetCaches()
    }

    /// `load-kanji-stats`
    func loadKanjiStats() {
        db.run("UPDATE kanji SET stat_common = 0, stat_irregular = 0")
        db.run("UPDATE reading SET stat_common = 0")
        for k in db.query("SELECT id, text FROM kanji WHERE grade <= 8") {
            let (stats, irregular, total) = ich.kanjiWordStats(k[1].text!)
            db.run("UPDATE kanji SET stat_common = ?, stat_irregular = ? WHERE id = ?", [total, irregular, k[0].int!])
            for (key, count) in stats {
                let parts = key.components(separatedBy: "\u{1}")
                db.run("UPDATE reading SET stat_common = ? WHERE kanji_id = ? AND text = ? AND type = ?",
                       [count, k[0].int!, parts[0], parts[1]])
            }
        }
    }
}
