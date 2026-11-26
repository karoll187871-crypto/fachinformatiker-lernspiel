# Importiert die Lernkarten der cwillam-Tracker (AGPL-3.0) als Karteikarten.
# Quelle: https://github.com/cwillam/ap1-tracker, ap2-tracker, ap2-fisi-tracker
# Aufruf: python tool/cwillam_import.py <ordner mit heruntergeladenen *.questions.js / *.data.js>
# Ergebnis: assets/questions/lernkarten.json
#
# Die JS-Dateien werden NICHT ausgeführt, sondern nur als Text geparst.
import json, pathlib, re, sys

REPOS = {
    'ap1-tracker': ('AP1', 'AP1'),
    'ap2-tracker': ('AP2', 'AP2 FIAE'),
    'ap2-fisi-tracker': ('AP2', 'AP2 FISI'),
}

STR = r"'((?:[^'\\]|\\.)*)'"
CARD = re.compile(r"\{\s*id:\s*" + STR + r",\s*q:\s*" + STR + r",\s*a:\s*" + STR + r"\s*\}", re.S)
KEY = re.compile(r"^\s*'([\w.\-]+)'\s*:\s*\[", re.M)
TOPIC = re.compile(r"id:\s*'([\w.\-]+)',\s*\n?\s*(?:title|name):\s*" + STR)


def unescape(s: str) -> str:
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            n = s[i + 1]
            out.append({'n': '\n', 't': '  ', "'": "'", '"': '"', '\\': '\\'}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out).strip()


WORD = re.compile(r"[a-zäöüß0-9]+")


def words(t: str) -> set:
    return {w for w in WORD.findall(t.lower()) if len(w) > 3}


def usable(c) -> bool:
    """Karte passt als 3-Antworten-Frage ins Rennen?"""
    return len(c['antwort']) <= 150 and chr(10) not in c['antwort'] and len(c['frage']) <= 170


def add_distractors(cards):
    """Für passende Karten zwei falsche Antworten aus demselben Thema wählen.
    Ausgeschlossen werden Antworten, die der richtigen zu ähnlich sind."""
    import random
    by_topic = {}
    for i, c in enumerate(cards):
        by_topic.setdefault((c['bereich'], c['thema']), []).append(i)
    ok = 0
    for i, c in enumerate(cards):
        if not usable(c):
            continue
        rng = random.Random(c['id'])
        a = c['antwort']
        wa, wq = words(a), words(c['frage'])
        cands = []
        for j in by_topic[(c['bereich'], c['thema'])]:
            d = cards[j]
            if j == i or not usable(d) or d['antwort'] == a:
                continue
            wd = words(d['antwort'])
            union = wa | wd
            if union and len(wa & wd) / len(union) > 0.25:
                continue  # zu ähnlich -> könnte auch richtig sein
            if wq and len(wq & words(d['frage'])) / len(wq | words(d['frage'])) > 0.6:
                continue  # fast gleiche Frage
            ratio = len(d['antwort']) / max(1, len(a))
            cands.append((abs(1 - ratio), j))
        if len(cands) < 2:
            continue
        cands.sort()
        pool = [j for _, j in cands[:6]]
        c['f'] = rng.sample(pool, 2)
        ok += 1
    print(f'{ok} Karten als Lauffragen nutzbar')


def main():
    src = pathlib.Path(sys.argv[1])
    root = pathlib.Path(__file__).resolve().parent.parent
    cards = []
    for repo, (exam, track) in REPOS.items():
        qjs = (src / f'{repo}.questions.js').read_text(encoding='utf-8')
        djs = (src / f'{repo}.data.js').read_text(encoding='utf-8')
        titles = {m.group(1): unescape(m.group(2)) for m in TOPIC.finditer(djs)}
        keys = [(m.start(), m.group(1)) for m in KEY.finditer(qjs)]
        n = 0
        for m in CARD.finditer(qjs):
            key = None
            for pos, k in keys:
                if pos < m.start():
                    key = k
                else:
                    break
            cards.append({
                'id': f'{repo}:{unescape(m.group(1))}',
                'pruefung': exam,
                'bereich': track,
                'thema': titles.get(key, key or 'Allgemein'),
                'frage': unescape(m.group(2)),
                'antwort': unescape(m.group(3)),
            })
            n += 1
        print(f'{repo}: {n} Karten, {len(titles)} Themen')
    add_distractors(cards)
    out = root / 'assets' / 'questions' / 'lernkarten.json'
    out.write_text(json.dumps(cards, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    lens = sorted(len(c['antwort']) for c in cards)
    print(f'gesamt {len(cards)} -> {out} ({out.stat().st_size // 1024} KB)')
    print('Antwortlänge Median', lens[len(lens) // 2], '| <=44:', sum(l <= 44 for l in lens),
          '| <=70:', sum(l <= 70 for l in lens))


if __name__ == '__main__':
    main()
