# BunsetsuKit – porting status

Swift port of [ichiran](https://github.com/tshatrov/ichiran) (MIT). **Work in progress – does not build yet.**

## Done (Sources/BunsetsuKit)
- `Characters.swift`, `Numbers.swift`, `Romanization.swift` – characters.lisp, numbers.lisp, romanize.lisp
- `Database/` – SQLite wrapper + schema mirroring ichiran's PostgreSQL tables
- `Dict/` – dict.lisp core (lookup, conjugation data, best readings, `calc-score`, segmentation, `find-best-path`),
  dict-grammar.lisp (suffixes, synergies, penalties, segfilters), dict-split.lisp runtime (splits, hints),
  dict-counters.lisp
- `Kanji.swift` – kanji.lisp (`match-readings`, kanji info)
- `WordInfo.swift`, `JSON.swift`, `API.swift` – word-info output, gloss JSON, public API
- `Generated/` – splits, hints and errata translated by `Scripts/lisp2swift.py`

## Left to do
1. `DictionaryBuilder` (dict-load.lisp, dict-errata.lisp helpers, dict-custom.lisp, kanjidic loading):
   JMdict XML import, conjugation generation from JMdictDB `kwpos.csv`/`conj.csv`/`conjo.csv`
   (incl. `errata-conj-rules-hook`), secondary conjugations, best readings, errata helpers referenced by
   `Generated/ErrataDefs.swift` (`addReading`, `setCommon`, `deleteSenses`, ...), custom data loaders, kanji stats.
   Store conj descriptions in a `conj_description` table.
2. `bunsetsu` CLI (`Sources/bunsetsu`): romanize / `-i` / `-f` / `build`.
3. deromanize.lisp.
4. Get it compiling, then port tests.lisp into XCTest (DB tests gated on an env var pointing to a built DB).
