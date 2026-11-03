// Port of the helper functions of dict-errata.lisp

import Foundation

extension DictionaryBuilder {
    func tableFor(_ text: String, _ table: ReadingTable?) -> ReadingTable { table ?? ReadingTable.forText(text) }

    func addCountDelta(_ seq: Int, _ table: ReadingTable, _ delta: Int) {
        let col = table == .kana ? "n_kana" : "n_kanji"
        db.run("UPDATE entry SET \(col) = \(col) + ? WHERE seq = ?", [delta, seq])
    }

    /// `find-conj`
    func findConj(_ seqFrom: Int, _ conjType: Int, _ pos: String, _ neg: Bool?, _ fml: Bool?) -> [Int] {
        db.column("""
            SELECT conj.id FROM conjugation conj INNER JOIN conj_prop prop ON prop.conj_id = conj.id
            WHERE conj."from" = ? AND prop.conj_type = ? AND prop.pos = ? AND prop.neg IS ? AND prop.fml IS ?
            """, [seqFrom, conjType, pos, neg, fml]).compactMap(\.int)
    }

    /// `add-conj`
    func addConj(_ seqFrom: Int, _ conjType: Int, _ pos: String, _ neg: Bool?, _ fml: Bool?, _ readingMap: [(String, String)]) {
        guard findConj(seqFrom, conjType, pos, neg, fml).isEmpty else { return }
        let next = nextSeq()
        db.run("INSERT INTO entry (seq, content, root_p) VALUES (?, '', 0)", [next])
        var ordR = 0, ordK = 0
        for (_, reading) in readingMap {
            let isKana = testWord(reading, .kana)
            let table: ReadingTable = isKana ? .kana : .kanji
            db.run("INSERT INTO \(table.rawValue) (seq, text, ord, common) VALUES (?, ?, ?, NULL)", [next, reading, isKana ? ordR : ordK])
            if isKana { ordR += 1 } else { ordK += 1 }
        }
        db.run("INSERT INTO conjugation (seq, \"from\", via) VALUES (?, ?, NULL)", [next, seqFrom])
        let conjId = db.lastInsertRowID
        db.run("INSERT INTO conj_prop (conj_id, pos, conj_type, neg, fml) VALUES (?, ?, ?, ?, ?)", [conjId, pos, conjType, neg, fml])
        for (src, reading) in readingMap {
            db.run("INSERT INTO conj_source_reading (conj_id, text, source_text) VALUES (?, ?, ?)", [conjId, reading, src])
        }
    }

    /// `add-reading`
    func addReading(_ seq: Int, _ reading: String, common: Int? = nil, conjugateP: Bool = true, table: ReadingTable? = nil) {
        let table = tableFor(reading, table)
        guard db.query("SELECT id FROM \(table.rawValue) WHERE seq = ? AND text = ?", [seq, reading]).isEmpty else { return }
        let maxord = db.single("SELECT MAX(ord) FROM \(table.rawValue) WHERE seq = ?", [seq]).int
        db.run("INSERT INTO \(table.rawValue) (text, seq, ord, common, conjugate_p) VALUES (?, ?, ?, ?, ?)",
               [reading, seq, maxord.map { $0 + 1 } ?? 0, common, conjugateP])
        addCountDelta(seq, table, 1)
    }

    /// `replace-reading`
    func replaceReading(_ seq: Int, _ from: String, _ to: String) {
        let table = ReadingTable.forText(from)
        if db.run("UPDATE \(table.rawValue) SET text = ? WHERE seq = ? AND text = ?", [to, seq, from]) > 0 {
            resetReadings([seq])
        }
    }

    /// `replace-reading-conj`
    func replaceReadingConj(_ seq: Int, _ table: ReadingTable, _ prefixFrom: String, _ prefixTo: String) {
        let seqs = [seq] + db.column("SELECT DISTINCT seq FROM conjugation WHERE \"from\" = ?", [seq]).compactMap(\.int)
        var toUpdate: [Int] = []
        for r in db.query("SELECT id, seq, text FROM \(table.rawValue) WHERE seq IN \(placeholders(seqs.count)) ORDER BY seq",
                          seqs.map { $0 as SQLBindable }) where r[2].text!.hasScalarPrefix(prefixFrom) {
            db.run("UPDATE \(table.rawValue) SET text = ? WHERE id = ?", [prefixTo + r[2].text!.sub(prefixFrom.len), r[0].int!])
            toUpdate.append(r[1].int!)
        }
        if !toUpdate.isEmpty { resetReadings(toUpdate) }
    }

