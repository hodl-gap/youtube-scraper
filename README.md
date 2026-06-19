# youtube-scraper

YouTube source for the AI-trend monitor. Shares the rubric + `people-db` /
`channels.json` registries with the X and LinkedIn scrapers.

YouTube is **hybrid** (see `people-db/YOUTUBE.md` for the full design):
- **Content/transcripts** → `yt-dlp` (YT token-gates browser caption fetch).
- **Recommended feed + (future) engagement** → logged-in browser via chrome-devtools.

## Built now

### `discover-youtube.sh` — recommended-feed → channel discovery
Grows `channels.json` from YouTube's recommended feed. A recommended video's
**channel** is added only when the video passes BOTH strict gates:
1. **Recency** — published within the last **2 weeks** (≤14 days). Older is
   skipped no matter how relevant.
2. **Validity** — judged **SIG** by the shared rubric (title + channel +
   entity-context; no transcript).

Discovery only — it does **not** watch, transcribe, like, or subscribe.

```bash
./discover-youtube.sh                                   # YT home recommended feed
./discover-youtube.sh https://www.youtube.com/watch?v=ID    # that video's sidebar
./discover-youtube.sh -n 25                              # consider up to N recs
```

## Not built yet (spec'd in `people-db/YOUTUBE.md`)
- **v1 on-demand summarizer**: URL → `yt-dlp` transcript → AI-focused per-video
  summary → append **guest(s)** to people-db (guests-only; confident-only SNS
  resolution; orgs skipped).
- **v2 auto**: `channels.json` → detect new uploads → AI pre-filter → process.
- **Engagement** (like + subscribe) — deferred.

## Prereqs
- `yt-dlp` on PATH (for transcripts, once the summarizer is built).
- chrome-devtools MCP (shared logged-in Chrome profile) for the recommended feed.
- Personalized recommendations need YT to be logged in in that profile.
