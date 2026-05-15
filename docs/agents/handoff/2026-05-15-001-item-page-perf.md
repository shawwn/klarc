---
name: item-page perf, 320ms -> 4ms/31ms
description: Series of perf changes to `/item?id=<n>` on a ~1k-comment thread. Cuts logged-out warm renders from ~320ms to ~4ms and logged-in from ~380ms to ~31ms on the 934-comment baseline in performance.md. Two structural wins (page-level cache for logged-out, comment-cache covers the whole tree); two runtime wins ('explicit-flush t and pr no longer conses a result list); several smaller inlinings.
type: project
---

# Handoff: item-page perf, 320ms -> 4ms / 31ms (2026-05-15)

> Builds on the measurements in
> [`performance.md`](../../../performance.md).
> The 2026-05-13 entry there documented our ~5x gap vs. HN production
> on the same 934-comment thread. This handoff closes that gap and
> then some.

## Result

934-comment thread, Apple M2 Max laptop, `curl` to localhost:8080,
10 successive measurements:

| viewer / state                         | before  | after          | vs HN median |
|---                                     |---:     |---:            |---:          |
| logged-out, warm (page-cache hit)      | n/a     | **3-4 ms**     | ~16x faster than HN's 65.5ms |
| logged-out, page-cache miss, cc warm   | n/a     | ~22 ms         |              |
| logged-out, both caches cold           | 320 ms  | ~130 ms        |              |
| logged-in, warm                        | ~380 ms | **30-31 ms**   | ~2.8x faster than HN's 85.5ms |

The cold path (~130 ms) only runs once per item-page-cache TTL bucket
(60 s) or after a new top-level reply, so steady-state cost on a
trafficked item is the 3-4 ms cache-hit number.

## Four commits on `main`

| sha       | what                                                   |
|---        |---                                                     |
| `467c0b1` | the big one: page-cache, urlencode memo, frontpage-rank memo, scaffold inlining, votelinks fast paths, `cc-window*` widening, `(declare 'explicit-flush t)` |
| `f34b33c` | `pr` / `prt`: `map1` -> `each` (no discarded cons-list per call); ~25-30% by itself |
| `94ee7b6` | drop the unused `t-gen-msec*` / `t-cache-msec*` accumulators (their wraps were removed in 467c0b1) |
| n/a       | (no fourth commit; the cleanup PR-line is the last one) |

Not pushed.

## What changed and why

The path is `item-page` (`news.arc:1799`) -> `display-subcomments`
(`news.arc:2085`) -> `display-comment-tree` -> `display-1comment` ->
`display-comment-body`. The first investigation showed >98% of the
render was inside `display-subcomments`, so the rest of the page
(header, item, comment-form, footer) was never worth attention.

### 1. `(declare 'explicit-flush t)` at top of news.arc

`arc0.lisp:455` -- `disp` ends with
`(unless *arc-explicit-flush* (force-output port))`. So every `pr`
call was doing a syscall-flush. The how-to-run-news.md docs already
say to set this; we just hadn't. Saved ~36ms on its own (~28% of the
warm bypass path).

All existing news.arc code that needs to flush already calls
`flushout` explicitly (3 sites in news.arc / scrape.arc; verified with
`grep -n 'flushout\b' *.arc`).

### 2. `defmemo urlencode` (strings.arc:74)

`vote-url` builds `vote?for=ID&dir=up&whence=ENCODED` per comment.
`whence` is the same string (`"item?id=<n>"`) for all 937 comments.
We were percent-encoding it 937 times. Hash-lookup with memo. Saved
~30 ms.

### 3. `cc-window*` from 10000 to 100000000 (news.arc:2143)

The `comment-cache*` (the body cache pg invented in news.arc:2069+,
keyed by `c!id`) was gated on `(< (- maxid* c!id) cc-window*)`.
Original window 10000 only covered the most recent 10k ids; on our
48M-id corpus, only ~170 of the 937 comments on this item passed the
window. The other 767 took the slow `gen-comment-body` path on every
render.