    /// `reset-readings`
    func resetReadings(_ seqs: [Int]) {
        let p = placeholders(seqs.count)
        setReading(.kana, where: "seq IN \(p)", seqs)
        setReading(.kanji, where: "seq IN \(p)", seqs)
    }

    func setReadings(_ table: ReadingTable, _ seq: Int) {
        setReading(table, where: "seq = ?", [seq])
    }

    /// `delete-reading`
    func deleteReading(_ seq: Int, _ reading: String, table: ReadingTable? = nil) {
        let table = tableFor(reading, table)
        let deleted = db.run("DELETE FROM \(table.rawValue) WHERE seq = ? AND text = ?", [seq, reading])
        guard deleted > 0 else { return }
        addCountDelta(seq, table, -deleted)
        for (ord, r) in db.query("SELECT id FROM \(table.rawValue) WHERE seq = ? ORDER BY ord, id", [seq]).enumerated() {
            db.run("UPDATE \(table.rawValue) SET ord = ? WHERE id = ?", [ord, r[0].int!])
        }
        resetReadings([seq])
    }

    func rootDiff(_ base: String, _ reading: String) -> (Int, Int) {
        let b = base.scalars, r = reading.scalars
        var ib = b.count - 1, ir = r.count - 1
        while ib >= 0 && ir >= 0 {
            if b[ib] != r[ir] { return (ib + 1, ir + 1) }
            ib -= 1
            ir -= 1
        }
        return r.count >= b.count ? (0, r.count - b.count) : (b.count - r.count, 0)
    }

    /// `add-conj-reading`
    func addConjReading(_ seq: Int, _ reading: String) {
        let table = ReadingTable.forText(reading)
        guard let baseText = db.single("SELECT text FROM \(table.rawValue) WHERE seq = ? AND ord = 0", [seq]).text else { return }
        let (b, r) = rootDiff(baseText, reading)
        let diff = { (text: String) in reading.sub(0, r) + text.sub(min(b, text.len)) }
        for conj in ich.conjugationRows(where: "\"from\" = ?", [seq]) {
            guard let base = db.query("SELECT text, conjugate_p FROM \(table.rawValue) WHERE seq = ? AND ord = 0", [conj.seq]).first else { continue }
            let newText = diff(base[0].text!)
            guard db.query("SELECT id FROM \(table.rawValue) WHERE seq = ? AND text = ?", [conj.seq, newText]).isEmpty else { continue }
            let maxord = db.single("SELECT MAX(ord) FROM \(table.rawValue) WHERE seq = ?", [conj.seq]).int ?? 0
            let source = db.single("SELECT source_text FROM conj_source_reading WHERE conj_id = ? AND text = ?", [conj.id, base[0].text!]).text ?? ""
            db.run("INSERT INTO \(table.rawValue) (text, seq, ord, common, conjugate_p) VALUES (?, ?, ?, NULL, ?)",
                   [newText, conj.seq, maxord, base[1].bool ?? true])
            db.run("INSERT INTO conj_source_reading (conj_id, text, source_text) VALUES (?, ?, ?)", [conj.id, newText, diff(source)])
            addCountDelta(conj.seq, table, 1)
        }
    }

    struct SensePropRow {
        let senseId: Int
        let tag: String
        let text: String
    }

    /// `delete-senses`
    func deleteSenses(_ seq: Int, _ test: (SensePropRow) -> Bool) {
        let props = db.query("SELECT sense_id, tag, text FROM sense_prop WHERE seq = ?", [seq])
            .map { SensePropRow(senseId: $0[0].int!, tag: $0[1].text!, text: $0[2].text!) }.filter(test)
        let ids = Array(Set(props.map(\.senseId)))
        guard !ids.isEmpty else { return }
        let p = placeholders(ids.count)
        db.run("DELETE FROM sense_prop WHERE sense_id IN \(p)", ids)
        db.run("DELETE FROM gloss WHERE sense_id IN \(p)", ids)
        db.run("DELETE FROM sense WHERE id IN \(p)", ids)
    }

    func deleteSenseProp(_ seq: Int, _ tag: String, _ text: String) {
        db.run("DELETE FROM sense_prop WHERE seq = ? AND tag = ? AND text = ?", [seq, tag, text])
    }

