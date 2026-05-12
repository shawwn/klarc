# Scraping Hacker News

`scrape.arc` fetches the live HN front page and item pages so you can
recover the flagged / dead / collapsed comment status that the
official Firebase API doesn't expose.  Item + comment data comes from
HTML scraping; user profiles come from the API.

# Quick start

```sh
./sharc
```

```
arc> (load "scrape.arc")
arc> (scrape!)
```

That logs in as `hnscraper`, fetches the top 60 stories from HN's
`/v0/topstories.json` (one API call), pulls each item's HTML at 3
seconds apart, and writes JSON under `arc/scrape/`.  Discovered
authors are then fetched from the Firebase API.

A full run takes a few minutes for the items and longer (5-20 min)
for the users, because each user is a separate `curl` subprocess.

# Mirroring HN on your local News

To serve HN's current front page from the local News server:

```
arc> (load "news.arc")
arc> (load "scrape.arc")
arc> (import-scrape!)
arc> (asv 8080)
```

Then visit http://localhost:8080.

`import-scrape!` populates `stories*`, `items*`, and `profs*` in
memory and writes them to News's `arc/news/story/` and
`arc/news/profile/` directories, so a subsequent `(nsv)` (which calls
`load-items` only when `stories*` is nil) sees them.

# Files

Everything writes under `arc/scrape/`:

| Path                            | Contents                                                      |
| ------------------------------- | ------------------------------------------------------------- |
| `arc/scrape/cookies.txt`        | curl cookie jar for the HN session                            |
| `arc/scrape/front.json`         | last scrape's `[{id, page, rank}, ...]` in HN's order         |
| `arc/scrape/item/{id}.json`     | one item's story + full comment tree (with status flags)      |
| `arc/scrape/user/{id}.json`     | one user profile (from Firebase API)                          |
| `arc/scrape/last-fetch.lisp`    | `id -> unix-seconds` for the per-id refetch cooldown          |

# Per-item JSON

```json
{
  "story": {
    "id": 48106024,
    "type": "story",
    "by": "surprisetalk",
    "title": "Learning Software Architecture",
    "url": "https://matklad.github.io/...",
    "text": null,
    "score": 110,
    "time": 1778578221,
    "fetched_at": 1778586000,
    "dead": null
  },
  "comments": [
    {
      "id": 48106273,
      "by": "Maverick_G",
      "time": 1778581299,
      "parent": 48085993,
      "indent": 0,
      "text": "...",
      "dead": true,
      "flagged": true,
      "collapsed": null,
      "deleted": null,
      "descendants": 1
    },
    ...
  ]
}
```

`parent` is derived from the indent column (HN's HTML doesn't include
parent ids on rendered comment rows; we walk in DFS order and remember
the most recent comment id at each indent level).

# Incremental updates

A second `(scrape!)` skips items refetched within the last hour
(`scrape-refetch-secs*`, default 3600).  Comments that were present
before but missing from the new fetch are kept with `deleted: true`
appended to the comment list, so you don't lose history.

To force a refetch of everything:

```
arc> (scrape! t)
```

# Smaller / dev runs

```
arc> (scrape! nil 5)     ; just the first 5 ranked stories
arc> (scrape! t 5)       ; same, force-refetch
```

# Login

Credentials live in `scrape.json` at the repo root.  It's gitignored;
on first run it's copied from the committed `scrape.example.json`
template (which contains only the username).

Auth resolution, in order:

1. **Existing valid cookie jar** (`arc/scrape/cookies.txt`).  If a
   prior session left a working cookie, nothing else runs.
2. **Pre-baked cookie** from `HN_SCRAPER_COOKIE` env var or
   `"cookie"` field in `scrape.json`.  Value is the raw
   `<username>&<token>` string -- copy it from your browser's
   devtools (Application → Cookies → news.ycombinator.com → `user`).
   This skips the password login entirely.
