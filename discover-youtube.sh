#!/usr/bin/env bash
#
# discover-youtube.sh — grow channels.json from YouTube's recommended feed.
#
# Reads the recommended feed (logged-in YT home, or a video's sidebar), and adds
# a video's CHANNEL to channels.json ONLY when the video passes BOTH strict gates:
#   1. RECENCY — published within the last 2 weeks (<=14 days). Older is skipped
#      no matter how relevant.
#   2. VALIDITY — judged SIG by the shared rubric (title + channel + entity-context).
#
# Discovery only: it does NOT watch/transcribe, like, or subscribe. (YT engagement
# is deferred.) It just expands the channel watchlist via the algorithm.
#
# Usage:
#   ./discover-youtube.sh                                  # YT home recommended feed
#   ./discover-youtube.sh https://www.youtube.com/watch?v=ID   # that video's sidebar
#   ./discover-youtube.sh -n 25                            # consider up to N recommendations
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

MAXV=20; RECENCY_DAYS=14; SOURCE_URL="https://www.youtube.com/"
PEOPLE_DB="${PEOPLE_DB:-$DIR/../people-db/people.json}"
RUBRIC="${RUBRIC:-$DIR/../people-db/judge_prompt.md}"
PDB_DIR="$(dirname "$PEOPLE_DB")"
CHANNELS="$PDB_DIR/channels.json"
UPDATE_CHANNELS="$PDB_DIR/tools/update_channels.py"
DISC_DIR="$DIR/store/discoveries"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) MAXV="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    http*) SOURCE_URL="$1"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$DISC_DIR"
[[ -f "$RUBRIC" ]] || { echo "Missing rubric: $RUBRIC" >&2; exit 1; }
[[ -f "$CHANNELS" ]] || { echo "Missing channels.json: $CHANNELS" >&2; exit 1; }

DATE="$(date +%Y-%m-%d)"; RUNID="$(date +%Y%m%d-%H%M%S)"
DISCFILE="$DISC_DIR/youtube-rec-$RUNID.jsonl"
echo ">> Recommended-feed discovery from: $SOURCE_URL"
echo ">> Gates: <=$RECENCY_DAYS days old AND valid(SIG). Output: $DISCFILE"

PROMPT=$(cat <<EOF
You are a YouTube discovery agent using the chrome-devtools MCP tools (browser
already logged in). Your ONLY job is to grow the channel watchlist from the
recommended feed — DO NOT watch, transcribe, like, or subscribe to anything.

Read first (Read tool):
- Significance rubric: $RUBRIC  (this defines "valid" = SIG; apply it)
- People/entity context: $PEOPLE_DB  (known AI people/orgs)
- Existing channels (do NOT re-add these): $CHANNELS

STEP 1 — read the recommended feed.
Navigate to "$SOURCE_URL" (timeout 60000; a reported timeout is usually false —
proceed anyway). If it's the YT home, read the recommended grid; if it's a video,
read the "recommended / up next" sidebar. Collect up to $MAXV recommended videos.
For each, capture: title, channel name, channel handle/URL, and the published age
(e.g. "3 days ago", "2 weeks ago", "1 month ago"). Skip Shorts, ads, live, and
mixes/playlists.

STEP 2 — apply TWO STRICT gates to each recommended video:
  (A) RECENCY: keep ONLY videos published within the last $RECENCY_DAYS days
      (<= 2 weeks). "today/N hours/N days ago" and "1-2 weeks ago" pass; "3 weeks
      ago", "N months/years ago" FAIL — skip them even if highly relevant.
  (B) VALIDITY: judge the video SIG / INSIG / SKIP using the rubric, from its
      title + channel + entity-context (no transcript). Keep ONLY SIG ("valid").

STEP 3 — for every video passing BOTH gates whose channel is NOT already in
channels.json, append the CHANNEL once to "$DISCFILE" as JSONL:
  {"channel":"@handle or channel-id","url":"https://www.youtube.com/...","name":"<channel name>","kind":"person"|"organization","linked_person":null,"note":"via recommended: <video title> (<age>)"}
One record per NEW channel (dedupe within this run too). Mark media/brand channels
as kind "organization", individuals as "person".

Finally, print a short table: each recommended video with its age, recency-pass,
validity verdict, and whether its channel was added (or already known).
EOF
)

claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --mcp-config "$DIR/.mcp.json" \
  --allowedTools "mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_snapshot,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__list_pages,mcp__chrome-devtools__new_page,Read,Write" \
  2>&1 | tee "$DIR/store/run-$RUNID.log"

if [[ -f "$UPDATE_CHANNELS" ]]; then
  echo ">> Merging discovered channels into channels.json..."
  python3 "$UPDATE_CHANNELS" --channels "$CHANNELS" --disc "$DISCFILE" --today "$DATE" || echo "WARN: channel merge failed" >&2
fi
echo ">> Done. Discoveries: $DISCFILE"