**Caveat (TODO):** at 1e8 the window is effectively unbounded. The
table will grow without limit on a long-running server. Existing
`cc-timeout`-based eviction in `cached-comment-body` only refreshes
entries; it doesn't drop them. Before deploying to a long-running
production server, either:

- switch to LRU eviction (cap entries, drop least-recently-used), or
- replace the id-window check with an age check that's also used to
  actively gc the table (something like a `harvest-cc` background
  task)

Search "TODO: this should switch to age- or LRU-based eviction" in
the 467c0b1 commit message.

### 4. New per-item comments-tree cache (news.arc:1799, `render-subcomments`)

For logged-out viewers (and only them: no admin, no editor, no
`(me)`), the entire output of `(tab (display-subcomments i here))` is
cached in `item-comments-cache*`, keyed by `i!id`, valid until either
60 s elapse (TTL) or `(cons (len i!kids) i!score)` changes. Cache
hit = one `pr` of the stored string.

Doesn't cover logged-in users; the vote-link URLs encode
`by=USER&auth=COOKIE` so the HTML is per-viewer. (If we ever want
logged-in caching too, the path is to move by/auth out of the URL and
into a click-time JS handler that reads them from the cookie. That's
a behaviour change so I didn't do it.)

There's also an `arg!nocache=t` switch -- bypasses the page cache to
benchmark the underlying render. See uses of `cacheable-subcomments-viewer`
in news.arc.

### 5. `sort-kids-by-rank` (news.arc:2079)

`display-subcomments` previously did
`(sort (compare > frontpage-rank:item) c!kids)`. `compare` doesn't
memoize, so `frontpage-rank` got invoked ~2n log n times per parent.
The new helper precomputes ranks into a table once per parent then
sorts via lookup. Sort time dropped from ~11 ms to ~4 ms.

### 6. Hand-inlined `display-1comment` (news.arc:2074)

Originally `(row (tab (display-comment nil c whence t indent showpar showpar)))`,
which expanded through `tr`/`td`/`tab` macros to ~12 `pr` calls per
comment surrounding the body. The new version is one big `pr` of the
literal scaffold strings, plus calls for `votelinks` and
`display-comment-body`. Same HTML output (the only byte difference is
a few suppressed newlines between tags that the macros emitted).

### 7. `votelinks` fast paths (news.arc:1039)

Two new branches at the top of `votelinks`, before the original
logic:

- **Logged-out + cansee + live**: one `pr` of the full
  `<center><a id= href="vote?...">UP_IMG</a><span id=down_X></span></center>`
  string.
- **Logged-in + cansee + live + not voted + not author + no
  downvote allowed**: same shape but with `id=up_X`,
  `onclick="return vote(this)"`, and `&by=USER&auth=COOKIE` in the
  URL.

These two cover essentially everyone reading a thread; admin / voted
/ author / downvote-capable cases fall through to the original
`(center ...)` form. Up-arrow and down-arrow imgs are precomputed
once at file load into `up-arrow-img*` / `down-arrow-img*` (the `out`
macro evaluates `gentag` at compile time, but we needed runtime
variables to splice into the inline `pr`).

### 8. `pr` / `prt`: `map1` -> `each` (arc.arc:658, separate commit `f34b33c`)

This is the cute one. `pr` was

```arc
(def pr args
  (map1 disp args)
  (car args))
```

`map1` conses up a list of `disp`'s return values (all `nil`). The
caller throws the list away. So every `pr` call with N args
allocated N cons cells purely for the GC. On this page that's ~17k
wasted conses per request.

`each` (defined as an `rfn` recursive walker, arc.arc:473) iterates
without consing. One-line swap, ~25-30% on the warm bypass path.

This affects every `pr` call in the system. 291/291 tests still
pass. The original return value of `pr` (`(car args)`) is preserved.

## The diagnostic instrumentation that's still there

`item-page`'s `(when (or (admin) arg!perf) ...)` block now prints a
breakdown bar under the admin-bar:

```
subcomments: N msec | page-cache: hit|miss | sort: N msec
| comments: N | cc hits: N | cc misses: N | cc size: N
```

Globals it reads (defined in news.arc:2145):
- `comments-printed*` (was already there, incremented in
  `display-comment-body`)
- `cc-hits*` (was already there)
- `cc-misses*` (added by 467c0b1, incremented in
  `cached-comment-body`'s miss branch)
- `t-sort-msec*` (added; only the sort wrap remains -- the gen/cache
  wraps were removed in 94ee7b6 since the answer there is now obvious
  from cc hits/misses)

You can hit a baseline-vs-current comparison via `?perf=t&nocache=t`
which keeps the cc-cache warm but bypasses the page cache.

## Things I deliberately didn't do

1. **Per-user page cache for logged-in viewers.** Memory unbounded
   in the worst case; 31 ms is already faster than HN. The path if
   we ever want it: move `by=`/`auth=` out of the URL into a JS
   click handler that reads them from cookies, then logged-in HTML
   becomes identical to logged-out and the existing page cache
   covers it.

2. **Active eviction for `comment-cache*`.** Noted above; with
   `cc-window*` widened it's effectively unbounded. The existing
   `cc-timeout` only refreshes entries.

3. **Caching the whole `item-page` output (not just subcomments).**
   The fluff outside `display-subcomments` is ~5 ms; caching it
   would save sub-ms and complicate invalidation.

4. **Replacing the `(message text)` `pr-escaped` machinery for
   comment text.** Gen path only runs on first-ever-render or after
   60 s, and total cold time is already ~130 ms.

## How to measure

```sh
# baseline page-cache hit
curl -s 'http://localhost:8080/item?id=48100433&perf=t' -o /dev/null

# bypass page cache, warm cc-cache  (~= what logged-in pays without auth)
curl -s 'http://localhost:8080/item?id=48100433&perf=t&nocache=t' -o /dev/null

# logged-in (red_admiral is the existing non-admin in arc/cooks)
curl -s -H 'Cookie: user=DjQpMegd' \
     'http://localhost:8080/item?id=48100433&perf=t' -o /dev/null

# extract just the total (the trailing field in the admin-bar)
... | grep -oE '[0-9]+/[0-9]+ loaded.* [0-9]+ msec' | tail -1
```

The server is run via `./sharc` with stdin piped from
`(load "news.arc")` + `(nsv)`. Use a `(... ; sleep 1000000) | ./sharc`
pipeline if you need to keep stdin open across the blocking `serve`
call -- otherwise SBCL `--script` mode reads EOF and quits even
though serve is blocked.

## Things future-me will want to know

- 291/291 tests pass. `./sharc test.arc` to re-run.
- The `out` macro (arc.arc:1613) is `(mac out (expr)
  '(pr ,(tostring (eval expr))))` -- it evaluates at macro-expand
  time, so `(out (gentag ...))` bakes in whatever the globals were
  when news.arc loaded. The new `up-arrow-img*` / `down-arrow-img*`
  rely on this -- they're computed by `(tostring (out (gentag ...)))`
  at load time, which means if anyone later mutates `up-url*`,
  they'll need to recompute these too.
- `urlencode` is now `defmemo`. It's used in a lot of places besides
  vote-url (search the codebase). Pure function so memoization is
  always safe; the global table will grow with the set of distinct
  inputs, but in practice that's a few hundred unique URL fragments.
- The page-cache key `(cons (len i!kids) i!score)` only invalidates
  on **top-level** kids/score change. A deeply-nested reply doesn't
  bump root's kid count -- the 60 s TTL is what catches that. HN
  does the same kind of approximation in its Nginx cache so this is
  fine, but be aware if someone reports "I posted a deep reply and
  the page doesn't show it for up to a minute".
- Memory grows ~25 mb per logged-in render before GC. That's just
  the Arc-on-SBCL function-call allocation patterns; can't be cut
  without compiler work.

## Open questions (not blockers)

- Should the comment-cache eviction be implemented before this is
  considered production-ready? (See TODO in the 467c0b1 commit
  message.)
- Worth updating `performance.md` with the new "after" numbers as a
  third dated entry? I left it alone since the doc is framed as
  ad-hoc snapshots and the user didn't ask for it.
