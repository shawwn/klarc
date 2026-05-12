; Hacker News scraper.
;
; Fetches the live HN front page (and page 2) so flagged / dead /
; collapsed comments (which the official Firebase API doesn't expose)
; can be recovered by parsing the HTML directly.  Items + comments
; come from the HTML; user profiles come from the Firebase API for
; speed.
;
; Usage:
;   ./sharc scrape.arc                         ; one-shot crawl
;   arc> (load "scrape.arc") (scrape!)         ; same, interactive
;   arc> (load "scrape.arc") (import-scrape!)  ; load JSON into News
;
; Output:
;   arc/scrape/cookies.txt           curl cookie jar (HN session)
;   arc/scrape/item/{id}.json        merged story + comment tree
;   arc/scrape/user/{id}.json        user profile
;   arc/scrape/last-fetch.lisp       per-id last-fetched timestamps
;
; Respects the Crawl-delay from https://news.ycombinator.com/robots.txt
; between HTML page fetches (no delay for Firebase user lookups, which
; hit a separate host that doesn't publish one).

(load "json.arc")


; ----- Config -----

(= scrape-dir*       "arc/scrape/"
   scrape-item-dir*  "arc/scrape/item/"
   scrape-user-dir*  "arc/scrape/user/"
   scrape-cookies*   "arc/scrape/cookies.txt"
   scrape-fetchlog*  "arc/scrape/last-fetch.lisp"
   scrape-user-agent*
     "hnscraper (https://news.ycombinator.com/user?id=hnscraper; contact shawnpresser@@gmail.com)"
   scrape-refetch-secs* 3600       ; skip items refetched within last hour
   ; robots.txt advertises Crawl-delay: 30 for generic bots.  The
   ; hnscraper account has explicit owner authorization to run faster;
   ; the About page invites contact if it's too aggressive.  Keep this
   ; conservative; revert to 30 if HN ops asks.
   scrape-crawl-delay*  3
   ; max parallel curl subprocesses for the user API.  Firebase has no
   ; advertised rate limit; 10 is comfortable.
   scrape-user-concurrency* 10
   scrape-hn-host*      "https://news.ycombinator.com"
   scrape-api-host*     "https://hacker-news.firebaseio.com/v0")

(= scrape-last-fetch* (table))     ; id -> unix seconds when last fetched


; ----- Shell + curl -----
;
; `shell` drops nils from the arg list so callers can conditionally
; include flags inline: `(shell 'curl (if quiet '-sS) url)`.

(def shellquote (str)
  (string "'" (multisubst (list (list "'" "'\"'\"'")) (string str)) "'"))

(def shellargs (cmd (o args))
  (string cmd " " (intersperse #\space (map shellquote:string (rem nil args)))))

(def shell (cmd . args)
  ; runs cmd with args, returns stdout as a string.
  (allchars (pipe-from (shellargs cmd args))))

(def shellsafe (cmd . args)
  (errsafe (apply shell cmd args)))

(def curl-args () (list "-sS" "--connect-timeout" "20" "--max-time" "120"
                        "-A" scrape-user-agent*))

(def curl-get (url)
  (apply shellsafe 'curl (+ (curl-args) (list "-b" scrape-cookies* url))))

(def curl-get-public (url)
  (apply shellsafe 'curl (+ (curl-args) (list url))))

(def curl-post-form (url fields)
  ; fields: alist of (key value) pairs.  POST as form-urlencoded.
  ; Saves + sends cookies via scrape-cookies*.
  (apply shellsafe 'curl
         (+ (curl-args)
            (list "-c" scrape-cookies* "-b" scrape-cookies*)
            (mappend (fn ((k v))
                       (list "--data-urlencode" (+ k "=" v)))
                     fields)
            (list url))))


; ----- Scraper config (username + optional password) -----
;
; `scrape.json` is gitignored.  On first run we copy
; `scrape.example.json` (committed, username only) into place.  The
; user may add a `"password":...` field manually; if they don't, we
; prompt at first login and save it back.  Password resolution order
; is: HN_SCRAPER_PASSWORD env var > scrape.json > prompt.

(= scrape-config*  "scrape.json"
   scrape-example* "scrape.example.json")

(def load-scrape-config ()
  (unless (file-exists scrape-config*)
    (when (file-exists scrape-example*)
      (system (+ "cp " (shellquote scrape-example*) " "
                       (shellquote scrape-config*)))))
  (or (and (file-exists scrape-config*) (load-json scrape-config*))
      (obj username "hnscraper")))

(def save-scrape-config (cfg)
  (save-json cfg scrape-config*))


; ----- Password prompt (no-echo on TTYs) -----

(def stdin-is-tty? ()
  ; sh's `test -t 0` returns success iff stdin is a terminal.
  (is "yes"
      (errsafe (allchars (pipe-from "test -t 0 && printf yes")))))

(def read-password-noecho ()
  ; turn echo off around (readline) so the password doesn't print.
  ; the `after` makes sure we restore echo even on Ctrl-C / errors.
  (after (do (system "stty -echo 2>/dev/null") (readline))
         (system "stty echo 2>/dev/null")
         (prn)))

(def prompt-password (user)
  (unless (stdin-is-tty?)
    (err (+ "no terminal: set HN_SCRAPER_PASSWORD in env or "
            "add \"password\" to " scrape-config*)))
  (pr "HN password for " user ": ") (flushout)
  (read-password-noecho))

(def resolve-password (cfg)
  ; returns (pw source) where source is 'env, 'config, or 'prompt.
  ; nil if no password could be obtained (and no terminal to prompt).
  (or (whenlet pw (getenv "HN_SCRAPER_PASSWORD") (list pw 'env))
      (whenlet pw cfg!password                  (list pw 'config))
      (whenlet pw (prompt-password (or cfg!username "hnscraper"))
        (and (~empty pw) (list pw 'prompt)))))


; ----- Pre-baked cookie support -----
;
; If the user supplies HN_SCRAPER_COOKIE in the environment or a
; "cookie" field in scrape.json, we skip the login dance and just
; write the cookie value into curl's Netscape jar.  Format is the
; raw "username&token" string HN's `user` cookie carries (copy it
; from your browser's devtools).

(def write-cookie-file (value)
  ; Netscape cookie jar line; tabs between fields.
  ;   #HttpOnly_news.ycombinator.com  FALSE  /  TRUE  <expiry>  user  <value>
  ; HN's own cookies expire at 2147368447 (~year 2038), so we copy that.
  (let line (apply + (intersperse #\tab
              (list "#HttpOnly_news.ycombinator.com"
                    "FALSE" "/" "TRUE" "2147368447" "user" value)))
    (writefile-raw (+ "# Netscape HTTP Cookie File\n" line "\n")
                   scrape-cookies*)))

(def seed-cookie-from-config! (cfg)
  ; if env or cfg has a cookie value, install it into the jar.
  ; returns t if a cookie was installed.
  (whenlet c (getenv "HN_SCRAPER_COOKIE" cfg!cookie)
    (write-cookie-file c)
    t))


; ----- Login -----

(def hn-logged-in? ((o user))
  ; quick check: fetch /news, look for the user?id=<user> link.
  (let u (or user (let cfg (load-scrape-config) cfg!username) "hnscraper")
    (aif (curl-get (+ scrape-hn-host* "/news"))
         (and (posmatch (+ "user?id=" u) it) t))))

(def hn-login ((o user) (o pw))
  (with (cfg (load-scrape-config) u user p pw source nil)
    (= u (or u cfg!username (err "no username in scrape.json")))
    (unless p
      (let resolved (resolve-password cfg)
        (unless resolved (err "no password supplied"))
        (= p      (car resolved)
           source (cadr resolved))))
    (prn "login: " u)
    (curl-post-form (+ scrape-hn-host* "/login")
                    (list (list "acct" u)
                          (list "pw"   p)
                          (list "goto" "news")))
    (let ok (hn-logged-in? u)
      (prn "  -> " (if ok "logged in" "FAILED"))
      ; only persist a prompted password if the login actually worked
      (when (and ok (is source 'prompt))
        (= cfg!password p)
        (save-scrape-config cfg)
        (prn "  password saved to " scrape-config*))
      ok)))

(def ensure-login ()
  ; Order: (1) existing valid cookie jar, (2) cookie supplied via env
  ; or scrape.json, (3) password login.
  (let cfg (load-scrape-config)
    (or (and (file-exists scrape-cookies*) (hn-logged-in? cfg!username))
        (and (seed-cookie-from-config! cfg)
             (hn-logged-in? cfg!username))
        (hn-login))))


; ----- HTML helpers -----
;
; HN's markup is generated by a single Arc template so it's regular and
; quote-stable.  We just hunt for the right substring landmarks.

(def html-attr (src start name)
  ; given src and a position just inside a tag, find `name="..."` (or
  ; name='...') and return the attribute value (HTML-undecoded).
  ; Searches within the same tag only -- stops at `>`.
  (withs (tag-end (or (posmatch ">" src start) (len src))
          pat-eq  (+ name "=")
          p       (posmatch pat-eq src start))
    (when (and p (< p tag-end))
      (withs (q     (+ p (len pat-eq))
              qchar (if (< q tag-end) (src q))
              close (if (or (is qchar #\") (is qchar #\'))
                        (posmatch (string qchar) src (+ q 1))))
        (when (and close (<= close tag-end))
          (cut src (+ q 1) close))))))

(def between (src pat-open pat-close (o start 0))
  ; find the text between pat-open and pat-close (both string patterns),
  ; starting search from `start`.  returns (text end-pos) or nil.
  (whenlet p (posmatch pat-open src start)
    (let s (+ p (len pat-open))
      (whenlet e (posmatch pat-close src s)
        (list (cut src s e) e)))))

; ----- HTML entity decoding -----

(def html-unescape (s)
  (multisubst '(("&amp;"  "&")
                ("&lt;"   "<")
                ("&gt;"   ">")
                ("&quot;" "\"")
                ("&#x27;" "'")
                ("&#x2F;" "/")
                ("&#x3D;" "=")
                ("&nbsp;" " "))
              s))


; ----- Front page ordering -----
;
; We get the ranked story list from the HN API's /v0/topstories.json --
; one request returns up to 500 ids, which is more authoritative than
; HTML-scraping /news + /news?p=2.  Per-story HTML is still scraped (in
; parse-item-page) for the dead/flagged/collapsed comment markers that
; the API doesn't expose.

(def fetch-top-stories ()
  ; returns list of story ids in HN's current top-stories order, or nil
  (errsafe:from-json (curl-get-public (+ scrape-api-host* "/topstories.json"))))


; ----- HTML helpers used by item parsing -----

(def parse-titleline! (html start rec)
  (aif (between html "<span class=\"titleline\">" "</span>" start)
       (withs (inner (car it)
               m-url (between inner "<a href=\"" "\"" 0)
               m-title (and m-url (between inner ">" "</a>" (cadr m-url)))
               url    (and m-url (html-unescape (car m-url))))
         ; an "item?id=N" href on the title means this is an Ask/text
         ; submission with no external URL.
         (when (and url (no (begins url "item?id=")))
           (= rec!url url))
         (when m-title (= rec!title (html-unescape (car m-title)))))))

(def parse-subtext-row! (html start rec open-pat close-pat)
  (aif (between html open-pat close-pat start)
       (withs (inner (car it)
               m-score (between inner "<span class=\"score\"" "</span>" 0)
               m-by    (between inner "<a href=\"user?id=" "\"" 0)
               m-age   (between inner "<span class=\"age\" title=\"" "\"" 0))
         (when m-score
           (let txt (car m-score)
             (aif (posmatch ">" txt)
                  (= rec!score
                     (errsafe:int (car (tokens (cut txt (+ it 1)))))))))
         (when m-by   (= rec!by (car m-by)))
         (when m-age
           (let toks (tokens (car m-age))
             (when toks (= rec!time (errsafe:int (last toks)))))))))


; ----- Item / comment page parsing -----
;
;   ... <tr class="athing comtr[ coll]" id="ID">
;       <td><table border="0"><tr>
;         <td class="ind" indent="N">...
;         <td valign="top" class="votelinks[ nosee]">...
;         <td class="default">
;           <div ...><span class="comhead">
;             <a href="user?id=USER" class="hnuser">USER</a>
;             <span class="age" title="ISO UNIX">...</span>
;             [flagged]  [dead]   <-- optional inline plaintext
;             <span class="navs">...</span>
;             <a class="togg clicky" id="ID" n="DCOUNT" ...>[..]</a>
;           </span></div><br>
;           <div class="comment[ noshow]">
;             <div class="commtext c00|c5A|cDD">TEXT-INLINE-HTML</div>
;             <div class="reply">...
;           </div>
;         </td>
;       </tr></table></td>
;     </tr>

(def parse-item-page (html)
  ; Parses both the story (top fatitem) and the comment list.
  ; Returns (obj story comments) where story is a table and comments
  ; is a list of comment tables in DFS render order.
  (withs (story    (parse-fatitem html)
          comments (parse-comments html story!id))
    (obj story story comments comments)))

(def parse-fatitem (html)
  ; The story page's top item lives inside <table class="fatitem"> as a
  ; <tr class="athing submission" id="N"> row followed by a subtext row.
  ; Story text (for Ask HN / text submissions) lives in <div class="toptext">.
  (let rec (obj type 'story dead nil deleted nil)
    (whenlet ft (posmatch "<table class=\"fatitem\"" html 0)
      (whenlet p (posmatch "<tr class=\"athing" html ft)
        (aif (html-attr html p "id")
             (= rec!id (errsafe:int it)))
        (parse-titleline! html p rec)
        (parse-subtext-row! html p rec "<td class=\"subtext\">" "</tr>")
        (aif (between html "<div class=\"toptext\">" "</div>" p)
             (= rec!text (html-unescape (car it))))))
    rec))

(def parse-comments (html story-id)
  ; Split the html into per-comment chunks once, then parse each in
  ; isolation.  Without this, posmatch's O(N) scans on the full 2MB
  ; html turn parse-comments into N*M-quadratic.
  (with (acc nil
         positions nil
         start 0
         anchor "<tr class=\"athing comtr"
         indent-stack (table))
    (whilet p (posmatch anchor html start)
      (push p positions)
      (= start (+ p (len anchor))))
    (let ps (rev positions)
      (forlen i ps
        (let p (ps i)
          (let row (cut html p (or (ps (+ i 1)) (len html)))
            (let c (parse-comment-row row story-id indent-stack)
              (when c
                (push c acc)
                (let ind c!indent
                  (= (indent-stack ind) c!id)
                  (each k (keys indent-stack)
                    (if (> k ind) (wipe (indent-stack k)))))))))))
    (rev acc)))

(def parse-comment-row (row story-id indent-stack)
  ; `row` is the substring starting at `<tr class="athing comtr` for one
  ; comment, up to (but not including) the next comment row's start.
  (catch
    (let rec (obj type 'comment dead nil flagged nil collapsed nil deleted nil)
      ; collapsed: class="athing comtr coll"
      (when (posmatch "comtr coll" row 0)
        (= rec!collapsed t))
      ; id="..."
      (aif (html-attr row 0 "id")
           (= rec!id (errsafe:int it)))
      (unless rec!id (throw nil))
      ; indent
      (aif (between row "<td class=\"ind\" indent=\"" "\"" 0)
           (= rec!indent (or (errsafe:int (car it)) 0))
           (= rec!indent 0))
      ; parent: most recent comment at indent-1, else story
      (= rec!parent (or (indent-stack (- rec!indent 1)) story-id))
      ; comhead -- look for inline flags, user, age, descendants.
      ; The comhead contains nested <span> children (.age, .navs, ...)
      ; so use the outer "</span></div>" landmark, not the first </span>.
      (let comhead (or (car (between row "<span class=\"comhead\">" "</span></div>" 0)) "")
        (aif (between comhead "<a href=\"user?id=" "\"" 0)
             (= rec!by (car it)))
        (aif (between comhead "<span class=\"age\" title=\"" "\"" 0)
             (let toks (tokens (car it))
               (when toks (= rec!time (errsafe:int (last toks))))))
        (when (posmatch "[flagged]" comhead) (= rec!flagged t))
        (when (posmatch "[dead]"    comhead) (= rec!dead    t))
        (aif (between comhead "class=\"togg clicky\"" "</a>" 0)
             (aif (html-attr (car it) 0 "n")
                  (= rec!descendants (or (errsafe:int it) 0)))))
      ; body text
      (aif (between row "<div class=\"commtext " "</div>" 0)
           (let inner (car it)
             ; strip the "c00\">" prefix
             (aif (posmatch ">" inner)
                  (= rec!text (html-unescape (trim (cut inner (+ it 1)) 'end))))))
      rec)))


; ----- HN Firebase API (users only) -----

(def fetch-user (id)
  ; returns parsed user table, or nil
  (aand (curl-get-public (+ scrape-api-host* "/user/" id ".json"))
        (from-json it)
        (and (isa it 'table) it)))



; ----- Refetch policy & deletion-aware merge -----

(def load-fetchlog ()
  (= scrape-last-fetch*
     (or (and (file-exists scrape-fetchlog*) (errsafe:load-table scrape-fetchlog*))
         (table))))

(def save-fetchlog ()
  (save-table scrape-last-fetch* scrape-fetchlog*))

(def recently-fetched? (id)
  (let t-last (scrape-last-fetch* id)
    (and t-last (< (- (seconds) t-last) scrape-refetch-secs*))))

(def merge-comments (old-comments new-comments)
  ; old-comments and new-comments are lists of tables; key by id.
  ; Comments in old but not in new are kept with deleted=t.
  ; Comments in new override old.  Returns merged list in new order
  ; followed by deleted-only entries (so order on disk roughly tracks
  ; HN render order while preserving history).
  (with (new-ids (table) merged nil)
    (each c new-comments
      (= (new-ids c!id) t)
      (push c merged))
    (each c old-comments
      (unless (new-ids c!id)
        (= c!deleted t)
        (push c merged)))
    (rev merged)))


; ----- Item scrape orchestration -----

(def scrape-item! (id (o force))
  (let result
       (if (and (no force) (recently-fetched? id))
           (do (prn "  skip " id " (fetched recently)")
               (load-json (+ scrape-item-dir* id ".json")))
           (do
             (prn "  item " id)
             (sleep scrape-crawl-delay*)
             (let html (curl-get (+ scrape-hn-host* "/item?id=" id))
               (if (no html)
                   (do (prn "  FAILED to fetch " id) nil)
                   (withs (parsed (parse-item-page html)
                           path   (+ scrape-item-dir* id ".json")
                           old    (and (file-exists path) (load-json path))
                           merged (build-item-json parsed old))
                     (save-json merged path)
                     (= (scrape-last-fetch* id) (seconds))
                     (save-fetchlog)
                     merged)))))
    ; collect users from the result whether freshly scraped or cached
    (when (and result result!story)
      (push-user-to-fetch result!story!by)
      (each c (or result!comments nil)
        (push-user-to-fetch c!by)))
    result))

(def build-item-json (parsed old)
  ; parsed = (obj story story comments comments).
  ; old (or nil) = previous saved record (decoded JSON; tables with symbol keys).
  (with (story    parsed!story
         comments parsed!comments
         old-comments (and old (or old!comments nil)))
    (= story!fetched_at (seconds))
    (let merged (merge-comments old-comments comments)
      (each c merged
        (each u (collect-users-from-comment c)
          (push-user-to-fetch u)))
      (push-user-to-fetch story!by)
      (obj story story comments merged))))

(def collect-users-from-comment (c) (if c!by (list c!by) nil))

; users discovered during scraping; processed at end
(= scrape-users-to-fetch* (table))

(def push-user-to-fetch (u)
  (when u (= (scrape-users-to-fetch* u) t)))


; ----- User scrape -----
;
; We deliberately avoid parsing+reserialising the firebase response.
; from-json on a 100KB user object (long `submitted` array) is ~0.4s
; per call in pure Arc, and parsing concurrently in many threads
; thrashes the allocator/GC.  Instead, save the raw response verbatim
; and inject `fetched_at` with a tiny string surgery on the trailing
; `}`.

(def scrape-user! (id (o force))
  (when (or force (no (recently-fetched? (sym (+ "u/" id)))))
    (let raw (curl-get-public (+ scrape-api-host* "/user/" id ".json"))
      (when (and raw (>= (len raw) 2))
        (writefile-raw (inject-fetched-at raw (seconds))
                       (+ scrape-user-dir* id ".json"))
        (= (scrape-last-fetch* (sym (+ "u/" id))) (seconds))
        t))))

(def writefile-raw (s path)
  (let tmp (+ path ".tmp")
    (w/outfile o tmp (disp s o))
    (mvfile tmp path)))

(def inject-fetched-at (raw t)
  ; raw is a JSON object string (firebase response).  Insert
  ; ,"fetched_at":<t> just before the trailing `}`.  No-op if the
  ; response doesn't look like a JSON object.  We avoid `trim`
  ; because copying a 100KB string per call wrecks throughput when
  ; many threads run this concurrently; instead, scan back from the
  ; end for the closing brace.
  (let n (len raw)
    (with (i (- n 1))
      (while (and (>= i 0) (whitec (raw i))) (-- i))
      (if (and (>= i 1) (is (raw i) #\}))
          (+ (cut raw 0 i)
             (if (is (raw (- i 1)) #\{) "" ",")
             "\"fetched_at\":" (string t) "}")
          raw))))


; ----- Bounded-parallel user scrape -----
;
; Fire N curls in parallel inside a single shell (`curl ... & ... &
; wait`).  Going through Arc threads + SBCL `run-program` per-curl is
; ~15x slower than native shell job control because each `run-program`
; call has measurable per-process overhead; one wrapping shell hides
; all of that.

(def scrape-users-parallel! (users (o force) (o batch-size scrape-user-concurrency*))
  (let pending (if force users
                   (rem [recently-fetched? (sym (+ "u/" _))] users))
    (with (total (len pending) done 0)
      (each batch (tuples pending batch-size)
        (scrape-user-batch! batch)
        (= done (+ done (len batch)))
        (when (is 0 (mod done (max 1 (* batch-size 5))))
          (prn "  users " done "/" total)
          (flushout))))))

(def scrape-user-batch! (ids)
  ; build a single shell command that backgrounds one `curl` per id
  ; and waits for them all.
  (let cmd
       (apply + (intersperse " "
                  (+ (map (fn (id)
                            (+ "curl -fsS --connect-timeout 20 --max-time 60 "
                               (shellquote (+ scrape-api-host* "/user/" id ".json"))
                               " -o "
                               (shellquote (+ scrape-user-dir* id ".json.raw"))
                               " &"))
                          ids)
                     '("wait"))))
    (system cmd)
    (let now (seconds)
      (each id ids
        (let raw-path (+ scrape-user-dir* id ".json.raw")
          (when (file-exists raw-path)
            (let raw (errsafe:filechars raw-path)
              (when (and raw (>= (len raw) 2))
                (writefile-raw (inject-fetched-at raw now)
                               (+ scrape-user-dir* id ".json"))
                (= (scrape-last-fetch* (sym (+ "u/" id))) now)))
            (errsafe:rmfile raw-path)))))))


; ----- Top-level entry -----

(def scrape! ((o force) (o limit 60))
  ; `limit` caps how many ranked stories to fetch.  Default 60 ~= the
  ; first two HN pages.  Use a smaller value for dev/testing.
  (map ensure-dir (list scrape-dir* scrape-item-dir* scrape-user-dir*))
  (load-fetchlog)
  (prn "crawl-delay: " scrape-crawl-delay* "s limit=" limit)
  (ensure-login)
  (let ids (firstn limit (or (fetch-top-stories) nil))
    (prn "topstories: " (len ids) " ids")
    ; record current rank for the importer (and for forensics).
    (let front (let i 0
                 (map (fn (id) (++ i)
                        (obj id id
                             page (if (<= i 30) 1 2)
                             rank (if (<= i 30) i (- i 30))))
                      ids))
      (save-json front (+ scrape-dir* "front.json")))
    (each id ids
      (scrape-item! id force))
    (save-fetchlog)
    (prn "scraping " (len (keys scrape-users-to-fetch*)) " users "
         "(" scrape-user-concurrency* "-way parallel)")
    (scrape-users-parallel! (keys scrape-users-to-fetch*) force)
    (save-fetchlog)
    (prn "done.")))


; ----- Import scraped JSON into News -----
;
; Populates items*/profs* so the local server's front page mirrors HN.
; Items are stored under their HN ids -- this may collide with locally
; created items if any.  Guard with `(news-active?)` and the user's
; explicit call to (import-scrape!).

; Scraper username as a symbol, used as the single flagger on every
; imported `[flagged]` comment.  Set by `import-scrape!` from the
; current scrape.json so the value matches the account that fetched
; the page.  Defaults to 'hnscraper for direct callers of
; `import-scraped-comment`.
(= scrape-flagger* 'hnscraper)

(def import-scrape! ()
  (map ensure-dir (list scrape-dir* scrape-item-dir* scrape-user-dir*
                        arcdir* newsdir* storydir* profdir* votedir*))
  (= scrape-flagger* (sym (or (let cfg (load-scrape-config) cfg!username)
                              "hnscraper")))
  ; news's `(flagged i)` requires `(len> i!flags many-flags*)`.  With
  ; many-flags* = 1 (the default), two flaggers are needed.  Since the
  ; scraper account is our only flagger, drop the threshold to 0 so a
  ; single flag is enough.
  (= many-flags* 0)
  (let ranked nil
    ; users first (so items have authors)
    (each f (dir scrape-user-dir*)
      (aif (load-json (+ scrape-user-dir* f))
           (import-scraped-user it)))
    ; then items, walking front.json (page+rank order from the scrape)
    (let front (or (load-json (+ scrape-dir* "front.json")) nil)
      (each entry front
        (aif (load-json (+ scrape-item-dir* entry!id ".json"))
             (when it!story
               (import-scraped-story it!story)
               (each c (or it!comments nil)
                 (import-scraped-comment c))
               (push it!story ranked)))))
    (let stories (rev ranked)
      (= stories* (map [item _!id] stories)
         ranked-stories* (map [item _!id] stories)))
    ; Persist the ranking so a subsequent (nsv) -> (ensure-topstories)
    ; reads our order from disk instead of calling gen-topstories (which
    ; walks down by 1 from maxid*; with HN ids in the tens of millions
    ; that's catastrophic).
    (save-topstories)
    (prn "imported " (len ranked) " stories")))


; news.arc's gen-topstories walks `(down id maxid* 1)` calling (item
; id) for every integer from maxid* down to 1.  With imported HN ids
; maxid* is ~48M, so a cold (nsv) (no topstories file on disk) freezes
; trying to do 48 million hash lookups + file probes.  Override it
; with an items*-driven version that touches only the ids we have.
(def gen-topstories ()
  (let metas (keep metastory (map item (keys items*)))
    (= ranked-stories*
       (or (sort (compare > (memo frontpage-rank)) metas)
           nil))))

(def import-scraped-story (s)
  (let id s!id
    (let it (or (items* id)
                (= (items* id)
                   (inst 'item
                         'id id
                         'type (sym (or s!type "story"))
                         'by   s!by
                         'time (or s!time (seconds))
                         'url  s!url
                         'title s!title
                         'text  s!text
                         'score (or s!score 0)
                         'dead  s!dead
                         'deleted s!deleted)))
      (when (> id maxid*) (= maxid* id))
      (= it!score (or s!score it!score))
      (= it!title (or s!title it!title))
      (= it!url   (or s!url   it!url))
      (= it!by    (or s!by    it!by))
      ; record the story under the author's submitted list (used by
      ; /submitted and /threads).
      (when s!by
        (whenlet author (profs* s!by)
          (unless (mem id author!submitted)
            (= author!submitted (cons id author!submitted))
            (save-prof s!by))))
      (save-item it)
      it)))

; news's (flagged i) requires (len> i!flags many-flags*).  We're the
; only flagger we know about, so we record the scraper username
; (many-flags* + 1) times -- enough to clear the threshold regardless
; of what many-flags* happens to be set to.
(def scrape-flag-list ()
  (n-of (+ (or many-flags* 1) 1) scrape-flagger*))

(def import-scraped-comment (c)
  (let id c!id
    (let it (or (items* id)
                (= (items* id)
                   (inst 'item
                         'id id
                         'type 'comment
                         'by c!by
                         'time (or c!time (seconds))
                         'text c!text
                         'parent c!parent
                         ; HN comments start with 1 point (author's auto-upvote).
                         ; We don't observe the live score from HTML, so 1 is the
                         ; right baseline.
                         'score 1
                         'dead  c!dead
                         'flags (if c!flagged (scrape-flag-list) nil)
                         'deleted c!deleted)))
      (when (> id maxid*) (= maxid* id))
      (= it!text (or c!text it!text))
      (= it!by   (or c!by   it!by))
      (= it!dead (or c!dead it!dead))
      ; if newly observed as [flagged] and the scraper isn't already
      ; on the flag list, install the (many-flags* + 1)-long marker.
      (when (and c!flagged (no (mem scrape-flagger* it!flags)))
        (= it!flags (scrape-flag-list)))
      ; link this comment under its parent's kids list.  Without this
      ; an item page renders the story but no comments -- news.arc's
      ; display-subcomments walks parent!kids, not (keep [is _!parent
      ; parent-id] all-items).
      (whenlet p (and c!parent (items* c!parent))
        (unless (mem id p!kids)
          (= p!kids (+ p!kids (list id)))
          (save-item p)))
      ; record this comment under the author's submitted list so
      ; news's (comments user) -- which walks (uvar user submitted) --
      ; picks it up for /threads?id=USER.
      (when c!by
        (whenlet author (profs* c!by)
          (unless (mem id author!submitted)
            (= author!submitted (cons id author!submitted))
            (save-prof c!by))))
      (save-item it)
      it)))

(def import-scraped-user (u)
  ; Note: we deliberately do NOT copy u!submitted (the firebase
  ; user's recent-submissions list) into the profile.  Firebase
  ; returns up to ~10000 ids, the vast majority of which we never
  ; scraped, so (item id) -> nil for them.  News's `comments` then
  ; calls (acomment nil) which is (nil 'type) -> error.  We build
  ; submitted from below instead, in import-scraped-{story,comment},
  ; restricting it to items we actually have.
  (let id (string u!id)
    (when (goodname id)
      (let p (or (profs* id)
                 (= (profs* id)
                    (inst 'profile
                          'id id
                          'created (or u!created (seconds))
                          'karma   (or u!karma 1)
                          'about   u!about)))
        (when u!karma (= p!karma u!karma))
        (when u!about (= p!about u!about))
        (save-prof id)
        p))))
