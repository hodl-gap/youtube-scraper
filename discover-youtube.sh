#!/usr/bin/env bash
#
# discover-youtube.sh — grow channels.json from YouTube's recommended feed,
# gating on ACTUAL CONTENT (transcript), not the title.
#
# Pipeline per recommended video:
#   1. RECENCY     — published within the last 2 weeks (<=14 days), else drop (cheap).
#   2. PRE-FILTER  — cheap title/entity check: drop the obviously-off-topic (cheap).
#   3. TRANSCRIPT  — pull the real transcript via yt-dlp for each survivor.
#   4. VALID?      — judge the CONTENT against the rubric. Only genuinely valuable
#                    AI substance qualifies (NOT just a good-looking title).
#   5. ADD CHANNEL — resolve the channel from the video id (canonical UC id +
#                    sub floor, impersonation-proof) and add it to the watchlist.
#
# Discovery only — it does not like/subscribe. It DOES read transcripts (that's
# the point: don't add a channel until a real recent video proves it's valuable).
#
# Usage:
#   ./discover-youtube.sh                                  # YT home recommended feed
#   ./discover-youtube.sh https://www.youtube.com/watch?v=ID   # that video's sidebar
#   ./discover-youtube.sh -n 20 --max-transcripts 6 --min-subs 1000
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

MAXV=20; RECENCY_DAYS=14; MAX_TX=6; MIN_SUBS=1000; SOURCE_URL="https://www.youtube.com/"
PEOPLE_DB="${PEOPLE_DB:-$DIR/../people-db/people.json}"
RUBRIC="${RUBRIC:-$DIR/../people-db/judge_prompt.md}"
PDB_DIR="$(dirname "$PEOPLE_DB")"
CHANNELS="$PDB_DIR/channels.json"
RESOLVE_TOOL="$PDB_DIR/tools/resolve_and_add_channels.py"
TX_TOOL="$PDB_DIR/tools/yt_transcript.sh"
DISC_DIR="$DIR/store/discoveries"; TX_DIR="$DIR/store/transcripts"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) MAXV="$2"; shift 2 ;;
    --max-transcripts) MAX_TX="$2"; shift 2 ;;
    --min-subs) MIN_SUBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    http*) SOURCE_URL="$1"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$DISC_DIR" "$TX_DIR"
[[ -f "$RUBRIC" ]] || { echo "Missing rubric: $RUBRIC" >&2; exit 1; }
[[ -f "$CHANNELS" ]] || { echo "Missing channels.json: $CHANNELS" >&2; exit 1; }

DATE="$(date +%Y-%m-%d)"; RUNID="$(date +%Y%m%d-%H%M%S)"
VIDDISC="$DISC_DIR/youtube-rec-$RUNID.jsonl"
echo ">> Content-gated discovery from: $SOURCE_URL"
echo ">> recency<=${RECENCY_DAYS}d -> title pre-filter -> transcribe<=${MAX_TX} -> judge content -> add (min ${MIN_SUBS} subs)"

PROMPT=$(cat <<EOF
You are a YouTube discovery agent (chrome-devtools MCP + Bash). Goal: grow the
channel watchlist, but ONLY with channels proven valuable by a real recent video's
TRANSCRIPT — never by title alone. DO NOT like/subscribe. DO NOT guess channel handles.

CAPS ARE CEILINGS, NOT TARGETS: only recent + content-valuable videos qualify;
if few/none do, add few/none. Never reach to fill the transcript or channel caps —
an empty run is correct when nothing recent is valuable.

Read first (Read tool):
- Rubric (defines "valid"=SIG): $RUBRIC
- People/entity context: $PEOPLE_DB

STEP 1 — READ FEED. Navigate "$SOURCE_URL" (timeout 60000; a reported timeout is
usually false — proceed). YT home -> recommended grid; a video -> its up-next sidebar.
Collect up to $MAXV videos; per tile capture: VIDEO ID (from /watch?v=ID — authoritative),
title, displayed channel name, published age. Skip Shorts/ads/live/playlists.

STEP 2 — RECENCY (cheap): keep ONLY videos within the last $RECENCY_DAYS days.
"N hours/days ago", "1-2 weeks ago" pass; "3 weeks ago", "N months/years ago" FAIL.

STEP 3 — TITLE PRE-FILTER (cheap): from title + channel + entity-context, drop the
videos that are clearly NOT about AI (sports, history, generic finance/macro,
lifestyle). Keep the plausibly-AI ones. This only NARROWS what we transcribe — do
not make the final call here.

STEP 4 — TRANSCRIPT + CONTENT JUDGEMENT. For up to $MAX_TX survivors (most
promising first), fetch the transcript by running, via Bash:
    bash "$TX_TOOL" <video_id> "$TX_DIR/<video_id>.txt"
Then Read that file and judge the CONTENT with the rubric: is this genuinely
valuable AI substance (SIG)? A clickbait title with empty content => NOT valid.
If a transcript is unavailable (exit 2 / NO_TRANSCRIPT), skip that video.

STEP 5 — OUTPUT. For each video whose CONTENT was judged valuable (SIG), append one
record to "$VIDDISC" as JSONL:
  {"video_id":"<id>","title":"<title>","age":"<age>","channel_name":"<displayed name>","kind":"person"|"organization"}
Do NOT include handles/URLs — the channel is resolved downstream from the video id.

Finally print a table: each video -> age, recency, pre-filter, (transcript? y/n),
content verdict, kept?. Be explicit when a good title was rejected on weak content.
EOF
)

claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --mcp-config "$DIR/.mcp.json" \
  --allowedTools "mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_snapshot,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__list_pages,mcp__chrome-devtools__new_page,Bash,Read,Write" \
  2>&1 | tee "$DIR/store/run-$RUNID.log"

if [[ -f "$RESOLVE_TOOL" ]]; then
  echo ">> Resolving channels of content-valid videos via yt-dlp (min $MIN_SUBS subs)..."
  python3 "$RESOLVE_TOOL" --channels "$CHANNELS" --disc "$VIDDISC" --today "$DATE" --min-subs "$MIN_SUBS" \
    || echo "WARN: channel resolution failed" >&2
fi
echo ">> Done. Content-valid videos: $VIDDISC"
