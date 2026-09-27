#!/usr/bin/env bash
#
# run.sh — measure word timing against real word stamps.
#
#   Scripts/word-timing-eval/fetch-corpus.py     # once: downloads the corpus
#   Scripts/word-timing-eval/run.sh [estimate|sync|synthetic]
#
# Compiles main.swift with the app's own timing code, so every number is
# for the code as it is now. Tune a constant, run again, compare.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CORPUS=build/word-timing-eval/corpus.json
[[ -f $CORPUS ]] || { echo "No corpus yet: run Scripts/word-timing-eval/fetch-corpus.py" >&2; exit 1; }

BIN=build/word-timing-eval/eval
L=Lyrical/Lyrics
swiftc -O -o "$BIN" Scripts/word-timing-eval/main.swift \
    $L/WordTiming.swift $L/WordSync.swift $L/LRCParser.swift $L/LyricsModel.swift
# Ad-hoc signed: a fresh unsigned binary can sit in the system's security scan.
codesign -s - -f "$BIN" 2>/dev/null
"$BIN" "${1:-all}" "$CORPUS"
