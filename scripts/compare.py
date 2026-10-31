#!/usr/bin/env python3
"""Word-for-word check of transcripts against the script they were read from.

    scripts/compare.py bench/scripts/long70.txt transcript.txt [more transcripts...]

Case and punctuation are ignored, and say-engine markup like [[slnc 1000]] is dropped from the script.
Every missing, extra or changed word is listed with its surroundings.
"""
import difflib, re, sys

NUM = {"5": "five", "3": "three", "2": "two", "30": "thirty", "1": "one"}

def words(text):
    text = re.sub(r"\[\[.*?\]\]", " ", text)
    out = []
    for w in re.findall(r"[A-Za-z0-9']+", text.replace("’", "'")):
        w = w.lower()
        out.append(NUM.get(w, w))
    return out

ref = words(open(sys.argv[1]).read())
bad = 0
for path in sys.argv[2:]:
    hyp = words(open(path).read())
    ops = [o for o in difflib.SequenceMatcher(a=ref, b=hyp, autojunk=False).get_opcodes() if o[0] != "equal"]
    print(f"{path}: {len(ref)} script words, {len(hyp)} transcript words, {len(ops)} difference(s)")
    for tag, a1, a2, b1, b2 in ops:
        ctx = " ".join(ref[max(0, a1 - 4):a1])
        print(f"   {tag:8} script: {' '.join(ref[a1:a2]) or '-':30} transcript: {' '.join(hyp[b1:b2]) or '-':30} (after \"…{ctx}\")")
    bad += bool(ops)
sys.exit(1 if bad else 0)
