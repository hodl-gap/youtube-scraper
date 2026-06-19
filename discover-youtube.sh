#!/usr/bin/env bash
#
# discover-youtube.sh — grow channels.json from YouTube's recommended feed.
#
# A recommended video's CHANNEL is added only when the video passes BOTH gates:
#   1. RECENCY  — published within the last 2 weeks (<=14 days).
#   2. VALIDITY — judged SIG by the shared rubric (title + channel + entity-context).
#
# Anti-impersonation: the agent records each kept video's VIDEO ID (never a
# synthesized handle). yt-dlp then resolves the REAL channel from that id
# (canonical UC id + subscriber count); squatters are rejected by a sub floor and
# dedup is by canonical id. (We learned this the hard way: a "Bloomberg Originals
# 🎖️" with 24 subs squatted @BloombergOriginals.)
#
# Discovery only — no watch/transcribe/like/subscribe.
#
# Usage:
#   ./discover-youtube.sh                                  # YT home recommended feed
#   ./discover-youtube.sh https://www.youtube.com/watch?v=ID   # that video's sidebar
#   ./discover-youtube.sh -n 25 --min-subs 5000
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

MAXV=20; RECENCY_DAYS=14; MIN_SUBS=1000; SOURCE_URL="https://www.youtube.com/"
PEOPLE_DB="${PEOPLE_DB:-$DIR/../people-db/people.json}"
RUBRIC="${RUBRIC:-$DIR/../people-db/judge_prompt.md}"
PDB_DIR="$(dirname "$PEOPLE_DB")"
CHANNELS="$PDB_DIR/channels.json"
RESOLVE_TOOL="$PDB_DIR/tools/resolve_and_add_channels.py"
DISC_DIR="$DIR/store/discoveries"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) MAXV="$2"; shift 2 ;;
    --min-subs) MIN_SUBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    http*) SOURCE_URL="$1"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$DISC_DIR"
[[ -f "$RUBRIC" ]] || { echo "Missing rubric: $RUBRIC" >&2; exit 1; }
[[ -f "$CHANNELS" ]] || { echo "Missing channels.json: $CHANNELS" >&2; exit 1; }

DATE="$(date +%Y-%m-%d)"; RUNID="$(date +%Y%m%d-%H%M%S)"
VIDDISC="$DISC_DIR/youtube-rec-$RUNID.jsonl"
echo ">> Recommended-feed discovery from: $SOURCE_URL"
echo ">> Gates: <=$RECENCY_DAYS days old AND valid(SIG); channels resolved via yt-dlp, min $MIN_SUBS subs."

PROMPT=$(cat <<EOF
You are a YouTube discovery agent using the chrome-devtools MCP tools (browser
already logged in). Your ONLY job is to identify recommended videos worth adding
their channel to the watchlist. DO NOT watch, transcribe, like, subscribe, or
navigate to channel pages. DO NOT guess or synthesize channel handles.

Read first (Read tool):
- Significance rubric: $RUBRIC  ("valid" = SIG; apply it)
- People/entity context: $PEOPLE_DB  (known AI people/orgs)

STEP 1 — read the recommended feed.
Navigate to "$SOURCE_URL" (timeout 60000; a reported timeout is usually false —
proceed anyway). If it's the YT home, read the recommended grid; if it's a video,
read the "up next / recommended" sidebar. Collect up to $MAXV recommended videos.
For each, capture from the tile: the VIDEO ID (from its /watch?v=ID link — this is
the authoritative key; never invent it), the title, the displayed channel name,
and the published age (e.g. "3 days ago", "2 weeks ago"). Skip Shorts, ads, live,
and playlists/mixes.

STEP 2 — apply TWO STRICT gates per video:
  (A) RECENCY: keep ONLY videos within the last $RECENCY_DAYS days (<=2 weeks).
      "today/N hours/N days ago" and "1-2 weeks ago" pass; "3 weeks ago",
      "N months/years ago" FAIL — skip even if highly relevant.
  (B) VALIDITY: judge SIG / INSIG / SKIP via the rubric, from title + channel +
      entity-context (no transcript). Keep ONLY SIG ("valid").

STEP 3 — write the survivors to "$VIDDISC" as JSONL, ONE record per kept video:
  {"video_id":"<the /watch?v= id>","title":"<title>","age":"<age>","channel_name":"<displayed channel name>","kind":"person"|"organization"}
  Do NOT include channel handles or URLs — the real channel is resolved downstream
  from the video id. Mark media/brand channels kind "organization", individuals "person".

Finally print a short table: each recommended video with age, recency-pass,
validity verdict, and whether it was kept.
EOF
)

claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --mcp-config "$DIR/.mcp.json" \
  --allowedTools "mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_snapshot,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__list_pages,mcp__chrome-devtools__new_page,Read,Write" \
  2>&1 | tee "$DIR/store/run-$RUNID.log"

if [[ -f "$RESOLVE_TOOL" ]]; then
  echo ">> Resolving channels from video ids via yt-dlp (rejecting impersonators < $MIN_SUBS subs)..."
  python3 "$RESOLVE_TOOL" --channels "$CHANNELS" --disc "$VIDDISC" --today "$DATE" --min-subs "$MIN_SUBS" \
    || echo "WARN: channel resolution failed" >&2
fi
echo ">> Done. Video discoveries: $VIDDISC"
