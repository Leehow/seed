#!/usr/bin/env python3
"""local_tasks.py -- small graded shell tasks, no Docker required.

Terminal-Bench is the right end-to-end measurement and it needs Harbor, images
and hours (see PREREGISTRATION.md). This file is the part of that experiment
that can run on a laptop: six tasks with real setup and real verifiers,
graded on environment state, so that "the four kernels behave the same" can be
checked on actual work and not only on witnesses.

Each task: an instruction the model sees, a setup script, and a verify script
whose exit status is the grade.
"""

TASKS = [
    {
        "id": "hello-file",
        "instruction": "Create a file hello.txt in the working directory whose "
                       "only content is the line: hello world",
        "setup": "true",
        "verify": "test \"$(cat hello.txt)\" = 'hello world'",
    },
    {
        "id": "count-lines",
        "instruction": "data.txt exists in the working directory. Write the "
                       "number of lines it contains, and nothing else, into "
                       "count.txt.",
        "setup": "printf 'a\\nb\\nc\\nd\\ne\\nf\\ng\\n' > data.txt",
        "verify": "test \"$(tr -d ' \\n' < count.txt)\" = 7",
    },
    {
        "id": "fix-python",
        "instruction": "buggy.py fails its test in test_buggy.py. Fix buggy.py "
                       "so that `python3 -m pytest -q test_buggy.py` passes, or "
                       "if pytest is unavailable so that `python3 test_buggy.py` "
                       "exits 0. Do not edit the test.",
        "setup": ("printf 'def add(a, b):\\n    return a - b\\n' > buggy.py; "
                  "printf 'from buggy import add\\n\\n"
                  "def test_add():\\n    assert add(2, 3) == 5\\n\\n"
                  "if __name__ == \"__main__\":\\n    test_add()\\n' > test_buggy.py"),
        "verify": "python3 test_buggy.py && "
                  "grep -q 'assert add(2, 3) == 5' test_buggy.py",
    },
    {
        "id": "json-extract",
        "instruction": "config.json holds a JSON object. Write the value of its "
                       "\"port\" key, and nothing else, into port.txt.",
        "setup": "printf '{\"host\": \"db.local\", \"port\": 5433, \"tls\": true}' > config.json",
        "verify": "test \"$(tr -d ' \\n\"' < port.txt)\" = 5433",
    },
    {
        "id": "exact-edit",
        "instruction": "settings.py sets RETRIES = 3. Change it to RETRIES = 7 "
                       "without changing anything else in the file.",
        "setup": ("printf 'DEBUG = False\\nRETRIES = 3\\nTIMEOUT = 30\\n"
                  "# RETRIES = 3 was the old default\\n' > settings.py"),
        "verify": ("grep -qx 'RETRIES = 7' settings.py && "
                   "grep -qx 'TIMEOUT = 30' settings.py && "
                   "grep -qx '# RETRIES = 3 was the old default' settings.py"),
    },
    {
        "id": "pipeline-report",
        "instruction": "sales.csv has a header and rows of name,amount. Write "
                       "the total of the amount column, as an integer with no "
                       "other text, into total.txt.",
        "setup": ("printf 'name,amount\\nada,120\\nbob,35\\ncy,7\\ndee,1000\\n' "
                  "> sales.csv"),
        "verify": "test \"$(tr -d ' \\n' < total.txt)\" = 1162",
    },
    {
        "id": "c-build",
        "instruction": "Write hello.c that prints hello, compile it with cc "
                       "into a binary named hello, run it, and put its exact "
                       "stdout into out.txt.",
        "setup": "true",
        "verify": "test -x hello && test \"$(cat out.txt)\" = hello",
    },
    {
        "id": "csv-filter",
        "instruction": "sales.csv has a header line and rows of name,amount. "
                       "Write big.csv containing the header and only the rows "
                       "whose amount is 100 or more, in the original order.",
        "setup": ("printf 'name,amount\\nada,120\\nbob,35\\ncy,7\\ndee,1000\\n' "
                  "> sales.csv"),
        "verify": ("printf 'name,amount\\nada,120\\ndee,1000\\n' | "
                   "diff -q - big.csv"),
    },
    {
        "id": "word-count",
        "instruction": "text.txt contains words separated by whitespace. Write "
                       "the single most frequent word, and nothing else, into "
                       "top.txt.",
        "setup": ("printf 'banana apple banana cherry\\nbanana apple\\n"
                  "cherry banana\\n' > text.txt"),
        "verify": "test \"$(tr -d ' \\n' < top.txt)\" = banana",
    },
    {
        "id": "patch-config",
        "instruction": "config.ini has a [db] section with port = 5432. Change "
                       "only that one to 6543. The [server] port and the "
                       "commented legacy line must stay exactly as they are.",
        "setup": ("printf '[server]\\nport = 8080\\n\\n[db]\\nport = 5432\\n"
                  "# legacy: port = 5432\\n' > config.ini"),
        "verify": ("grep -qx 'port = 8080' config.ini && "
                   "grep -qx '# legacy: port = 5432' config.ini && "
                   "grep -qx 'port = 6543' config.ini && "
                   "! grep -qx 'port = 5432' config.ini"),
    },
    {
        "id": "dep-error",
        "instruction": "python3 app.py fails. Make it work without installing "
                       "anything: the standard library already has what it "
                       "needs. It must print a JSON object with ok set to true.",
        "setup": ("printf 'import jsonlib as json\\n"
                  "print(json.dumps({\"ok\": True}))\\n' > app.py"),
        "verify": "python3 app.py | tr -d ' ' | grep -q '{\"ok\":true}'",
    },
    {
        "id": "two-file-refactor",
        "instruction": "Move the answer() function out of a.py and into b.py, "
                       "update main.py to import it from b, and leave a.py "
                       "without that function. python3 main.py must still "
                       "print 42.",
        "setup": ("printf 'def answer():\\n    return 42\\n' > a.py; "
                  "printf '# shared helpers\\n' > b.py; "
                  "printf 'from a import answer\\nprint(answer())\\n' > main.py"),
        "verify": ("test \"$(python3 main.py)\" = 42 && "
                   "grep -q 'def answer' b.py && ! grep -q 'def answer' a.py"),
    },
    {
        "id": "sort-uniq",
        "instruction": "words.txt has one word per line with duplicates. Write "
                       "the unique words, sorted alphabetically, one per line, "
                       "into uniq.txt.",
        "setup": "printf 'pear\napple\npear\nfig\napple\nfig\npear\n' > words.txt",
        "verify": "printf 'apple\nfig\npear\n' | diff -q - uniq.txt",
    },
    {
        "id": "dir-tree",
        "instruction": "Create the nested directories a/b/c and put a file "
                       "named leaf.txt containing deep inside c.",
        "setup": "true",
        "verify": "test \"$(cat a/b/c/leaf.txt)\" = deep",
    },
    {
        "id": "rename-ext",
        "instruction": "The notes/ directory holds .txt files. Rename every one "
                       "of them to the same name with a .md extension, leaving "
                       "the contents alone.",
        "setup": ("mkdir -p notes; printf 'one\n' > notes/a.txt; "
                  "printf 'two\n' > notes/b.txt; printf 'keep\n' > notes/c.dat"),
        "verify": ("test -f notes/a.md && test -f notes/b.md && "
                   "test ! -f notes/a.txt && test ! -f notes/b.txt && "
                   "test -f notes/c.dat && test \"$(cat notes/b.md)\" = two"),
    },
    {
        "id": "sum-json",
        "instruction": "items.json holds a JSON array of objects each with a "
                       "value field. Write the sum of all value fields, as an "
                       "integer and nothing else, into sum.txt.",
        "setup": ("printf '[{\"id\":1,\"value\":40},{\"id\":2,\"value\":2},"
                  "{\"id\":3,\"value\":300}]' > items.json"),
        "verify": "test \"$(tr -d ' \n' < sum.txt)\" = 342",
    },
    {
        "id": "grep-count",
        "instruction": "log.txt is a log file. Write the number of lines "
                       "containing ERROR, as a bare integer, into errors.txt.",
        "setup": ("printf 'INFO start\nERROR disk full\nINFO ok\n"
                  "ERROR timeout\nWARN slow\nERROR reset\n' > log.txt"),
        "verify": "test \"$(tr -d ' \n' < errors.txt)\" = 3",
    },
    {
        "id": "make-executable",
        "instruction": "Write a shell script greet.sh that prints hello there, "
                       "make it executable, run it as ./greet.sh, and put its "
                       "output into out.txt.",
        "setup": "true",
        "verify": ("test -x greet.sh && test \"$(cat out.txt)\" = 'hello there' "
                   "&& test \"$(./greet.sh)\" = 'hello there'"),
    },
    {
        "id": "tar-roundtrip",
        "instruction": "Archive the src/ directory into src.tar, extract it "
                       "into a new directory restored/ so that "
                       "restored/src/one.txt exists with its original content.",
        "setup": "mkdir -p src; printf 'alpha\n' > src/one.txt",
        "verify": ("test -f src.tar && test \"$(cat restored/src/one.txt)\" = alpha"),
    },
    {
        "id": "sqlite-query",
        "instruction": "Create a SQLite database app.db with a table t(name "
                       "text, n integer) holding the rows (a,1), (b,5) and "
                       "(c,9), then write the sum of n, as a bare integer, into "
                       "total.txt.",
        "setup": "true",
        "verify": ("test \"$(tr -d ' \n' < total.txt)\" = 15 && "
                   "test \"$(sqlite3 app.db 'select count(*) from t')\" = 3"),
    },
    {
        "id": "cli-args",
        "instruction": "Write add.py so that `python3 add.py 3 4` prints 7 and "
                       "`python3 add.py 10 -2` prints 8, then run the first of "
                       "those and put its output into seven.txt.",
        "setup": "true",
        "verify": ("test \"$(python3 add.py 3 4)\" = 7 && "
                   "test \"$(python3 add.py 10 -2)\" = 8 && "
                   "test \"$(tr -d ' \n' < seven.txt)\" = 7"),
    },
    {
        "id": "fix-shebang",
        "instruction": "./run.sh fails to execute. Fix it so that running "
                       "./run.sh prints ok. Do not change what it prints.",
        "setup": ("printf '#!/bin/nonexistent-shell\necho ok\n' > run.sh; "
                  "chmod +x run.sh"),
        "verify": "test \"$(./run.sh)\" = ok",
    },
    {
        "id": "dedupe-csv",
        "instruction": "rows.csv has a header and duplicate data rows. Write "
                       "clean.csv with the header and each distinct data row "
                       "once, keeping the order of first appearance.",
        "setup": ("printf 'id,name\n1,ada\n2,bob\n1,ada\n3,cy\n2,bob\n' "
                  "> rows.csv"),
        "verify": ("printf 'id,name\n1,ada\n2,bob\n3,cy\n' | diff -q - clean.csv"),
    },
    {
        "id": "env-default",
        "instruction": "Write show.sh that prints the value of the GREETING "
                       "environment variable, or the word default when it is "
                       "unset or empty. Run it both ways and write the two "
                       "outputs, in that order, one per line, into both.txt.",
        "setup": "true",
        "verify": ("test \"$(GREETING=hi sh ./show.sh)\" = hi && "
                   "test \"$(unset GREETING; sh ./show.sh)\" = default && "
                   "test \"$(wc -l < both.txt | tr -d ' ')\" -ge 2"),
    },
]
