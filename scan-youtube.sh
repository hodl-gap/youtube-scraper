#!/usr/bin/env bash
#
# scan-youtube.sh — YouTube v2: scan tracked channels for NEW videos, process them
# into the report, and weave in channel-discovery as a byproduct.
#
#   for each tracked channel (channels.json):
#     new videos since last run? (incremental, dedup by video id)
#       no  -> nothing to do (no video -> no sidebar -> no discovery)
#       yes -> for each new video (bounded, newest-first):
#                AI pre-filter (title) -> transcript (yt-dlp) -> judge VALUABLE
#                if valuable:
#                  - per-video AI-focused summary -> digest (the report)
#                  - extract GUEST(s) (guests-only) -> people-db (confident SNS resolve)
#                  - DISCOVERY: harvest THAT video's recommended sidebar, content-gate
#                    it (recency + transcript + valuable), resolve channels by video id
#                    and add them (impersonation-proof)
#
# CAPS ARE CEILINGS, NOT TARGETS — quiet channels produce empty runs.
#   -n            max NEW videos processed this run        (default 4)
#   --per-channel max new videos per channel               (default 2)
#   --disc-tx     sidebar transcripts per video (discovery)(default 3)
#   --min-subs    impersonator floor for discovered channels (default 1000)
#
# "valuable" currently = the shared post-rubric (a known stand-in; the video-specific
# criterion is deferred). Engagement (like/subscribe) is deferred.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

NMAX=4; PER_CH=2; DISC_TX=3; MIN_SUBS=1000
PEOPLE_DB="${PEOPLE_DB:-$DIR/../people-db/people.json}"
RUBRIC="${RUBRIC:-$DIR/../people-db/judge_prompt.md}"
PDB_DIR="$(dirname "$PEOPLE_DB")"
CHANNELS="$PDB_DIR/channels.json"
TX_TOOL="$PDB_DIR/tools/yt_transcript.sh"
RESOLVE_TOOL="$PDB_DIR/tools/resolve_and_add_channels.py"
UPDATE_PEOPLE="$PDB_DIR/tools/update_people_db.py"
STORE_DIR="$DIR/store/raw"; DISC_DIR="$DIR/store/discoveries"; TX_DIR="$DIR/store/transcripts"; DIGEST_DIR="$DIR/digests"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NMAX="$2"; shift 2 ;;
    --per-channel) PER_CH="$2"; shift 2 ;;
    --disc-tx) DISC_TX="$2"; shift 2 ;;
    --min-subs) MIN_SUBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$STORE_DIR" "$DISC_DIR" "$TX_DIR" "$DIGEST_DIR"
[[ -f "$RUBRIC" ]] || { echo "Missing rubric: $RUBRIC" >&2; exit 1; }
[[ -f "$CHANNELS" ]] || { echo "Missing channels.json: $CHANNELS" >&2; exit 1; }

DATE="$(date +%Y-%m-%d)"; RUNID="$(date +%Y%m%d-%H%M%S)"; STAMP="$(date '+%Y-%m-%d %H:%M %Z')"
SEEN="$STORE_DIR/.seen_video_ids.txt"
CANDS="$DISC_DIR/youtube-candidates-$RUNID.jsonl"
RAWFILE="$STORE_DIR/youtube-$RUNID.jsonl"
DIGEST="$DIGEST_DIR/youtube-$DATE.md"
GUESTDISC="$DISC_DIR/youtube-guests-$RUNID.jsonl"
CHDISC="$DISC_DIR/youtube-rec-$RUNID.jsonl"

# seen video ids (across prior youtube runs)
python3 - "$STORE_DIR" > "$SEEN" <<'PY'
import sys, glob, json, os
seen=set()
for fp in glob.glob(os.path.join(sys.argv[1],"youtube-*.jsonl")):
    for line in open(fp,encoding="utf-8"):
        line=line.strip()
        if not line: continue
        try: seen.add(json.loads(line)["id"])
        except Exception: pass
print("\n".join(sorted(seen)))
PY

# STEP 0 (deterministic): list NEW candidate videos per channel (newest-first, bounded).
python3 - "$CHANNELS" "$SEEN" "$PER_CH" "$NMAX" > "$CANDS" <<'PY'
import sys, json, subprocess
chf, seenf, per_ch, nmax = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
seen = set(l.strip() for l in open(seenf, encoding="utf-8") if l.strip())
chans = json.load(open(chf, encoding="utf-8"))["channels"]
out = []
for c in chans:
    if len(out) >= nmax: break
    url = (c.get("url") or f"https://www.youtube.com/{c['channel']}").rstrip("/") + "/videos"
    try:
        r = subprocess.run(["yt-dlp", "--flat-playlist", "--playlist-end", "8", "--no-warnings",
                            "--print", "%(id)s\t%(title)s", url],
                           capture_output=True, text=True, timeout=150)
    except Exception:
        continue
    got = 0
    for line in (r.stdout or "").splitlines():
        if "\t" not in line: continue
        vid, title = line.split("\t", 1)
        if vid in seen: continue          # already processed -> not new
        out.append({"channel": c["channel"], "channel_id": c.get("channel_id"),
                    "video_id": vid, "title": title})
        got += 1
        if got >= per_ch or len(out) >= nmax: break
