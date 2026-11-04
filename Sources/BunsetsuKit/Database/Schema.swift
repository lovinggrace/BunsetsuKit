// Database schema, mirroring ichiran's PostgreSQL tables (dict.lisp, kanji.lisp).

enum Schema {
    static let dictTables = """
    CREATE TABLE IF NOT EXISTS entry (
        seq INTEGER PRIMARY KEY,
        content TEXT NOT NULL DEFAULT '',
        root_p INTEGER NOT NULL DEFAULT 0,
        n_kanji INTEGER NOT NULL DEFAULT 0,
        n_kana INTEGER NOT NULL DEFAULT 0,
        primary_nokanji INTEGER NOT NULL DEFAULT 0,
        materialized INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS kanji_text (
        id INTEGER PRIMARY KEY,
        seq INTEGER NOT NULL,
        text TEXT NOT NULL,
        ord INTEGER NOT NULL,
        common INTEGER,
        common_tags TEXT NOT NULL DEFAULT '',
        conjugate_p INTEGER NOT NULL DEFAULT 1,
        nokanji INTEGER NOT NULL DEFAULT 0,
        best_kana TEXT
    );
    CREATE TABLE IF NOT EXISTS kana_text (
        id INTEGER PRIMARY KEY,
        seq INTEGER NOT NULL,
        text TEXT NOT NULL,
        ord INTEGER NOT NULL,
        common INTEGER,
        common_tags TEXT NOT NULL DEFAULT '',
        conjugate_p INTEGER NOT NULL DEFAULT 1,
        nokanji INTEGER NOT NULL DEFAULT 0,
        best_kanji TEXT
    );
    CREATE TABLE IF NOT EXISTS sense (
        id INTEGER PRIMARY KEY,
        seq INTEGER NOT NULL,
        ord INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS gloss (
        id INTEGER PRIMARY KEY,
        sense_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        ord INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sense_prop (
        id INTEGER PRIMARY KEY,
        tag TEXT NOT NULL,
        sense_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        ord INTEGER NOT NULL,
        seq INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS restricted_readings (
        id INTEGER PRIMARY KEY,
        seq INTEGER NOT NULL,
        reading TEXT NOT NULL,
        text TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS conjugation (
        id INTEGER PRIMARY KEY,
        seq INTEGER NOT NULL,
        "from" INTEGER NOT NULL,
        via INTEGER
    );
    CREATE TABLE IF NOT EXISTS conj_prop (
        id INTEGER PRIMARY KEY,
        conj_id INTEGER NOT NULL,
        conj_type INTEGER NOT NULL,
        pos TEXT NOT NULL,
        neg INTEGER,
        fml INTEGER
    );
    CREATE TABLE IF NOT EXISTS conj_source_reading (
        id INTEGER PRIMARY KEY,
        conj_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        source_text TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
    );
    """

    static let dictIndexes = """
    CREATE INDEX IF NOT EXISTS kanji_text_seq ON kanji_text(seq);
    CREATE INDEX IF NOT EXISTS kanji_text_text ON kanji_text(text);
    CREATE INDEX IF NOT EXISTS kana_text_seq ON kana_text(seq);
    CREATE INDEX IF NOT EXISTS kana_text_text ON kana_text(text);
    CREATE INDEX IF NOT EXISTS sense_seq ON sense(seq);
    CREATE INDEX IF NOT EXISTS gloss_sense_id ON gloss(sense_id);
    CREATE INDEX IF NOT EXISTS sense_prop_sense_id_tag ON sense_prop(sense_id, tag);
    CREATE INDEX IF NOT EXISTS sense_prop_tag_text ON sense_prop(tag, text);
    CREATE INDEX IF NOT EXISTS sense_prop_seq_tag_text ON sense_prop(seq, tag, text);
    CREATE INDEX IF NOT EXISTS restricted_readings_seq_reading ON restricted_readings(seq, reading);
    CREATE INDEX IF NOT EXISTS conjugation_seq ON conjugation(seq);
    CREATE INDEX IF NOT EXISTS conjugation_from ON conjugation("from");
    CREATE INDEX IF NOT EXISTS conj_prop_conj_id ON conj_prop(conj_id);
    CREATE INDEX IF NOT EXISTS conj_source_reading_conj_id_text ON conj_source_reading(conj_id, text);
    """

    /// Tables of compact databases (conjugations computed at lookup time)
    static let compactTables = """
    CREATE TABLE IF NOT EXISTS pos_index (
        id INTEGER PRIMARY KEY,
        pos TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS conj_rule (
        id INTEGER PRIMARY KEY,
        pos_id INTEGER NOT NULL,
        conj INTEGER NOT NULL,
        neg INTEGER NOT NULL,
        fml INTEGER NOT NULL,
        onum INTEGER NOT NULL,
        stem INTEGER NOT NULL,
        okuri TEXT NOT NULL,
        euphr TEXT NOT NULL,
        euphk TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS pos_ending (
        pos_id INTEGER NOT NULL,
        len INTEGER NOT NULL,
        ending TEXT NOT NULL,
        PRIMARY KEY (pos_id, len, ending)
    );
    CREATE TABLE IF NOT EXISTS conj_group (
        seq INTEGER PRIMARY KEY,
        grp INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS conj_group_grp ON conj_group(grp);
    CREATE TABLE IF NOT EXISTS materialized_from (
        seq INTEGER PRIMARY KEY
    );
    """

    static let kanjiTables = """
    CREATE TABLE IF NOT EXISTS kanji (
        id INTEGER PRIMARY KEY,
        text TEXT NOT NULL,
        radical_c INTEGER,
        radical_n INTEGER,
        grade INTEGER,
        strokes INTEGER,
        freq INTEGER,
        stat_common INTEGER NOT NULL DEFAULT 0,
        stat_irregular INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS reading (
        id INTEGER PRIMARY KEY,
        kanji_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        text TEXT NOT NULL,
        suffixp INTEGER NOT NULL DEFAULT 0,
        prefixp INTEGER NOT NULL DEFAULT 0,
        stat_common INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS okurigana (
        id INTEGER PRIMARY KEY,
        reading_id INTEGER NOT NULL,
        text TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS meaning (
        id INTEGER PRIMARY KEY,
        kanji_id INTEGER NOT NULL,
        text TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS kanji_text_idx ON kanji(text);
    CREATE INDEX IF NOT EXISTS kanji_grade ON kanji(grade);
    CREATE INDEX IF NOT EXISTS reading_kanji_id ON reading(kanji_id);
    CREATE INDEX IF NOT EXISTS reading_text ON reading(text);
    CREATE INDEX IF NOT EXISTS okurigana_reading_id ON okurigana(reading_id);
    CREATE INDEX IF NOT EXISTS meaning_kanji_id ON meaning(kanji_id);
    """
}
