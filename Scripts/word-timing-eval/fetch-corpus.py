#!/usr/bin/env python3
#
# fetch-corpus.py — ground truth for tuning word timing.
#
# For each song below: NetEase's word-by-word lyrics (the truth) and
# LRCLIB's line-synced lyrics for the same song (what the app really gets).
# Written to build/word-timing-eval/corpus.json, which stays out of git:
# it's other people's lyrics. Uses curl, so no Python packages are needed.
#
import json, re, subprocess, sys, time, urllib.parse, os

OUT = os.path.join(os.path.dirname(__file__), "../../build/word-timing-eval/corpus.json")

SONGS = """Blinding Lights|The Weeknd
Shape of You|Ed Sheeran
Levitating|Dua Lipa
bad guy|Billie Eilish
Someone Like You|Adele
Viva la Vida|Coldplay
Anti-Hero|Taylor Swift
As It Was|Harry Styles
Espresso|Sabrina Carpenter
Flowers|Miley Cyrus
Uptown Funk|Mark Ronson
Rolling in the Deep|Adele
Counting Stars|OneRepublic
Believer|Imagine Dragons
Perfect|Ed Sheeran
Stay|The Kid LAROI
Watermelon Sugar|Harry Styles
drivers license|Olivia Rodrigo
good 4 u|Olivia Rodrigo
Shallow|Lady Gaga
Rolling Stone|Bob Dylan
Hotel California|Eagles
Bohemian Rhapsody|Queen
Billie Jean|Michael Jackson
Smells Like Teen Spirit|Nirvana
Mr. Brightside|The Killers
Yellow|Coldplay
Let It Be|The Beatles
Lose Yourself|Eminem
HUMBLE.|Kendrick Lamar
God's Plan|Drake
Sunflower|Post Malone
Circles|Post Malone
Bad Habits|Ed Sheeran
Cruel Summer|Taylor Swift
Love Story|Taylor Swift
All of Me|John Legend
Thinking Out Loud|Ed Sheeran
Hello|Adele
Stressed Out|Twenty One Pilots
Radioactive|Imagine Dragons
Riptide|Vance Joy
Take Me to Church|Hozier
Royals|Lorde
Chandelier|Sia
Happier Than Ever|Billie Eilish
Heat Waves|Glass Animals
Kill Bill|SZA
Vampire|Olivia Rodrigo
Die With A Smile|Lady Gaga
APT.|ROSÉ
Birds of a Feather|Billie Eilish
Beautiful Things|Benson Boone
Too Sweet|Hozier
Starboy|The Weeknd
Save Your Tears|The Weeknd
Dance Monkey|Tones and I
Someone You Loved|Lewis Capaldi
Photograph|Ed Sheeran
Wonderwall|Oasis
Creep|Radiohead
Fix You|Coldplay
Africa|Toto
Don't Stop Believin'|Journey
Sweet Child O' Mine|Guns N' Roses
Hallelujah|Jeff Buckley
Skinny Love|Bon Iver
Space Song|Beach House
Pumped Up Kicks|Foster the People
Take On Me|a-ha""".strip().split("\n")

def get(url):
    out = subprocess.run(["curl", "-s", "-m", "15", "-A", "Lyrical word-timing eval", url],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except ValueError:
        return None

def yrc_lines(text):
    lines = []
    for raw in text.split("\n"):
        m = re.match(r"^\[(\d+),(\d+)\](.*)$", raw)
        if not m:
            continue
        words = re.findall(r"\((\d+),(\d+),\d+\)([^(]*)", m.group(3))
        if words:
            lines.append({"start": int(m.group(1)) / 1000, "dur": int(m.group(2)) / 1000,
                          "words": [{"text": t, "start": int(s) / 1000, "end": (int(s) + int(d)) / 1000}
                                    for s, d, t in words]})
    return lines

corpus = []
for entry in SONGS:
    title, artist = entry.split("|")
    found = get("https://music.163.com/api/search/get?" + urllib.parse.urlencode(
        {"s": f"{title} {artist}", "type": 1, "limit": 5})) or {}
    songs = (found.get("result") or {}).get("songs") or []
    song = next((s for s in songs if s["name"].lower().startswith(title.lower()[:6])), None)
    if not song:
        print("not on NetEase:", title); continue
    lyric = get(f"https://music.163.com/api/song/lyric/v1?id={song['id']}&lv=1&yv=1") or {}
    lines = [l for l in yrc_lines((lyric.get("yrc") or {}).get("lyric", ""))
             if not re.search(r"[\u4e00-\u9fff]", "".join(w["text"] for w in l["words"]))]
    if len(lines) < 8:
        print("no word timing:", title); continue
    duration = song["duration"] / 1000
    records = get("https://lrclib.net/api/search?" + urllib.parse.urlencode(
        {"track_name": title, "artist_name": artist})) or []
    records = sorted((r for r in records if r.get("syncedLyrics")),
                     key=lambda r: abs((r.get("duration") or 0) - duration))
    corpus.append({"title": title, "artist": artist, "duration": duration, "lines": lines,
                   "lrc": records[0]["syncedLyrics"] if records else None})
    print("ok:", title)
    time.sleep(0.3)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump(corpus, open(OUT, "w"))
print(f"{len(corpus)} songs -> {os.path.normpath(OUT)}")
