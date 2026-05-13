# Performance log

Ad-hoc snapshots of how long pages take to render on the local mirror,
recorded before we knew enough to write proper benchmarks.  Treat
these as anecdotes: they're tied to a specific corpus snapshot (often
listed in the entry) and a specific machine, and they go stale every
time the corpus is re-imported.

Each entry should record:

- date, and ideally the commit (`git rev-parse HEAD`) it was measured against
- what page was loaded and against what corpus snapshot
- how the timings were collected (browser dev tools, `curl -w '%{time_total}'`, ...)
- raw numbers (so future entries can compare apples to apples)

---

## 2026-05-13 -- item page, 632 comments, logged-in vs logged-out

**Page:** local mirror of `item?id=48100433` (HN snapshot at 593 points,
632 comments at scrape time).

**Method:** browser page load, 10 successive measurements each.  Times
in milliseconds.

| viewer       | n  | min | median | mean  | max |
|---           |---:|---: |---:    |---:   |---: |
| logged-in    | 10 | 158 | 166    | 168.3 | 190 |
| logged-out   | 10 | 130 | 138    | 138.2 | 147 |

Raw:

```
logged-in:  190 164 181 170 168 160 159 160 173 158
logged-out: 142 140 139 147 137 134 130 134 135 144
```

About 30 ms slower for the logged-in path -- that's the cost of all
the per-user state news.arc computes (vote arrows, hide links,
showdead-gated markers, threads-link header).

**Note:** this snapshot is about to be invalidated by a re-scrape
(the same thread is up to 979 comments / 879 points on HN now).
New numbers will follow under their own entry.
