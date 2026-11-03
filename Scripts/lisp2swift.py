#!/usr/bin/env python3
"""Translates the data-heavy parts of ichiran (splits, hints, errata) into Swift.

Usage: python3 Scripts/lisp2swift.py /path/to/ichiran

Generates:
  Sources/BunsetsuKit/Generated/SplitDefs.swift
  Sources/BunsetsuKit/Generated/HintDefs.swift
  Sources/BunsetsuKit/Generated/ErrataDefs.swift
"""
import os
import re
import sys

# ---------------------------------------------------------------- reader

class Sym(str):
    pass

class Kw(str):
    pass

class Char(str):
    pass

def tokenize(src):
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
        elif c == ';':
            while i < n and src[i] != '\n':
                i += 1
        elif src.startswith('#|', i):
            depth = 1
            i += 2
            while i < n and depth:
                if src.startswith('|#', i):
                    depth -= 1
                    i += 2
                elif src.startswith('#|', i):
                    depth += 1
                    i += 2
                else:
                    i += 1
        elif src.startswith('#-(and)', i):
            yield ('skipnext', None)
            i += 7
        elif c in '()':
            yield (c, None)
            i += 1
        elif c == "'":
            yield ('quote', None)
            i += 1
        elif c == '`':
            yield ('quote', None)
            i += 1
        elif c == '"':
            j = i + 1
            buf = []
            while src[j] != '"':
                if src[j] == '\\':
                    j += 1
                buf.append(src[j])
                j += 1
            yield ('atom', ''.join(buf))
            i = j + 1
        elif src.startswith('#\\', i):
            j = i + 2
            # character name or single char
            m = re.match(r'[A-Za-z_]{2,}', src[j:])
            if m and m.group(0) not in ():
                name = m.group(0)
                yield ('atom', Char(name))
                i = j + len(name)
            else:
                yield ('atom', Char(src[j]))
                i = j + 1
        else:
            j = i
            while j < n and not src[j].isspace() and src[j] not in '()':
                j += 1
            tok = src[i:j]
            i = j
            if re.fullmatch(r'-?\d+', tok):
                yield ('atom', int(tok))
            elif tok.startswith(':'):
                yield ('atom', Kw(tok[1:].lower()))
            else:
                yield ('atom', Sym(tok.lower()))

def parse_all(src):
    toks = list(tokenize(src))
    pos = 0

    def read():
        nonlocal pos
        t, v = toks[pos]
        pos += 1
        if t == '(':
            lst = []
            while toks[pos][0] != ')':
                x = read()
                if x is SKIP:
                    continue
                lst.append(x)
            pos += 1
            return lst
        if t == 'quote':
            return read()
        if t == 'skipnext':
            read()
            return SKIP
        return v

    forms = []
    while pos < len(toks):
        f = read()
        if f is not SKIP:
            forms.append(f)
    return forms

SKIP = object()

CHAR_NAMES = {'hiragana_letter_i': 'い'}

def swift_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

def char_str(c):
    if len(c) == 1:
        return swift_str(c)
    return swift_str(CHAR_NAMES[c.lower()])

# ---------------------------------------------------------------- expressions

class Ctx:
    def __init__(self, names):
        self.names = names  # lisp symbol -> swift expr