3. **Password login**:
   1. `HN_SCRAPER_PASSWORD` env var (preferred for CI / non-interactive)
   2. `"password"` field in `scrape.json`
   3. Interactive no-echo prompt, if stdin is a TTY

If the prompt path is taken and login succeeds, the password is
written back to `scrape.json` so subsequent runs skip the prompt.
A typo'd password is *not* saved.  Env-supplied passwords and
cookies are never persisted.

The account's About page invites contact (shawnpresser@gmail.com) if
the scrape is too aggressive.

To force a re-login:

```
arc> (hn-login)
```

Or override credentials explicitly:

```
arc> (hn-login "other-user" "their-password")
```

**Don't commit `scrape.json` if it contains a password.**  The
`.gitignore` already lists it, but double-check before pushing.

# Logging in as imported users

After `(import-scrape!)`, every imported HN user has a password set
to `"password"` -- so you can log in to your local mirror as any of
them and see things from their perspective.

The shared dev password comes from `scrape-dev-password*`, which
defaults to `"password"`.  Override by adding a `"dev-password":
"..."` field to `scrape.json`.  Set it to `null` or the empty string
to skip password installation entirely.

Caveats:

- Only set when the user has no existing `hpasswords*` entry -- a
  real password (e.g. one set via `/login` in the local UI) is never
  clobbered.
- Don't expose this server beyond localhost; every imported account
  is one guessable string away.

# Crawl delay

`scrape-crawl-delay*` is set to 3 seconds.  HN's `robots.txt`
advertises `Crawl-delay: 30` for generic bots; the 3s rate is
explicitly owner-authorized via the `hnscraper` account.  Revert to
30 if HN ops asks.

To change it for one session:

```
arc> (= scrape-crawl-delay* 10)
arc> (scrape!)
```

User-profile fetches are not rate-limited on our side (they go to a
different host, `hacker-news.firebaseio.com`).

# Verifying status detection

`scrape-verify-flags.arc` re-fetches the 4 comment examples from
[the original scraper prompt](docs/agents/handoff/2026-05-12-002-hn-scraper-prompt.txt)
and asserts each has the expected flag combination.  Useful sanity check if you suspect HN's markup has
shifted:

```sh
./sharc scrape-verify-flags.arc
```

Expected output:

```
PASS 48106273 in 48085993 dead=T flagged=T collapsed=
PASS 48105810 in 48038191 dead=T flagged= collapsed=
PASS 48092598 in 48086190 dead=T flagged=T collapsed=T
PASS 48085067 in 48073201 dead= flagged= collapsed=T
```

# Useful entry points

| Form                                | Behavior                                         |
| ----------------------------------- | ------------------------------------------------ |
| `(scrape!)`                         | full one-shot crawl                              |
| `(scrape! force limit)`             | optional knobs (`force` re-fetches; `limit` caps)|
| `(scrape-item! id)`                 | scrape one item by id                            |
| `(scrape-user! id)`                 | scrape one user by handle                        |
| `(import-scrape!)`                  | populate News from disk JSON                     |
| `(hn-login)`                        | refresh the cookie jar                           |
| `(parse-item-page html)`            | offline: parse a saved HTML string               |
| `(fetch-top-stories)`               | just the API id list                             |

# Implementation notes

- `pipe-from` (in `arc0.lisp`) is configured for `:latin-1` so curl's
  byte stream round-trips cleanly through Latin-1 file I/O.  Without
  it, multi-byte UTF-8 chars from HN's HTML (e.g. curly quotes)
  crash on output to JSON files.
- `parse-comments` slices the raw HTML into per-comment substrings
  *first*, then parses each in isolation.  Without that scoping,
  `posmatch` scans the full 2MB document for every field of every
  comment and parse times explode to minutes.
- See [the handoff doc](docs/agents/handoff/2026-05-12-002-hn-scraper.md)
  for the full design rationale and Arc-specific gotchas encountered
  while building this.