print("\n".join(json.dumps(o, ensure_ascii=False) for o in out))
PY

NCAND=$(grep -c . "$CANDS" || true)
echo ">> YouTube v2: $NCAND new candidate video(s) across tracked channels (cap $NMAX, ${PER_CH}/channel)."
if [[ "$NCAND" -eq 0 ]]; then
  echo ">> Nothing new on any tracked channel — empty run (correct). Done."
  exit 0
fi

PROMPT=$(cat <<EOF
You process NEW YouTube videos from tracked channels into a report, and discover
new channels as a byproduct. Tools: Bash (yt-dlp + transcript helper), chrome-devtools
MCP (recommended sidebar + SNS lookup), Read, Write. Work bounded.

CAPS ARE CEILINGS, NOT TARGETS: only genuinely valuable content qualifies; if little
is valuable, produce little. Never reach to fill a cap.

Read first (Read tool):
- Rubric (defines "valuable" = SIG; a known stand-in): $RUBRIC
- People/entity context: $PEOPLE_DB
- New candidate videos (JSONL: channel, channel_id, video_id, title): $CANDS

For EACH candidate video:
1. AI PRE-FILTER (cheap): from the title + channel + entity-context, skip videos
   clearly NOT about AI. (Cheap narrowing only.)
2. TRANSCRIPT: run via Bash:  bash "$TX_TOOL" <video_id> "$TX_DIR/<video_id>.txt"
   then Read that file. If unavailable (exit 2), skip the video.
3. JUDGE the CONTENT with the rubric: is this genuinely valuable AI substance (SIG)?
   A weak/empty video is NOT valuable even with a good title.
4. If VALUABLE:
   a. SUMMARY: write a per-video block to the digest "$DIGEST" — title, channel
      (the source), a 3-5 sentence AI-focused summary (what leaders are doing/saying),
      and participants. Output is per-VIDEO.
   b. GUESTS (guests-only): identify the GUEST speaker(s) who APPEAR (have dialogue) —
      NOT the host/channel (org or recurring panel), NOT merely-mentioned people. For
      each guest, FIRST require they are THEMSELVES a genuine AI person/operator
      (founder/researcher/builder/exec in AI) — a non-AI guest (politician, generic
      celebrity/exec) is listed in the digest but NOT appended. For a qualifying AI
      guest, resolve their X/LinkedIn by name + corroborating role (browser search;
      CONFIDENT-ONLY — if you cannot corroborate, leave unfound, never guess), then append to
      "$GUESTDISC": {"platform":"x"|"linkedin","handle"|"id":"<resolved>","name":"<name>","kind":"person","role_org":"<role>"}.
      List unresolved guests in the digest but do not append them.
   c. DISCOVERY (byproduct): navigate to https://www.youtube.com/watch?v=<video_id>
      and read its recommended/up-next sidebar. For up to $DISC_TX recommendations
      that are (i) within the last 2 weeks AND (ii) plausibly AI by title, fetch their
      transcript (bash "$TX_TOOL" <rec_id> "$TX_DIR/<rec_id>.txt"), Read, and judge
      VALUABLE. For each VALUABLE rec whose channel is new, append to "$CHDISC":
      {"video_id":"<rec_id>","title":"<title>","age":"<age>","channel_name":"<name>","kind":"person"|"organization"}
      (channels are resolved downstream from the video id — do NOT add handles).
5. Append the candidate video (valuable or not) to "$RAWFILE" as JSONL:
   {"id":"<video_id>","platform":"youtube","channel":"<channel>","title":"<title>","label":"VALUABLE"|"SKIP","reason":"<=12 words","source":"channel-scan","scraped_at":"$STAMP"}

Finally print a table: each candidate -> pre-filter, transcript?, valuable?, guests added, channels discovered.
EOF
)

claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --mcp-config "$DIR/.mcp.json" \
  --allowedTools "mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_snapshot,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__list_pages,mcp__chrome-devtools__new_page,Bash,Read,Write" \
  2>&1 | tee "$DIGEST_DIR/run-$RUNID.log"

# post-steps: add discovered channels (resolved by video id) + guests (people-db)
if [[ -f "$RESOLVE_TOOL" && -s "$CHDISC" ]]; then
  echo ">> Adding discovered channels (yt-dlp resolve, min $MIN_SUBS subs)..."
  python3 "$RESOLVE_TOOL" --channels "$CHANNELS" --disc "$CHDISC" --today "$DATE" --min-subs "$MIN_SUBS" || true
fi
if [[ -f "$UPDATE_PEOPLE" && -s "$GUESTDISC" ]]; then
  echo ">> Adding resolved guests to people-db..."
  for plat in x linkedin; do
    python3 "$UPDATE_PEOPLE" --people "$PEOPLE_DB" --platform "$plat" --today "$DATE" --disc "$GUESTDISC" || true
  done
fi
echo ">> Done. Digest: $DIGEST  Raw: $RAWFILE"
