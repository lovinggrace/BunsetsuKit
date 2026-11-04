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

### Compact and full databases

ichiran stores every conjugated form of every word as its own dictionary entry; those make up about 95% of
its database. By default `bunsetsu build` writes a **compact** database instead (110 MB instead of 2.1 GB): it
keeps the dictionary entries, the conjugation rules and the conjugations that coincide with dictionary
words, and BunsetsuKit generates the other conjugated forms when text is looked up. It undoes the conjugation
rules to find candidate dictionary forms, then conjugates those exactly like ichiran's loader does (including
words whose conjugated forms coincide, which the loader merges).

The build first creates the full database, then checks for every word that the generated conjugations are
identical to the stored ones. Words where they differ (about ten, because of errata applied after
conjugation) keep their stored conjugations, so results are the same as with the full database.

Generated entries are cached per word group; `Ichiran.virtualCacheLimit` (default 40,000 entries) bounds the
cache. With the default, segmenting the 541 test sentences takes about 4x as long as with the full database
and peaks below 100 MB of memory.

`--format full` writes the full ichiran-style database instead (`--keep-full yes` keeps it next to the
compact one), and `bunsetsu compact FULL_DB JMDICTDB_DATA_DIR OUTPUT` compacts an existing full database.

### Database without glosses

`--no-glosses` drops the English glosses after the build (89 MB instead of 108 MB for a compact database).
Segmentation, romanization and `dictionaryForms(of:)` do not need them; only word descriptions do.
`Ichiran.hasGlosses` tells whether a database has them.

The `Database` workflow builds such a database monthly and publishes it as
`bunsetsu-segmentation.sqlite.gz` (about 35 MB) with metadata in `bunsetsu-segmentation.json`, as assets of the
[`database` release](https://github.com/lovinggrace/BunsetsuKit/releases/tag/database).
To rebuild it outside the schedule (for example after a JMdict fix), run the workflow from the Actions tab
(Database → Run workflow) or with `gh workflow run database.yml`.

### Dictionary forms

`dictionaryForms(of:)` returns the JMdict `seq` numbers of a segmented word's dictionary forms: conjugated forms
map to the word they were conjugated from, compounds to their components (main word first). Since JMdict-based
Yomitan dictionaries such as Jitendex use the same numbers, segments can be linked to their entries.

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
With a compact `BUNSETSU_DB`, setting `BUNSETSU_FULL_DB` to the full database it was built from also checks
that both give identical segmentations.

## Regenerating the data tables

`Sources/BunsetsuKit/Generated` (splits, kana hints, errata) is generated from the ichiran sources:

```bash
python3 Scripts/lisp2swift.py /path/to/ichiran
```

## License

MIT, like Ichiran. Dictionary data (JMdict, KANJIDIC, JMdictDB tables) is subject to its own licenses
(EDRDG licence / GPL for JMdictDB) and is not included.
