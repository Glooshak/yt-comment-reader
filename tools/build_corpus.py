#!/usr/bin/env python3
"""Build a complete offline corpus for the comment reader app.

Crawls every root comment and every reachable reply thread for a video,
then writes data/corpus.json for the SwiftUI reader.

Usage:
    python3 -I build_corpus.py <video-url-or-id> [--out data/corpus.json] [--resume]
"""

import argparse
import gzip
import json
import re
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "data" / "cache"


def video_id(value: str) -> str:
    value = value.strip()
    for pat in (r"(?:v=)([A-Za-z0-9_-]{11})", r"youtu\.be/([A-Za-z0-9_-]{11})",
                r"/shorts/([A-Za-z0-9_-]{11})", r"/embed/([A-Za-z0-9_-]{11})"):
        m = re.search(pat, value)
        if m:
            return m.group(1)
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", value):
        return value
    raise SystemExit(f"Could not find an 11-character video id in: {value!r}")


def request(url, data=None, headers=None, tries=4):
    h = {"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9", "Accept-Encoding": "gzip"}
    if headers:
        h.update(headers)
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, data=data, headers=h)
            with urllib.request.urlopen(req, timeout=40) as r:
                raw = r.read()
            if raw[:2] == b"\x1f\x8b":
                raw = gzip.decompress(raw)
            return raw
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def walk_dicts(obj):
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from walk_dicts(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk_dicts(v)


def first_token(obj):
    for node in walk_dicts(obj):
        tok = node.get("continuationCommand", {}).get("token")
        if tok:
            return tok
    return None


def comment_section_token(initial):
    candidates = []

    def walk(o, in_main=False):
        if isinstance(o, dict):
            if o.get("sectionIdentifier") == "comment-item-section":
                tok = first_token(o.get("contents", []))
                if tok:
                    candidates.append((0 if in_main else 1, tok))
            for k, v in o.items():
                walk(v, in_main or k == "twoColumnWatchNextResults")
        elif isinstance(o, list):
            for v in o:
                walk(v, in_main)

    walk(initial)
    candidates.sort(key=lambda x: x[0])
    return candidates[0][1] if candidates else None


def parse_count(value):
    if value is None:
        return 0
    s = str(value).strip().replace(",", "").upper()
    if not s:
        return 0
    m = re.search(r"([\d.]+)\s*([KMB]?)", s)
    if not m:
        return 0
    mult = {"": 1, "K": 1_000, "M": 1_000_000, "B": 1_000_000_000}[m.group(2)]
    return int(round(float(m.group(1)) * mult))


def button_text(b):
    return "".join(r.get("text", "") for r in b.get("text", {}).get("runs", []))


class Crawler:
    def __init__(self, vid):
        self.vid = vid
        self.initial = None
        self.key = None
        self.ver = None
        self.last_request = 0.0

    def load_watch(self):
        html = request(f"https://www.youtube.com/watch?v={self.vid}&hl=en&gl=US").decode("utf-8", "replace")
        m = re.search(r"ytInitialData\s*=\s*(\{.*?\});</script>", html, re.S)
        if not m:
            raise SystemExit("Could not parse ytInitialData from the watch page.")
        self.initial = json.loads(m.group(1))
        self.key = re.search(r'"INNERTUBE_API_KEY":"([^"]+)"', html).group(1)
        self.ver = re.search(r'"INNERTUBE_CLIENT_VERSION":"([^"]+)"', html).group(1)
        self.token = comment_section_token(self.initial)
        if not self.token:
            raise SystemExit("No comment section found.")

    def post(self, tok):
        # gentle pacing across every request
        wait = 0.32 - (time.monotonic() - self.last_request)
        if wait > 0:
            time.sleep(wait)
        body = json.dumps({
            "context": {"client": {"clientName": "WEB", "clientVersion": self.ver,
                                   "hl": "en", "gl": "US",
                                   "originalUrl": f"https://www.youtube.com/watch?v={self.vid}"},
                        "user": {"lockedSafetyMode": False}},
            "continuation": tok,
        }).encode()
        raw = request(
            f"https://www.youtube.com/youtubei/v1/next?key={self.key}&prettyPrint=false",
            data=body,
            headers={"Content-Type": "application/json", "Origin": "https://www.youtube.com",
                     "Referer": f"https://www.youtube.com/watch?v={self.vid}",
                     "X-YouTube-Client-Name": "1", "X-YouTube-Client-Version": self.ver})
        self.last_request = time.monotonic()
        return json.loads(raw)

    def video_meta(self):
        def find(key):
            for node in walk_dicts(self.initial):
                if key in node:
                    return node[key]
            return None

        meta = {"id": self.vid, "url": f"https://www.youtube.com/watch?v={self.vid}",
                "title": None, "channel": None, "views": None, "date": None}
        primary = find("videoPrimaryInfoRenderer")
        if primary:
            runs = primary.get("title", {}).get("runs", [])
            meta["title"] = "".join(x.get("text", "") for x in runs) or None
            vc = primary.get("videoViewCountRenderer")
            if vc:
                meta["views"] = (vc.get("viewCount", {}) or {}).get("simpleText")
            meta["date"] = (primary.get("dateText", {}) or {}).get("simpleText")
        owner = find("videoOwnerRenderer")
        if owner:
            runs = owner.get("title", {}).get("runs", [])
            meta["channel"] = "".join(x.get("text", "") for x in runs) or None

        total = None
        for node in walk_dicts(self.initial):
            if "commentsEntryPointHeaderRenderer" in node:
                total = node["commentsEntryPointHeaderRenderer"].get("commentCount", {}).get("simpleText")
                break
        meta["commentsTotalDisplay"] = total
        return meta


def payload_map(data):
    out = {}
    for node in walk_dicts(data):
        p = node.get("commentEntityPayload")
        if isinstance(p, dict):
            cid = p.get("properties", {}).get("commentId")
            if cid:
                out[cid] = p
    return out


def comment_from_payload(p):
    props = p.get("properties", {})
    toolbar = p.get("toolbar", {})
    author = p.get("author", {})
    likes = (toolbar.get("likeCountNotliked") or toolbar.get("likeCountLiked")
             or toolbar.get("likeCountA11y") or "0")
    reply_display = toolbar.get("replyCount") or ""
    reply_a11y = toolbar.get("replyCountA11y") or ""
    replies_n = parse_count(reply_display) or parse_count(reply_a11y)
    return {
        "id": props.get("commentId"),
        "author": author.get("displayName") or "",
        "authorId": author.get("channelId"),
        "published": props.get("publishedTime"),
        "text": (props.get("content", {}) or {}).get("content", ""),
        "likes": parse_count(likes),
        "likesDisplay": likes,
        "repliesCount": replies_n,
        "isCreator": bool(author.get("isCreator")),
        "isVerified": bool(author.get("isVerified")),
        "hearted": bool(toolbar.get("heartActiveTooltip")),
        "replies": [],
    }


def thread_entries(data):
    """Yield (commentId, replyToken) for root threads on a page, in order."""
    out = []
    for node in walk_dicts(data):
        th = node.get("commentThreadRenderer")
        if not isinstance(th, dict):
            continue
        vm = th.get("commentViewModel", {}).get("commentViewModel", {})
        cid = vm.get("commentId")
        if not cid:
            continue
        token = None
        replies = th.get("replies", {}).get("commentRepliesRenderer", {})
        if replies:
            token = first_token(replies.get("contents", []))
            if not token:
                token = first_token(replies)
        out.append((cid, token))
    return out


def continuation_items(data):
    out = []
    for ep in data.get("onResponseReceivedEndpoints", []):
        for k, v in ep.items():
            if isinstance(v, dict):
                out.extend(v.get("continuationItems", []))
    return out


def page_next_token(data):
    for item in reversed(continuation_items(data)):
        cir = item.get("continuationItemRenderer")
        if cir:
            tok = (cir.get("continuationEndpoint", {})
                      .get("continuationCommand", {}).get("token"))
            if tok:
                return tok
    return None


def crawl_roots(cr, cache_path, refresh=False):
    if cache_path.exists() and not refresh:
        cache = json.load(open(cache_path))
        print(f"  roots cache: {len(cache['roots'])} roots", file=sys.stderr)
        return cache

    print("  crawling root comments…", file=sys.stderr)
    payloads_for = {}
    roots = []
    seen = set()
    token = cr.token
    page = 0
    restarted = False
    zero_streak = 0
    while token and page < 300:
        page += 1
        data = cr.post(token)
        pm = payload_map(data)
        payloads_for.update(pm)
        entries = thread_entries(data)

        # honor the top sort before accepting anything
        if not restarted and not roots:
            sort_info = None
            for node in walk_dicts(data):
                if "sortFilterSubMenuRenderer" in node:
                    menu = node["sortFilterSubMenuRenderer"]
                    sel = next((x.get("title") for x in menu.get("subMenuItems", [])
                                if x.get("selected")), None)
                    toks = {x.get("title", "").lower(): (x.get("serviceEndpoint", {})
                            .get("continuationCommand", {}).get("token"))
                            for x in menu.get("subMenuItems", [])}
                    sort_info = (sel, toks)
                    break
            if sort_info and sort_info[0] and sort_info[0].lower() != "top":
                top_tok = sort_info[1].get("top")
                if top_tok:
                    print(f"    sort was {sort_info[0]}; restarting with top", file=sys.stderr)
                    restarted = True
                    token = top_tok
                    page = 0
                    continue

        added = 0
        for cid, reply_token in entries:
            if cid in seen or cid not in pm:
                continue
            seen.add(cid)
            c = comment_from_payload(pm[cid])
            c["_replyToken"] = reply_token
            roots.append(c)
            added += 1

        print(f"    root page {page}: +{added}, {len(roots)}", file=sys.stderr)
        zero_streak = zero_streak + 1 if added == 0 else 0
        nxt = page_next_token(data)
        if not nxt or nxt == token or zero_streak >= 2:
            break
        token = nxt

    cache = {
        "video": cr.video_meta(),
        "capturedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "roots": roots,
    }
    json.dump(cache, open(cache_path, "w"), ensure_ascii=False)
    return cache


def crawl_replies(cr, token, max_depth=3, seen_tokens=None):
    """Return (comments, child_tokens_by_comment_id)."""
    if not token:
        return [], {}
    seen_tokens = seen_tokens if seen_tokens is not None else set()
    comments = []
    child_tokens = {}
    seen_ids = set()
    next_tok = token
    pages = 0
    while next_tok and pages < 200:
        pages += 1
        if next_tok in seen_tokens:
            break
        seen_tokens.add(next_tok)
        data = cr.post(next_tok)
        pm = payload_map(data)
        items = continuation_items(data)
        last_cid = None
        page_next = None

        for item in items:
            vm = item.get("commentViewModel")
            if isinstance(vm, dict):
                cid = vm.get("commentId")
                if cid and cid in pm and cid not in seen_ids:
                    seen_ids.add(cid)
                    comments.append(comment_from_payload(pm[cid]))
                last_cid = cid
                continue
            th = item.get("commentThreadRenderer")
            if isinstance(th, dict):
                th_vm = th.get("commentViewModel", {}).get("commentViewModel", {})
                cid = th_vm.get("commentId")
                if cid and cid in pm and cid not in seen_ids:
                    seen_ids.add(cid)
                    comments.append(comment_from_payload(pm[cid]))
                last_cid = cid
                continue
            cir = item.get("continuationItemRenderer")
            if cir:
                tok = (cir.get("continuationEndpoint", {})
                          .get("continuationCommand", {}).get("token"))
                if not tok:
                    b = cir.get("button", {}).get("buttonRenderer", {})
                    tok = (b.get("command", {})
                            .get("continuationCommand", {}).get("token"))
                txt = button_text(cir.get("button", {}).get("buttonRenderer", {}))
                if tok:
                    if txt.lower().startswith("show more"):
                        page_next = tok
                    elif last_cid:
                        child_tokens.setdefault(last_cid, tok)

        if not page_next:
            break
        next_tok = page_next

    return comments, child_tokens


def attach_children(cr, comments, child_tokens, depth, max_depth, seen_tokens):
    if depth >= max_depth:
        return
    by_id = {c["id"]: c for c in comments}
    for cid, tok in child_tokens.items():
        parent = by_id.get(cid)
        if not parent or tok in seen_tokens:
            continue
        kids, grand = crawl_replies(cr, tok, max_depth, seen_tokens)
        existing = {c["id"] for c in parent["replies"]}
        for k in kids:
            if k["id"] not in existing:
                parent["replies"].append(k)
        attach_children(cr, parent["replies"], grand, depth + 1, max_depth, seen_tokens)


def build_tiers(roots):
    n = len(roots)
    desc = sorted((r["likes"] for r in roots), reverse=True)
    tiers = []
    for pct in (1, 5, 10, 25, 50):
        k = max(1, round(n * pct / 100.0))
        tiers.append({"id": f"top{pct}", "label": f"Top {pct}%", "percent": pct,
                      "count": k, "cutoff": desc[k - 1] if k <= n else 0})
    tiers.append({"id": "all", "label": "All roots", "percent": 100,
                  "count": n, "cutoff": desc[-1] if desc else 0})
    return tiers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--out", default=str(ROOT / "data" / "corpus.json"))
    ap.add_argument("--refresh", action="store_true", help="ignore the roots cache")
    args = ap.parse_args()

    vid = video_id(args.video)
    CACHE.mkdir(parents=True, exist_ok=True)
    roots_cache = CACHE / f"roots-{vid}.json"
    replies_cache = CACHE / f"replies-{vid}.json"

    cr = Crawler(vid)
    cr.load_watch()
    cache = crawl_roots(cr, roots_cache, refresh=args.refresh)
    roots = cache["roots"]

    done = {}
    if replies_cache.exists():
        try:
            done = json.load(open(replies_cache))
        except Exception:
            done = {}

    todo = [r for r in roots if r.get("_replyToken")]
    print(f"  reply threads to fetch: {len(todo)} (cached: {len(done)})", file=sys.stderr)

    for i, root in enumerate(todo, 1):
        rid = root["id"]
        if rid in done:
            continue
        try:
            replies, child_tokens = crawl_replies(cr, root["_replyToken"])
            attach_children(cr, replies, child_tokens, 0, 3, set())
            done[rid] = replies
        except Exception as e:
            print(f"    ! {rid}: {e}", file=sys.stderr)
            done[rid] = []
        if i % 10 == 0 or i == len(todo):
            json.dump(done, open(replies_cache, "w"), ensure_ascii=False)
            print(f"    replies {i}/{len(todo)}  ({len(done)} threads saved)", file=sys.stderr)

    json.dump(done, open(replies_cache, "w"), ensure_ascii=False)

    out_roots = []
    for r in roots:
        rr = {k: v for k, v in r.items() if not k.startswith("_")}
        rr["replies"] = done.get(r["id"], [])
        rr["repliesFetched"] = len(rr["replies"])
        # flatten child reply counts for display sanity
        out_roots.append(rr)

    out_roots.sort(key=lambda c: (-c["likes"], c["id"]))
    total_likes = sum(c["likes"] for c in out_roots)

    corpus = {
        "schema": 1,
        "video": cache["video"],
        "capturedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "rootCount": len(out_roots),
        "totalLikes": total_likes,
        "tiers": build_tiers(out_roots),
        "comments": out_roots,
    }
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    json.dump(corpus, open(out_path, "w"), ensure_ascii=False)
    total_replies = sum(r["repliesFetched"] for r in out_roots)
    print(f"wrote {out_path}: {len(out_roots)} roots, {total_replies} replies", file=sys.stderr)


if __name__ == "__main__":
    main()
