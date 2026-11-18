# Comment Reader

A native macOS YouTube comment reader. It downloads every root comment and every
reply once, then lets you read them one comment at a time, filtered to the top
1 / 5 / 10 / 25 / 50 % of root comments by likes. Replies appear inline under
each root, like YouTube, with a **Show more replies** control.

## Open it

Double-click **CommentReader.app**. If `data/corpus.json` exists at build time
it is embedded, so the app starts with a sample video already available; that
file is a local scrape and is not tracked in git. Without it the app opens on
the add-video screen, ready to download a video.

To read another video, click **+ Add video** (or press `⌘N`), paste a YouTube
link, and press **Fetch**. The app downloads root comments first, then every
reply thread, with a live progress bar, percentages, and counts. Downloads are
saved under `~/Library/Application Support/CommentReader/corpora/`, so each
video is downloaded only once.

## Controls

| Action | How |
|---|---|
| Previous / next root comment | `←` / `→`, the round buttons, or the Navigate menu |
| Read replies | Scroll down — they are inline under the root comment |
| Show more replies | The button at the bottom of the reply thread |
| Change tier | The pills under the video title |
| Add another video | **+ Add video** (`⌘N`) |
| Open a corpus file | **File → Open Corpus…** (`⌘O`) |

## What each screen shows

- **Top bar:** tier pills, plus the estimated **reading time for the whole
  tier** — every root comment in the selected tier plus all of their replies,
  at 200 words per minute. It stays visible while you scroll.
- **Root card:** author, age, likes, reply count, and text.
- **Replies:** inline below the root as a **true nested tree**, indented level by
  level exactly like YouTube: replies to replies sit under their parent, with
  their own likes and reply counts. **Show more replies** appears at any level
  that has more children. Long replies collapse with **Read more**.
- **Progress:** `Top 7 of 33` for the active tier, plus a fill bar and the tier
  cutoff (`Top 5% · 539+ likes`).

## Saved state

Every move is saved immediately for the current video — tier and root comment.
Each tier remembers its own last position. Close and reopen and the app returns
to the exact comment you were reading. State is stored per video in
`~/Library/Preferences/local.commentreader.plist`.

## Fetching details

- Anonymous YouTube InnerTube API; no login or API key. The app uses the page's
  full client context (including `configInfo.appInstallData`), which makes
  YouTube return the threaded format (`subThreads`) instead of the older flat
  reply list.
- Root comments are paginated to the end of the Top sort.
- Replies are fetched recursively down the tree; every "Show more replies"
  continuation at every depth is followed, up to depth 8.
- A few threads are omitted by the threaded endpoint; the app automatically
  re-fetches those threads in YouTube's legacy flat format so no replies are
  lost (those recovered replies appear directly under the root).
- A 10,000-comment video takes several minutes; the app can cancel cleanly.

## Fetching another video

Use **+ Add video** in the app. Videos are downloaded with their full reply
tree and stored under
`~/Library/Application Support/CommentReader/corpora/<video-id>.json`;
reopening a downloaded video is instant.

To embed a sample corpus in the app, write a `data/corpus.json` in the same
format and run `./build.sh`. It is optional and excluded from git so that
scraped comment data is not redistributed. (`tools/build_corpus.py` is the
older flat-format crawler, kept only as a reference.)

## Data notes

- Root comments only for the distribution and tiers; replies are excluded from
  the percentages and totals.
- Tier cutoffs use the same rank definition as the analysis skill:
  `k = round(n × pct / 100)`, minimum 1.
- Like counts below 1,000 are exact; at and above 1,000 YouTube abbreviates
  them (`4.6K`, `2.7K`), so those values are approximate.
- YouTube's displayed comment count includes replies; the app shows the root
  count and the captured reply count separately.
- Reading time is an estimate based on the captured text.

## Project layout

```
app/main.swift          SwiftUI app: reader, state, fetching UI
app/YouTubeFetcher.swift native InnerTube crawler (roots + replies)
app/Info.plist          bundle metadata
app/AppIcon.icns        generated icon
build.sh                compile + package + ad-hoc sign
tools/build_corpus.py   legacy flat-format crawler (reference only)
data/corpus.json        optional local sample, not tracked
data/cache/             resumable crawl caches (ignored)
CommentReader.app       the built app
```
