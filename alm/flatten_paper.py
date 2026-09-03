#!/usr/bin/env python3
"""flatten_paper.py -- one self-contained .tex, for a reader who has only the file.

The paper is assembled from generated parts: 23 table fragments and a macro
file, so that no number is ever typed by hand. That is right for the artifact
and wrong for anyone reviewing the text alone, who would see \\input{gen/tab-tb}
and \\tbmaxdiff where the evidence should be. This expands both, so the
flattened copy says 0.052 where the source says \\tbmaxdiff.

    python3 alm/flatten_paper.py            # writes paper/seed-flat.tex
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAPER = os.path.join(ROOT, "paper")


def main():
    src = open(os.path.join(PAPER, "seed.tex")).read()

    macros = {}
    for m in re.finditer(r"\\newcommand\{\\(\w+)\}\{(.*)\}\s*$",
                         open(os.path.join(PAPER, "gen", "macros.tex")).read(),
                         re.M):
        macros[m.group(1)] = m.group(2)

    # inline the generated tables, keeping \widetable's scaling semantics
    def table(m):
        name = m.group(2)
        path = os.path.join(PAPER, "gen", name + ".tex")
        if not os.path.exists(path):
            return m.group(0)
        body = open(path).read().rstrip()
        return (r"\resizebox{\textwidth}{!}{%s}" % body
                if m.group(1) == "widetable" else body)

    src = re.sub(r"\\(input|widetable)\{gen/(tab-[a-z0-9-]+)\}", table, src)
    src = src.replace("\\input{gen/macros}",
                      "%% macros expanded below; see alm/paper_tables.py")

    # substitute the scalars, longest name first so \tbarmone is not eaten by \tbarm
    for name in sorted(macros, key=len, reverse=True):
        src = re.sub(r"\\%s(\\ |\\,|\b)" % name,
                     lambda m, v=macros[name]: v + ("" if m.group(1) == r"\ " else m.group(1)),
                     src)

    left = sorted(set(re.findall(r"\\(%s)\b" % "|".join(macros), src))) if macros else []
    out = os.path.join(PAPER, "seed-flat.tex")
    with open(out, "w") as fh:
        fh.write(src)
    print("-> %s (%d KB)" % (out, os.path.getsize(out) // 1024))
    print("   %d macros expanded, %d tables inlined" % (len(macros),
          len(re.findall(r"\\begin\{tabular\}", src))))
    if left:
        print("   WARNING: still unexpanded: %s" % ", ".join(left))
        return 1
    if "\\input{gen/" in src:
        print("   WARNING: an \\input{gen/...} survived")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