def expr(e, ctx, opt=False):
    """Translate a Lisp expression. Returns swift source string.
    Values that may be nil in Lisp are rendered as optionals (Int?)."""
    if isinstance(e, bool):
        return 'true' if e else 'false'
    if isinstance(e, int):
        return str(e)
    if isinstance(e, Char):
        return char_str(e)
    if isinstance(e, Sym):
        if e == 'nil':
            return 'nil'
        if e == 't':
            return 'true'
        if e in ctx.names:
            return ctx.names[e]
        raise ValueError('unknown symbol %r' % e)
    if isinstance(e, Kw):
        return '.' + e
    if isinstance(e, str):
        return swift_str(e)
    head = e[0]
    args = e[1:]
    if head == '-':
        if len(args) == 1:
            return '(-%s)' % expr(args[0], ctx)
        return '(' + ' - '.join(expr(a, ctx) for a in args) + ')'
    if head == '+':
        return '(' + ' + '.join(expr(a, ctx) for a in args) + ')'
    if head == '1+':
        return '(%s + 1)' % expr(args[0], ctx)
    if head == '1-':
        return '(%s - 1)' % expr(args[0], ctx)
    if head == 'position':
        # a missing character makes the Lisp code signal an error; here it yields an invalid length instead
        return '(%s.position(of: %s) ?? -1000)' % (expr(args[1], ctx), char_str(args[0]))
    if head == 'find':
        return '%s.containsScalar(%s)' % (expr(args[1], ctx), char_str(args[0]))
    if head == 'search':
        from_end = ':from-end' in [str(a) for a in args] or Kw('from-end') in args
        return '%s.searchPos(%s, fromEnd: %s)' % (expr(args[1], ctx), expr(args[0], ctx), 'true' if from_end else 'false')
    if head == 'if':
        return '(%s ? %s : %s)' % (cond(args[0], ctx), expr(args[1], ctx), expr(args[2], ctx))
    if head in ('eql', 'equal', '='):
        a, b = args
        if isinstance(a, list) and a[0] == 'word-type':
            return '(%s == %s)' % (expr(a, ctx), {'kanji': '.kanji', 'kana': '.kana'}[b])
        return '(%s == %s)' % (expr(a, ctx), expr(b, ctx))
    if head == 'word-type':
        return 'c.wordType'
    if head == '>':
        return '(%s > %s)' % (expr(args[0], ctx), expr(args[1], ctx))
    if head == 'alexandria:starts-with-subseq':
        return '%s.hasScalarPrefix(%s)' % (expr(args[1], ctx), expr(args[0], ctx))
    if head == 'alexandria:ends-with':
        return '%s.endsWith(%s)' % (expr(args[1], ctx), char_str(args[0]))
    raise ValueError('unknown form %r' % (e,))

def cond(e, ctx):
    return expr(e, ctx)

# ---------------------------------------------------------------- splits

SPLIT_CTX = Ctx({'len': 'c.len', 'txt': 'c.txt', 'r': 'c.r'})

def split_part(p, split_seq, lenvar, txtvar, rvar):
    names = {}
    if lenvar: names[lenvar] = 'c.len'
    if txtvar: names[txtvar] = 'c.txt'
    if rvar: names[rvar] = 'c.r'
    ctx = Ctx(names)
    p = list(p) + [None] * (4 - len(p))
    part_seq, length, conj_p, modify = p[0], p[1], p[2], p[3]
    if part_seq == Kw('test'):
        new_score = 'nil' if conj_p in (None, Sym('nil')) else str(conj_p)
        marker = 'nil' if modify is None else '.' + modify
        return '.test({ c in %s }, newScore: %s, marker: %s)' % (cond(length, ctx), new_score, marker)
    if part_seq in (Kw('score'), Kw('pscore')):
        return '.marker(.%s)' % part_seq
    if isinstance(part_seq, list):
        if part_seq and isinstance(part_seq[0], str) and not isinstance(part_seq[0], (Sym, Kw, Char)):
            seqs = '.lookup(%s, [%s])' % (swift_str(part_seq[0]), ', '.join(str(x) for x in part_seq[1:]))
        else:
            seqs = '.seqs([%s])' % ', '.join(str(x) for x in part_seq)
    else:
        seqs = '.seqs([%d])' % part_seq
    if length is None or length == Sym('nil'):
        lexpr = 'nil'
    elif isinstance(length, list) and length[0] == 'position':
        lexpr = '{ c in %s.position(of: %s) }' % (expr(length[2], ctx), char_str(length[1]))
    else:
        lexpr = '{ c in %s }' % expr(length, ctx)
    conj = 'true' if conj_p not in (None, Sym('nil')) else 'false'
    if modify is None or modify == Sym('nil'):
        mod = '.none'
    elif modify == Sym('t'):
        mod = '.unrendaku'
    elif isinstance(modify, list) and modify[0] == 'optprefix':
        mod = '.optprefix(%s)' % swift_str(modify[1])
    else:
        raise ValueError('modify %r' % (modify,))
    return '.part(%s, length: %s, conj: %s, modify: %s)' % (seqs, lexpr, conj, mod)

def score_swift(score):
    if isinstance(score, int):
        return '.score(%d)' % score
    # segsplit attrs: (score &key primary connector root)
    s = score[0]
    rest = score[1:]
    kw = {}
    i = 0
    while i < len(rest):
        kw[str(rest[i])] = rest[i + 1]
        i += 2
    primary = kw.get('primary', 0)
    connector = kw.get('connector', ' ')
    root = kw.get('root', [])
    return '.attrs(score: %d, primary: %d, connector: %s, root: [%s])' % (
        s, primary, swift_str(connector), ', '.join(str(x) for x in root))

