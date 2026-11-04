// A Bloom filter of the reading texts stored in a compact database: most generated conjugated forms
// are not dictionary words, and this answers that without a database query.

import Foundation

struct BloomFilter {
    private(set) var words: [UInt64]
    let hashes: Int

    init(capacity: Int, bitsPerItem: Int = 12, hashes: Int = 8) {
        let bits = max(64, capacity * bitsPerItem)
        words = Array(repeating: 0, count: (bits + 63) / 64)
        self.hashes = hashes
    }

    init(words: [UInt64], hashes: Int) {
        self.words = words
        self.hashes = hashes
    }

    /// FNV-1a over UTF-8, split into two 32-bit halves for double hashing (stable across processes).
    private func hashPair(_ s: String) -> (UInt64, UInt64) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        let h1 = h & 0xffff_ffff, h2 = (h >> 32) | 1
        return (h1, h2)
    }

    mutating func insert(_ s: String) {
        let (h1, h2) = hashPair(s)
        let m = UInt64(words.count * 64)
        for i in 0..<UInt64(hashes) {
            let bit = (h1 &+ i &* h2) % m
            words[Int(bit / 64)] |= 1 << (bit % 64)
        }
    }

    func mayContain(_ s: String) -> Bool {
        let (h1, h2) = hashPair(s)
        let m = UInt64(words.count * 64)
        for i in 0..<UInt64(hashes) {
            let bit = (h1 &+ i &* h2) % m
            if words[Int(bit / 64)] & (1 << (bit % 64)) == 0 { return false }
        }
        return true
    }

    // MARK: storage (table text_bloom: idx, word)

    static func load(_ db: SQLiteDB) -> BloomFilter? {
        guard !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'text_bloom'").isEmpty,
              let k = DBMeta.value(db, "bloom_hashes").flatMap(Int.init) else { return nil }
        let rows = db.query("SELECT word FROM text_bloom ORDER BY idx")
        return BloomFilter(words: rows.map { UInt64(bitPattern: Int64($0[0].int!)) }, hashes: k)
    }

    func save(_ db: SQLiteDB) {
        db.exec("DROP TABLE IF EXISTS text_bloom; CREATE TABLE text_bloom (idx INTEGER PRIMARY KEY, word INTEGER NOT NULL)")
        for (i, w) in words.enumerated() {
            db.run("INSERT INTO text_bloom (idx, word) VALUES (?, ?)", [i, Int(Int64(bitPattern: w))])
        }
        db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('bloom_hashes', ?)", [String(hashes)])
    }
}