    func addSenseProp(_ seq: Int, _ senseOrd: Int, _ tag: String, _ text: String) {
        guard let senseId = db.single("SELECT id FROM sense WHERE seq = ? AND ord = ? ORDER BY id", [seq, senseOrd]).int else { return }
        if db.query("SELECT id FROM sense_prop WHERE sense_id = ? AND tag = ? AND text = ?", [senseId, tag, text]).isEmpty {
            db.run("INSERT INTO sense_prop (sense_id, tag, text, ord, seq) VALUES (?, ?, ?, 0, ?)", [senseId, tag, text, seq])
        }
    }

    func addSense(_ seq: Int, _ ord: Int, _ glosses: [String]) {
        guard db.query("SELECT id FROM sense WHERE seq = ? AND ord = ?", [seq, ord]).isEmpty else { return }
        db.run("INSERT INTO sense (seq, ord) VALUES (?, ?)", [seq, ord])
        let sid = db.lastInsertRowID
        for (g, gloss) in glosses.enumerated() {
            db.run("INSERT INTO gloss (sense_id, text, ord) VALUES (?, ?, ?)", [sid, gloss, g])
        }
    }

    /// `add-new-sense`
    @discardableResult
    func addNewSense(_ seq: Int, _ positions: [String], _ glosses: [String]) -> Int? {
        let senses = ich.getSensesRaw(seq)
        let glossesStr = glosses.joined(separator: "; ")
        var rpos: [String]? = nil
        for s in senses {
            rpos = s.prop("pos") ?? rpos
            if rpos == positions && glossesStr == s.gloss { return nil }
        }
        let ord = (senses.last?.ord ?? -1) + 1
        let lastPos = senses.reversed().lazy.compactMap { $0.prop("pos") }.first
        db.run("INSERT INTO sense (seq, ord) VALUES (?, ?)", [seq, ord])
        let sid = db.lastInsertRowID
        for (g, gloss) in glosses.enumerated() {
            db.run("INSERT INTO gloss (sense_id, text, ord) VALUES (?, ?, ?)", [sid, gloss, g])
        }
        if lastPos != positions {
            for (o, pos) in positions.enumerated() {
                db.run("INSERT INTO sense_prop (sense_id, tag, text, ord, seq) VALUES (?, 'pos', ?, ?, ?)", [sid, pos, o, seq])
            }
        }
        return sid
    }

    func addGloss(_ seq: Int, _ ord: Int, _ texts: [String]) {
        guard let sid = db.single("SELECT id FROM sense WHERE seq = ? AND ord = ?", [seq, ord]).int else { return }
        let existing = db.query("SELECT text, ord FROM gloss WHERE sense_id = ? ORDER BY ord DESC", [sid])
        var maxOrd = (existing.first?[1].int).map { $0 + 1 } ?? 0
        let texts0 = Set(existing.map { $0[0].text! })
        for t in texts where !texts0.contains(t) {
            db.run("INSERT INTO gloss (sense_id, text, ord) VALUES (?, ?, ?)", [sid, t, maxOrd])
            maxOrd += 1
        }
    }

    func setCommon(_ table: ReadingTable, _ seq: Int, _ text: String, _ common: Int?) {
        db.run("UPDATE \(table.rawValue) SET common = ? WHERE seq = ? AND text = ?", [common, seq, text])
    }

    func setRootP(_ seq: Int, _ value: Bool) {
        db.run("UPDATE entry SET root_p = ? WHERE seq = ?", [value, seq])
    }

    func addDehaJaReadings() {
        for r in db.query("""
            SELECT DISTINCT conj.seq, kt.text FROM conjugation conj, kana_text kt
            WHERE conj."from" = 2089020 AND kt.seq = conj.seq AND kt.text LIKE 'では%'
            """) {
            addReading(r[0].int!, "じゃ" + r[1].text!.sub(2))
        }
        for r in db.query("""
            SELECT csr.conj_id, csr.text, csr.source_text FROM conjugation conj, conj_source_reading csr
            WHERE conj."from" = 2089020 AND csr.conj_id = conj.id AND csr.text LIKE 'では%'
            """) {
            let conjId = r[0].int!, text = r[1].text!, source = r[2].text!
            let ja = "じゃ" + text.sub(2)
            if db.query("SELECT id FROM conj_source_reading WHERE conj_id = ? AND text = ? AND source_text = ?", [conjId, ja, source]).isEmpty {
                db.run("INSERT INTO conj_source_reading (conj_id, text, source_text) VALUES (?, ?, ?)",
                       [conjId, ja, source.hasScalarPrefix("では") ? "じゃ" + source.sub(2) : source])
            }
        }
    }