def gen_split(seq, score, vars_, parts):
    lenvar = vars_[0] if len(vars_) > 0 else None
    txtvar = vars_[1] if len(vars_) > 1 else None
    rvar = vars_[2] if len(vars_) > 2 else None
    steps = [split_part(p, seq, lenvar, txtvar, rvar) for p in parts]
    return 'SplitDef(seq: %d, score: %s, steps: [\n        %s,\n    ])' % (seq, score_swift(score), ',\n        '.join(steps))

def translate_splits(forms):
    regular, segsplit = [], []

    def handle(f, out):
        h = f[0]
        if h == 'def-simple-split':
            _, name, seq, score, vars_ = f[:5]
            out.append(gen_split(seq, score, vars_, f[5:]))
        elif h == 'def-de-split':
            seq, seqa = f[1], f[2]
            score = 20
            if len(f) > 3:
                score = f[4]
            out.append(gen_split(seq, score, [Sym('len')], [[seqa, [Sym('-'), Sym('len'), 1]], [2028980, 1]]))
        elif h == 'def-toori-split':
            seq, seqa = f[1], f[2]
            opts = dict(zip([str(x) for x in f[3::2]], f[4::2]))
            score = opts.get('score', 50)
            seqb = opts.get('seq-b', 1432930)
            out.append(gen_split(seq, score, [Sym('len'), Sym('txt'), Sym('r')], [
                [Kw('test'), [Sym('eql'), [Sym('word-type'), Sym('r')], Kw('kanji')]],
                [seqa, [Sym('-'), Sym('len'), 2]],
                [seqb, 2]]))
        elif h == 'def-do-split':
            seq, seqb = f[1], f[2]
            opts = dict(zip([str(x) for x in f[3::2]], f[4::2]))
            score = opts.get('score', 30)
            seqa = opts.get('seq-a', 2252690)
            out.append(gen_split(seq, score, [Sym('len'), Sym('txt'), Sym('r')], [[seqa, 1], [seqb]]))
        elif h == 'def-shi-split':
            seq, seqb = f[1], f[2]
            opts = dict(zip([str(x) for x in f[3::2]], f[4::2]))
            score = opts.get('score', 30)
            seqa = opts.get('seq-a', ["し", 1157170])
            out.append(gen_split(seq, score, [Sym('len'), Sym('txt'), Sym('r')], [[seqa, 1], [seqb, Sym('nil'), Sym('t')]]))
        elif h == 'let':
            for sub in f[2:]:
                handle(sub, segsplit)

    for f in forms:
        if isinstance(f, list) and f:
            handle(f, regular)
    return regular, segsplit

# ---------------------------------------------------------------- hints

def translate_hints(forms):
    out = []  # in definition order: (seqs, swift)
    for f in forms:
        if not isinstance(f, list) or not f:
            continue
        if f[0] == 'def-simple-hint':
            seqs = f[1] if isinstance(f[1], list) else [f[1]]
            vars_ = f[2]
            names = {}
            if len(vars_) > 0: names[vars_[0]] = 'l'
            if len(vars_) > 1: names[vars_[1]] = 'k'
            ctx = Ctx(names)
            body = []
            hints = []
            for (var, val) in f[3:]:
                if var == Kw('test'):
                    body.append('guard %s else { return nil }' % expr(val, ctx))
                elif isinstance(var, Kw):
                    hints.append('(.%s, %s)' % (var, expr(val, ctx)))
                else:
                    sw = 'v_' + var.replace('-', '_')
                    body.append('guard let %s = %s else { return nil }' % (sw, expr(val, ctx)))
                    ctx.names[var] = sw
            body.append('return [%s]' % ', '.join(hints))
            clos = '.simple({ l, k in\n        %s\n    })' % '\n        '.join(body)
            out.append((seqs, clos))
        elif f[0] == 'def-easy-hint':
            out.append(([f[1]], '.easy(%s)' % swift_str(f[2])))
    return out

# ---------------------------------------------------------------- errata

def errata_arg(a):
    if isinstance(a, int):
        return str(a)
    if isinstance(a, Kw):
        if a == 'null':
            return 'nil'
        return '.' + a.replace('-', '')
    if isinstance(a, Sym):
        if a in ('kana-text', 'kanji-text'):
            return '.' + a.split('-')[0]
        if a == 't':
            return 'true'
        if a == 'nil':
            return 'false'
        raise ValueError(a)
    if isinstance(a, str):
        return swift_str(a)
    raise ValueError(a)

