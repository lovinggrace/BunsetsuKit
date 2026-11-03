# BunsetsuKit

A Swift port of [Ichiran](https://github.com/tshatrov/ichiran) by Timofei Shatrov: Japanese text segmentation,
romanization and dictionary lookup based on [JMdict](https://www.edrdg.org/jmdict/j_jmdict.html).

The algorithms (dictionary lookup, conjugations, scoring, suffixes, synergies, splits, kana hints, counters)
are ported from the Common Lisp sources; PostgreSQL is replaced by a single SQLite file.

```swift
import BunsetsuKit

let ichiran = try Ichiran(databasePath: "bunsetsu.sqlite")
ichiran.romanize("一覧は最高だぞ")          // "ichiran wa saikō da zo"

let (text, info) = ichiran.romanizeWithInfo("一覧は最高だぞ")
for (word, gloss) in info { print(word, gloss) }

for word in ichiran.simpleSegment(text: "ご注文はうさぎですか") {
    print(word.text, word.kana.values, word.seq)
}

ichiran.romanizeDetailed("一覧は最高だぞ", limit: 5)   // the JSON of `ichiran-cli -f`
```

Romanization methods: `.hepburnTraditional` (default), `.hepburnModified`, `.hepburnSimple`, `.hepburnPassport`,
`.hepburnBasic`, `.kunreiSiki`. Kana-only helpers (`romanizeKana`, `asHiragana`, `asKatakana`, `romajiToKana`)
work without a database.

## Building the database

The database is generated from the dictionary sources (it is not distributed with the package):

1. [JMdict_e](http://ftp.edrdg.org/pub/Nihongo/JMdict_e.gz) (gunzip it)
2. the `jmdictdb/data` directory of [JMdictDB](https://gitlab.com/yamagoya/jmdictdb) (conjugation tables
   `kwpos.csv`, `conj.csv`, `conjo.csv`)
3. optionally [kanjidic2.xml](http://www.edrdg.org/kanjidic/kanjidic2.xml.gz) (needed for some kana hints and kanji info)

```bash
swift run -c release bunsetsu build --jmdict JMdict_e --jmdictdb-data jmdictdb/jmdictdb/data --kanjidic kanjidic2.xml --output bunsetsu.sqlite
```

## Command line

`bunsetsu` mirrors `ichiran-cli`:

```bash
swift run -c release bunsetsu --db bunsetsu.sqlite -i "一覧は最高だぞ"
```

`-i` prints dictionary info, `-f` prints the full segmentation as JSON (`-l` limits the number of segmentations).

## Tests

```bash
BUNSETSU_DB=$PWD/bunsetsu.sqlite swift test
```

The dictionary tests (a port of ichiran's `tests.lisp`) run only when `BUNSETSU_DB` points to a database.

## Regenerating the data tables

`Sources/BunsetsuKit/Generated` (splits, kana hints, errata) is generated from the ichiran sources:

```bash
python3 Scripts/lisp2swift.py /path/to/ichiran
```

## License

MIT, like Ichiran. Dictionary data (JMdict, KANJIDIC, JMdictDB tables) is subject to its own licenses
(EDRDG licence / GPL for JMdictDB) and is not included.