    /// `delete-conjugation`
    func deleteConjugation(_ seq: Int, _ from: Int, _ via: Int? = nil) {
        let conjIds = db.column("SELECT id FROM conjugation WHERE seq = ? AND \"from\" = ? AND via IS ?", [seq, from, via]).compactMap(\.int)
        guard !conjIds.isEmpty, let entry = ich.getEntry(seq) else { return }
        let p = placeholders(conjIds.count)
        let others = db.query("SELECT id FROM conjugation WHERE seq = ? AND id NOT IN \(p)", [seq] + conjIds.map { $0 as SQLBindable })
        let deleteEntryP = !(entry.rootP || !others.isEmpty)
        db.run("DELETE FROM conj_prop WHERE conj_id IN \(p)", conjIds)
        db.run("DELETE FROM conj_source_reading WHERE conj_id IN \(p)", conjIds)
        db.run("DELETE FROM conjugation WHERE id IN \(p)", conjIds)
        if deleteEntryP { deleteEntry(seq) }
        ich.entryCache[seq] = nil
    }

    func removeHiraganaNokanji() {
        let seqs = db.query("SELECT seq, text FROM kana_text WHERE nokanji").filter { testWord($0[1].text!, .hiragana) }.map { $0[0].int! }
        for chunk in chunked(Array(Set(seqs))) {
            db.run("UPDATE entry SET primary_nokanji = 0 WHERE primary_nokanji AND seq IN \(placeholders(chunk.count))", chunk)
        }
    }

    func setPrimaryNokanji(_ seq: Int, _ value: Bool) {
        db.run("UPDATE entry SET primary_nokanji = ? WHERE seq = ?", [value, seq])
    }

    /// Rearrange readings with prefix before the rest of them
    func rearrangeReadings(_ seq: Int, _ table: ReadingTable, _ prefix: String) {
        let rows = db.query("SELECT id, text FROM \(table.rawValue) WHERE seq = ? ORDER BY ord, id", [seq])
        let offset = rows.filter { $0[1].text!.hasScalarPrefix(prefix) }.count
        var cnt1 = -1, cnt2 = offset - 1
        for r in rows {
            let newOrd: Int
            if r[1].text!.hasScalarPrefix(prefix) { cnt1 += 1; newOrd = cnt1 } else { cnt2 += 1; newOrd = cnt2 }
            db.run("UPDATE \(table.rawValue) SET ord = ? WHERE id = ?", [newOrd, r[0].int!])
        }
    }

    func rearrangeReadingsConj(_ seq: Int, _ table: ReadingTable, _ prefix: String) {
        rearrangeReadings(seq, table, prefix)
        for s in db.column("SELECT DISTINCT seq FROM conjugation WHERE \"from\" = ?", [seq]).compactMap(\.int) {
            rearrangeReadings(s, table, prefix)
        }
    }

    func addPrimaryNokanji(_ seq: Int, _ reading: String) {
        setPrimaryNokanji(seq, true)
        db.run("UPDATE kana_text SET nokanji = 1 WHERE seq = ? AND text = ?", [seq, reading])
    }

    func addGozaimasuConjs() {
        for seq in [1612690, 2253080] {
            let readings = getAllReadings(seq)
            let pos = seq == 2253080 ? "cop" : "exp"
            let forms: [(Int, Bool?, String)] = [(1, true, "せん"), (2, nil, "した"), (3, nil, "して"), (9, nil, "しょう"),
                                                  (11, nil, "したら"), (12, nil, "したり")]
            for (type, neg, suf) in forms {
                addConj(seq, type, pos, neg, nil, readings.map { ($0, applyPatch($0, (suf, "す"))) })
            }
        }
    }

    /// JMdict might have renamed cop-da to cop, but the data csvs still use cop-da
    func conjugateDa(seq: Int = 2089020) {
        if db.query("SELECT id FROM sense_prop WHERE seq = ? AND tag = 'pos' AND text = 'cop-da'", [seq]).isEmpty {
            addSenseProp(seq, 0, "pos", "cop-da")
            conjugateEntryOuter(seq)
        }
    }
}