ERRATA_SIMPLE = {
    'set-common': lambda a: 'setCommon(%s, %s, %s, %s)' % tuple(errata_arg(x) for x in a),
    'add-sense-prop': lambda a: 'addSenseProp(%s, %s, %s, %s)' % tuple(errata_arg(x) for x in a),
    'delete-sense-prop': lambda a: 'deleteSenseProp(%s, %s, %s)' % tuple(errata_arg(x) for x in a),
    'set-primary-nokanji': lambda a: 'setPrimaryNokanji(%s, %s)' % tuple(errata_arg(x) for x in a),
    'add-conj-reading': lambda a: 'addConjReading(%s, %s)' % tuple(errata_arg(x) for x in a),
    'replace-reading': lambda a: 'replaceReading(%s, %s, %s)' % tuple(errata_arg(x) for x in a),
    'add-primary-nokanji': lambda a: 'addPrimaryNokanji(%s, %s)' % tuple(errata_arg(x) for x in a),
    'replace-reading-conj': lambda a: 'replaceReadingConj(%s, %s, %s, %s)' % tuple(errata_arg(x) for x in a),
    'rearrange-readings-conj': lambda a: 'rearrangeReadingsConj(%s, %s, %s)' % tuple(errata_arg(x) for x in a),
    'rearrange-readings': lambda a: 'rearrangeReadings(%s, %s, %s)' % tuple(errata_arg(x) for x in a),
    'add-gloss': lambda a: 'addGloss(%s, %s, [%s])' % (errata_arg(a[0]), errata_arg(a[1]), ', '.join(errata_arg(x) for x in a[2:])),
    'add-new-sense*': lambda a: 'addNewSense(%s, [%s], [%s])' % (errata_arg(a[0]), errata_arg(a[1]), ', '.join(errata_arg(x) for x in a[2:])),
    'delete-conjugation': lambda a: 'deleteConjugation(%s)' % ', '.join(errata_arg(x) for x in a),
    'delete-senses-all': None,
}

def kwargs(a):
    pos = []
    kw = {}
    i = 0
    while i < len(a):
        if isinstance(a[i], Kw):
            kw[str(a[i])] = a[i + 1]
            i += 2
        else:
            pos.append(a[i])
            i += 1
    return pos, kw

def errata_call(f):
    h, a = f[0], f[1:]
    if h in ('add-reading', 'delete-reading'):
        pos, kw = kwargs(a)
        parts = [errata_arg(x) for x in pos]
        if 'common' in kw: parts.append('common: ' + errata_arg(kw['common']))
        if 'conjugate-p' in kw: parts.append('conjugateP: ' + errata_arg(kw['conjugate-p']))
        if 'table' in kw: parts.append('table: ' + errata_arg(kw['table']))
        fn = 'addReading' if h == 'add-reading' else 'deleteReading'
        return '%s(%s)' % (fn, ', '.join(parts))
    if h in ERRATA_SIMPLE and ERRATA_SIMPLE[h]:
        return ERRATA_SIMPLE[h](a)
    if h == 'mapc' and a[0] == 'set-reading' and a[1][0] == 'select-dao':
        return 'setReadings(%s, %d)' % (errata_arg(a[1][1]), a[1][2][2])
    if h.startswith('add-errata-'):
        return 'addErrata%s()' % ''.join(p.capitalize() for p in h[len('add-errata-'):].split('-'))
    return None

def translate_errata(forms):
    funcs = []
    for f in forms:
        if not (isinstance(f, list) and f and f[0] == 'defun'):
            continue
        name = f[1]
        if not (name.startswith('add-errata-')):
            continue
        body = f[3:]
        if body and isinstance(body[0], str) and not isinstance(body[0], (Sym, Kw, Char)):
            body = body[1:]
        lines = []
        for form in body:
            if not isinstance(form, list):
                continue
            c = errata_call(form)
            if c is None:
                lines.append('// TODO untranslated: %s' % (form[0],))
                raise ValueError('untranslated errata form %r in %s' % (form, name))
            lines.append(c)
        swift_name = 'addErrata' + ''.join(p.capitalize() for p in name[len('add-errata-'):].split('-'))
        funcs.append('    func %s() {\n        %s\n    }' % (swift_name, '\n        '.join(lines)))
    return funcs

