#!/usr/bin/env python3
"""Words-wrong rate (word error rate) of transcripts against a reference text.

    scripts/score.py bench/real/option-hold.txt transcript.txt [more...]

Lowercase, punctuation dropped (apostrophes kept), then word-level edit distance / reference words.
Also flags the two known problems: "Claude Code" spelled otherwise, and a doubled "the menu, the menu".
"""
import re, sys

def norm(s):
    return re.sub(r"[^a-z0-9' ]", " ", s.lower().replace("’", "'")).split()

def wer(h, r):
    h, r = norm(h), norm(r)
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        p = d[:]; d[0] = i
        for j, hw in enumerate(h, 1):
            d[j] = min(p[j] + 1, d[j - 1] + 1, p[j - 1] + (rw != hw))
    return d[-1] / len(r)

ref = open(sys.argv[1]).read()
for path in sys.argv[2:]:
    t = open(path).read()
    flags = []
    if "claude code" not in t.lower(): flags.append("no 'Claude Code'")
    if re.search(r"\bcloud code\b", t, re.I): flags.append("'Cloud Code'")
    if re.search(r"\bthe menu\W+the menu\b", t, re.I): flags.append("'the menu, the menu'")
    print(f"{path}: {wer(t, ref):.1%} words wrong  {'; '.join(flags) or 'ok'}")