def errata_main_body(forms):
    """Translates the simple forms of (defun add-errata ...) - complex forms are handled manually."""
    for f in forms:
        if isinstance(f, list) and f and f[0] == 'defun' and f[1] == 'add-errata':
            out = []
            for form in f[3:]:
                if not isinstance(form, list):
                    continue
                c = errata_call(form)
                if c is None:
                    out.append(None)  # manual
                    out.append(form)
                else:
                    out.append(c)
            return out
    return []

def render_manual(form):
    h = form[0]
    if h == 'conjugate-da': return 'conjugateDa()'
    if h == 'add-deha-ja-readings': return 'addDehaJaReadings()'
    if h == 'remove-hiragana-nokanji': return 'removeHiraganaNokanji()'
    if h == 'add-gozaimasu-conjs': return 'addGozaimasuConjs()'
    if h == 'delete-senses':
        seq, test = form[1], form[2]
        if test == ['constantly', Sym('t')]:
            return 'deleteSenses(%d) { _ in true }' % seq
        # (lambda (prop) (and (equal (text prop) "n") (equal (tag prop) "pos")))
        conds = test[2][1:]
        text = [c[2] for c in conds if c[1][0] == 'text'][0]
        tag = [c[2] for c in conds if c[1][0] == 'tag'][0]
        return 'deleteSenses(%d) { $0.text == %s && $0.tag == %s }' % (seq, swift_str(text), swift_str(tag))
    if h == 'let':
        # (let ((entry (get-dao 'entry 2611370))) (setf (slot-value entry 'root-p) nil) (update-dao entry))
        seq = form[1][0][1][2]
        return 'setRootP(%d, false)' % seq
    if h == 'ichiran/custom:load-custom-data':
        return 'loadCustomData(["extra"])'
    raise ValueError('manual form %r' % (form,))

# ---------------------------------------------------------------- main

HEADER = '// Generated by Scripts/lisp2swift.py from ichiran %s - do not edit.\n\n'

def main():
    root = sys.argv[1]
    outdir = os.path.join(os.path.dirname(__file__), '..', 'Sources', 'BunsetsuKit', 'Generated')
    os.makedirs(outdir, exist_ok=True)

    split_forms = parse_all(open(os.path.join(root, 'dict-split.lisp'), encoding='utf-8').read())
    regular, segsplit = translate_splits(split_forms)
    with open(os.path.join(outdir, 'SplitDefs.swift'), 'w', encoding='utf-8') as out:
        out.write(HEADER % 'dict-split.lisp')
        out.write('// swiftlint:disable all\n\n')
        out.write('let splitDefs: [SplitDef] = [\n    ')
        out.write(',\n    '.join(regular))
        out.write(',\n]\n\n')
        out.write('let segsplitDefs: [SplitDef] = [\n    ')
        out.write(',\n    '.join(segsplit))
        out.write(',\n]\n')

    hints = translate_hints(split_forms)
    with open(os.path.join(outdir, 'HintDefs.swift'), 'w', encoding='utf-8') as out:
        out.write(HEADER % 'dict-split.lisp')
        out.write('// swiftlint:disable all\n\n')
        out.write('let hintDefs: [([Int], HintDef)] = [\n    ')
        out.write(',\n    '.join('([%s], %s)' % (', '.join(str(s) for s in seqs), h) for seqs, h in hints))
        out.write(',\n]\n')

    errata_forms = parse_all(open(os.path.join(root, 'dict-errata.lisp'), encoding='utf-8').read())
    funcs = translate_errata(errata_forms)
    main_body = errata_main_body(errata_forms)
    lines = []
    i = 0
    while i < len(main_body):
        if main_body[i] is None:
            lines.append(render_manual(main_body[i + 1]))
            i += 2
        else:
            lines.append(main_body[i])
            i += 1
    with open(os.path.join(outdir, 'ErrataDefs.swift'), 'w', encoding='utf-8') as out:
        out.write(HEADER % 'dict-errata.lisp')
        out.write('// swiftlint:disable all\n\n')
        out.write('extension DictionaryBuilder {\n')
        out.write('    func addErrata() {\n        %s\n    }\n\n' % '\n        '.join(lines))
        out.write('\n\n'.join(funcs))
        out.write('\n}\n')
    print('splits: %d, segsplits: %d, hints: %d, errata functions: %d' % (len(regular), len(segsplit), len(hints), len(funcs)))

if __name__ == '__main__':
    main()
