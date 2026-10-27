# Releases

What each release of Preflight changes for the person running it, newest
first. Read the entry for the version you are moving to before you update.
`CHANGES.md` is the engineering log; this file is the operator's.

Every entry says whether **the database changes**, and names the **schema
revision** the release ships. `api/VERSION` is the release; the revision is
what your database records. If the API refuses to start with *"the database is
at schema revision X, which is newer than this build"*, find the entry below
that names X and check out that release or a later one — or restore the backup
you took before updating.

`ui/package.json` also carries a `version`. It is not the version of anything
(Vite wants the field) and stays at 0.1.0.

### Cutting a release

1. Put the new version in `api/VERSION` (`X.Y.Z`, no `v`).
2. Rename the `## Unreleased` section at the top of this file to
   `## X.Y.Z — YYYY-MM-DD`. (Work lands under `## Unreleased` as it happens,
   so this is usually a rename and a read-through, not writing from scratch.
   Its `**Database:**` line must say `unchanged` or `changes`, the latter
   naming the head revision — `ls api/app/migrations/versions/` — and telling
   people to back up first.) A released entry is never edited afterwards: it
   describes a tag people can check out, and revising it makes it a lie.
3. `python scripts/release_check.py`. It fails if any of the three disagree.
   The unit job runs it on every PR too.
4. In `.github/workflows/ci.yml`, set `PREVIOUS_SCHEMA_REF` to the tag of the
   release people are updating *from* (the one before this). CI then proves
   this release adopts that release's database.
5. Commit, open the PR, merge it.
6. Tag the merge commit on `main`, one of two ways:
   - **The button.** GitHub → Actions → *cut release* → Run workflow. It
     re-runs the check against the tag name, refuses if the tag exists, and
     pushes `vX.Y.Z`. Use this when you cannot push a tag from where you are.
   - **By hand.** `git tag -a vX.Y.Z -m "Preflight X.Y.Z"` then
     `git push origin vX.Y.Z`. `.github/workflows/release-guard.yml` re-runs
     the check against the pushed tag.
   (GitHub does not start workflows for a push made by another workflow, so
   the guard does not run on a button-made tag — the button's own check is
   what stands in for it.)
   Either way, `publish-image.yml` then builds and pushes
   `ghcr.io/sleepvista/preflight-api:X.Y.Z` (beta edition, amd64 and arm64)
   and attaches the install folder, with a compose file pinned by digest, to
   the run as an artifact. It refuses while `beta.TRUSTED` is empty and
   refuses to overwrite a version already published. Then copy that artifact
   to sleepvista/preflight-install (the session cutting the release does it),
   **only after checking where it came from** (docs/SPEC-beta-delivery.md
   §2.2): the run is `publish-image.yml` itself or `cut-release.yml` calling
   it, its event is the tag push or the button, its commit is the tag's
   commit, and that commit is on `main`. Once the package is public, also
   check that `docker buildx imagetools inspect
   ghcr.io/sleepvista/preflight-api:X.Y.Z` reports the digest the compose
   file pins. An artifact from any other run — a branch, a pull request, a
   re-run on another commit — is not copied, whatever it is named.
7. A tag that turns out wrong within minutes: `git tag -d vX.Y.Z`,
   `git push origin :refs/tags/vX.Y.Z`, fix, tag again — unless its image was
   already published, in which case the publish refuses the same version and
   the fix ships as `X.Y.Z+1`. A tag anyone may have
   fetched already stays in their clone whatever you do — ship `X.Y.Z+1`
   instead.

## 0.3.2 — 2026-10-26

**The report button's health summary now sends what it promises.** Its
checkbox says "the status words /health shows anyone — no addresses or
messages". It sent each background job's last result line as well, and one
of those lines can hold an error message naming an internal address. Now
the summary, and `/health` for anyone without the operator token, keep each
job's name, timings, failure count and error type, and leave the sentence
out. Signed in, you still see the full line. Found by the first end-to-end
test of the beta with a real key; that test report held no address.

**Updating from 0.3.1 or earlier: one step by hand, once.** Preflight's
database had a default password that is printed in Preflight's source, and on
a Linux machine anyone with an account on it could reach the database with
it — read your recordings, change stored workflow versions, edit the audit
log. Now `POSTGRES_PASSWORD` is required, and `docker compose up -d` stops
with *"required variable POSTGRES_PASSWORD is missing a value"* until you set
it. Your database keeps the old password until you change it there too, so
follow INSTALL.md, "Changing the database password": a new value in `.env`,
start the database alone, `\password preflight`, then `up` as usual. Nothing
is deleted at any step; if you skip the `\password` step Preflight cannot
sign in to the database and says so in `docker compose logs api`, and doing
it then fixes that. The API also refuses to start on the old published
value, so putting it in `.env` is not a way round this.

**The database is also on a network of its own**, shared only with
Preflight's API, that your machine has no address on (Docker Engine 28 or
later). `up` creates it; nothing to do.

**Security fixes from a review before the first testers.** Several checks
that mask passwords, spot private keys and group recordings took time that
grew with the square of their input, so a large enough webhook body could
stall Preflight; each is now one pass, with identical results. A capture
token revoked while a report was uploading can no longer deliver it. Error
text from your n8n now reaches an AI assistant marked as untrusted, like the
rest. A `password=…` at the very start of a form-encoded string is now
masked in stored recordings, and recordings or replays made before a clean-up
pass reached them no longer keep raw values. **After updating, Preflight
re-masks every stored recording once in the background**. It is finished
when the `secret_scrub` job's last result, on `/health` while you are signed
in, reads `left: 0 fixture(s), 0 replay(s), 0 adversarial run(s)`. Every
recording stays replayable while it runs.

**Database:** unchanged; head revision stays `0013_deploy_integrity`. Its
password changes, by the step above; its contents do not.

## 0.3.1 — 2026-10-25

**Install this one, not 0.3.0.** It is the same Preflight as 0.3.0 — read
0.3.0's notes below for what changed since 0.2.0. The 0.3.0 image was pushed,
but the check that starts it on both kinds of processor was itself broken: it
started the Intel/AMD image, then failed to fetch the ARM one. So 0.3.0 never
went into the install folder. The fix is in that check only; nothing in
Preflight itself changed. Building 0.3.0 from source is unaffected.

**Database:** unchanged; head revision stays `0013_deploy_integrity`.

## 0.3.0 — 2026-10-25

**Updating from 0.2.0:** back up as usual, then pull and `up`; the
database does not change. Nothing changes for a source build except the
report button and the corrected Windows backup commands below.

**Background jobs no longer pause for ten minutes after every restart.**
When Preflight stopped cleanly — an update, `docker compose down` then `up` —
the process that started next ran no background job (deploy watching,
heartbeats, the secret scrub) for up to ten minutes, and `/health` said
`standby` meanwhile. From 0.3.0 a clean stop hands over at once. **This one
update from 0.2.0 still waits** up to ten minutes, because it is 0.2.0 doing
the stopping; after that it is immediate.

**The free beta: a published image, a beta key, and a report button.**
From this release Preflight is also published as a ready-built image,
`ghcr.io/sleepvista/preflight-api`, with an install folder at
github.com/sleepvista/preflight-install. That image is the *beta edition*: it
needs a beta key from your invitation (paste it in the bar at the top of the
page, or set `PREFLIGHT_BETA_KEY` in `.env`). Each key lasts 90 days. The key
is checked on your machine; Preflight does not call anywhere to check it.
Without a current key Preflight is **read-only**: history, polling and the
report button keep working; new replays, recordings and deploys stop until a
key is entered. Rollback keeps working and still writes to n8n, restoring
only a version that was live there before. **Building from this
repository, as INSTALL.md describes, is unchanged**: a source build reports
the key and enforces nothing.

**A "Report a bug or request a feature" button** sits at the top of every
page. You choose what goes with your message, see the report byte for byte,
and only then press Send. It goes to preflightgate.com; nothing is sent
otherwise. Passwords, keys and tokens in what you type are removed first.

**Backups on Windows work now.** The backup command in INSTALL.md used a
`> file` redirect, which Windows PowerShell saves as UTF-16 that PostgreSQL
cannot read back, and the restore used `<`, which PowerShell does not have.
Both now run inside the database container and copy the file with
`docker compose cp`, the same on every system. If you made a backup on
Windows with the old command, make a new one.

**Database:** unchanged; head revision stays `0013_deploy_integrity`.

## 0.2.0 — 2026-10-24

**Updating from 0.1.0, in short:** back up first (the database changes, see
**Database** below); stop the stack with `down` before `up` this once; and
expect the page to ask for an operator token the first time you open it,
because 0.1.0 had no authentication at all. Everything below says why.

**Two `.env` settings now actually work.** On the self-host stack,
`PREFLIGHT_AUTO_MIGRATE=false` and `PREFLIGHT_RUNNER=false` were never handed
to Preflight, so setting them did nothing: migrations still ran on boot and
the background loop still ran. If you set either, it takes effect from this
release — check that is still what you want before you update. The commands
in INSTALL's collector section now include the operator token they need
(they answered 401 before), and INSTALL says plainly that the collector
cannot yet reach Preflight from an n8n running in Docker.

**The API runs as an ordinary user, and the demo n8n no longer uses
Preflight's database account.** Existing installs are converted on the first
boot. Two commands change: **reading a file from the API container now needs
`-u app`**, e.g. `docker compose -f docker-compose.selfhost.yml exec -u app api
cat /preflight-state/api-token` (without it you get "Permission denied").
Also new and optional: a narrower token for the MCP server
(`PREFLIGHT_AGENT_TOKEN`: it can read and set up, never deploy), and a way to
change `PREFLIGHT_SECRET` without losing anything (INSTALL.md, "Changing
PREFLIGHT_SECRET"). Credentials no longer reach the logs, the UI refuses to be
framed by another site, and `/health` tells anonymous callers only whether
things are working, not why.

**Deploys look before they push, and every decision is recorded.** A deploy
now reads your workflow from n8n first. If someone edited it in the n8n
editor since Preflight last looked, that edit is saved as a version (so
rollback can bring it back). Under the `block` policy the deploy is refused
once, with a message naming that version; deploy again to confirm. A deploy
that timed out after it landed is recorded as landed, and one Preflight cannot
be sure about says **unknown — check the workflow in n8n**. Refused deploys,
gate-policy changes, accepted diffs, declared versions and noise-rule changes
are now in the audit trail (`/api/audit` and the workflow page), and `actor`
must be 1–200 plain characters.

**Preflight checks where it connects on every connection.** Until this
release the address of your n8n was checked once, when you registered it; a
DNS name that changed its answer afterwards could point Preflight anywhere.
Now every connection is checked, cloud metadata addresses are always refused,
and three more limits apply to each call to your n8n: two minutes, 100 MB
(`INSTANCE_RESPONSE_MAX_BYTES`), and no compressed replies. **Two things may
need you:** an instance registered as plain `http://` on the **public
internet** now stops working with a message naming
`ALLOW_INSECURE_INSTANCE_URLS` — register it again as `https://` (or set that
to `true`); and Preflight **never uses a proxy** to reach your n8n, so if your
network needs one, n8n must be reachable directly. A registered URL with a
`?`, `#` or `user:password@` in it now fails with a message saying to register
it again. Hosted anywhere shared (Railway)? Set
`ALLOW_PRIVATE_INSTANCE_URLS=false` — INSTALL.md §5.

**The replay sandbox has its own owner now, and is walled off from your
machine.** Until this release every Preflight sandbox had the same owner
password, written in the source code, and a workflow being replayed could use
it to take the sandbox over. Each install now generates its own the first
time it starts. **An existing sandbox is migrated automatically:** Preflight
logs in once with the old password, changes it, and deletes everything in the
sandbox that the old password could have let in (extra users, API keys,
credentials, workflows). The sandbox holds nothing you need; replays clean up
after themselves.

**For this update, stop the stack with `down` before `up`**, so the sandbox
network is recreated with the new setting that keeps your machine off it
(Docker Engine 28 or later). `/health` reports `sandbox_isolation`:
`isolated` is what you want. If you run n8n directly on this machine and
followed the old advice to listen on `0.0.0.0`, see INSTALL.md §5.

Also: replays have a time and memory limit, at most two run at once (a third
gets "sandbox busy, try again"), and a workflow using **Execute Command** is
replayed with that node skipped, like an email node, instead of running a
shell command in the sandbox.

**Secrets are taken out of recordings.** Before this release, a recording
kept whatever credentials were in the execution data: a webhook's
`Authorization` header, OAuth tokens, database passwords, private keys. Each
one is now replaced by a fingerprint like `⟦SECRET:kbhdmoaflcpe⟧` before
anything is stored. The same value always gets the same fingerprint, so a
diff still notices when it changes, but the value itself is gone and cannot
be recovered. **Recordings you already have are cleaned in the background**
by a job that runs every five minutes, a few at a time; its progress is on
the runner's status. One behaviour change to know about: a workflow that
*checks* an incoming secret (an IF node comparing an API-key header to a
fixed value, say) will now show a difference on replay, because the replay
sees the fingerprint and not the secret. See docs/SPEC-secret-scrub.md §3.

**Preflight now requires a token.** The API had no authentication at all, and
anything that could reach its port could push workflow JSON to a client's
production n8n. Every route needs `Authorization: Bearer <token>` now, except
the health check, the replay stub endpoints and the collector's report
endpoint (which has its own per-instance credential).

You do not have to create one. If `PREFLIGHT_API_TOKEN` is not set, Preflight
generates a token the first time it starts and writes it into its state volume;
the startup log says which file. Read it with `docker compose exec -u app api cat
/seed-state/api-token` (demo) or `/preflight-state/api-token` (self-host), and
paste it into the page the UI shows you. **On a host with no persistent volume
— Railway, for instance — set `PREFLIGHT_API_TOKEN` yourself, or the token
changes on every deploy.**

Two smaller consequences: `/docs` and `/openapi.json` are no longer served
anonymously, and `curl` examples in the README and INSTALL now carry the
header.

**Database:** changes. Adds three tables for the background runner —
`runner_lease`, `runner_schedule` and `runner_coverage`; one,
`telemetry_records`, for what each upgrade check observed; and three for the
capture credential — `capture_report`, `capture_report_workflow` and
`credential_audit` — plus four columns on `instances`; and two columns on
`fixtures` (`origin`, `derived_from`) for designed inputs; and one table,
`adversarial_runs`, for retry checks; one table, `deploy_watch`, and three
cadence columns on `workflows`, for watched deploys; and one index,
`ix_capture_report_instance_window`, for the readers of the capture reports;
and two columns on `workflows` (`absent_since`, `last_absence_at`) for
workflows that are no longer on the instance; and two columns on
`capture_report_workflow` (`by_status`, `by_mode`) for what the collector saw,
**nullable with no default**, because an empty breakdown would read as "no
errors" on every row an older collector wrote; and one column on `instances`
(`collector_version`) so a stale collector is a stated fact rather than
something inferred from missing data; and three columns on `fixtures`,
`replays` and `adversarial_runs` for the secret pass (`secret_scrub`,
`secret_scrub_version`), **nullable with no default**, because NULL is the
honest state of a row the pass has not reached yet; and, for deploy
integrity, two columns on `workflows` (`observed_n8n_version_id`,
`observed_hash`: what Preflight last saw live, NULL until it next looks), one
on `deploy_audit` (`result_detail`) and a new table `operator_audit` for
decisions and refused deploys.
Schema revision `0013_deploy_integrity`. Every fixture that exists is
marked `recorded` on the way through, and **the watch outcome `ran_as_before`
is rewritten to `kept_firing`** — "as before" claimed a comparison the watch
has no baseline to make. Nothing else is rewritten, but **back up first** all
the same ([Updating](docs/INSTALL.md#updating-in-this-order)).

- **The collector works.** It had never been run against a real n8n, and it
  could not have worked: it asked itself for `http://localhost:5678`, which
  resolves to IPv6 first on most hosts while n8n listens on IPv4, and both its
  HTTP nodes carried a credential without telling n8n to send it. If you
  installed it before this release, re-import
  `collector/preflight-collector.json` and re-attach the two credentials.
- **Reported windows are now kept for 210 days and then deleted.** There was
  no retention at all before, and the table grows by six rows an hour per
  instance. The horizon is the cadence baseline window plus the longest a
  late report may legitimately arrive, so nothing an alert could use is
  removed.
- **A report that cannot be true is refused rather than repaired.** A window
  ending in the future used to be accepted — and because "last heard from"
  only moves forward, one of those made an instance look dead for a day while
  it was alive. Negative, fractional and boolean execution counts used to be
  rounded into a number Preflight then treated as observed.

- **Every deploy is now watched.** After the gate approves and the push
  succeeds, Preflight watches the next 10 executions the client's collector
  reports (or 24 hours, whichever first) and closes the window as *kept
  firing*, *stalled* (nothing ran where the workflow's usual cadence
  predicted several — the trigger may have stopped) or *inconclusive*. The
  counts come from the optional collector, so without it a window has nothing
  to watch; and the collector cannot yet reach Preflight from an n8n running
  in Docker (INSTALL, "Import the collector"). It is
  not a canary: n8n cannot split traffic, every execution in the window is
  real, and rollback cannot undo what they sent. It also does not check what
  those executions did — no execution data reaches Preflight yet — so the
  outcome is never "clear". Each window names the exact version it should
  roll back to, so a later deploy cannot move the target. The workflow page
  shows each workflow's observed cadence (runs per day over the hours the
  collector reported) so you can judge what "10 executions" means for it.
  Both numbers can be set per deploy.
- **You can replay a fixture twice and see whether a retry would get
  through.** A "Retry checks" section on the workflow page runs the current
  version twice against the latest recording in one sandbox pass and counts
  how many times each email, Slack or similar node was reached. `unguarded`
  means nothing in the workflow stopped the second run reaching it with the
  same input. It cannot tell you whether the service on the other end would
  have de-duplicated — every run is answered from the recording — and the
  report says so every time.
- **You can plant a trap on a recording.** Pick a fixture, paste a
  trigger payload with the case you are worried about (a duplicate line, an
  unknown item code, a row with no matching price), give it a label, and
  replay it. The nodes that run before the workflow's first external call
  run for real on your input; the external calls and everything after them
  are answered from the original recording and are marked as such, never
  passed. A designed fixture is never a baseline, never counts as coverage,
  and never opens or blocks a deploy. Its report says "the workflow did X on
  this input", not "the workflow changed".
- **Recordings keep every output branch now.** A fixture promoted from
  this release on records what an IF, Switch or Loop sent down *every*
  output, plus n8n's item lineage and the node settings that change how many
  items come out. Older fixtures cannot be upgraded — n8n has pruned the
  executions they came from — so they are marked `v2 cassette` and any check
  that needs the new data says so instead of guessing. Two bugs fixed on the
  way: a node fed by a router's second branch was recorded with the first
  branch's items as its input, and a node that ran several times with one
  empty run counted as fully captured. **Expect some fixtures to show more
  untestable nodes after a re-promote** — that is the second fix being honest.
- **The upgrade check now remembers what it found.** It used to compute an
  answer, print it, and forget — so checking one client's instance taught you
  nothing when you checked the next. Each check now stores, per node, what it
  observed, and nothing leaves your machine: the rows are structure only (node
  types and graph shape, never names, URLs, parameters or payloads) and there
  is no uploader in this build.
- **Optional: tell Preflight when your automations actually run.** A small
  workflow you install on your own n8n counts how many times each workflow ran
  in the last ten minutes and posts the counts back — counts only, no execution
  data, no payloads, no credentials. You can open it and read exactly what it
  sends, and switch it off whenever you like. It exists so Preflight can tell
  "this automation has not run since Tuesday" apart from "Preflight was not
  watching", which are different facts. Off until you turn it on;
  [the steps are in INSTALL](docs/INSTALL.md#telling-preflight-when-your-automations-run),
  Windows commands included.
- **Preflight now issues a credential, and cannot show it twice.** The token
  for that workflow is shown once when you create it and stored only as a
  one-way hash — so a copy of the database yields no usable token. Lose it and
  you issue a new one, which stops the old one working immediately. This is
  deliberately different from the n8n API key you register, which Preflight has
  to be able to replay to n8n and therefore stores encrypted rather than
  hashed.
- **Upgrade checks will now say "could not be tested" far more often, and
  that is a correction, not a regression.** Until this release, a workflow
  whose HTTP nodes were answered from their own recording came back as
  "reproduces its fixture on n8n X". Those nodes parsed nothing — replay hands
  them the answer — so the check had no way to know whether the new n8n version
  still reads those APIs the same way, which is exactly what an upgrade
  changes. It now reports them as untestable and names the reason. Workflows
  built from internal logic (Set, Code, IF) still report safe. **If a check
  that used to come back clean now comes back "not a clean bill of health",
  nothing about your workflow changed — Preflight stopped overstating what it
  had checked.**
- **A new view: what your other instances saw.** `GET
  /api/fleet/compatibility` shows, per node type and node version, how many of
  your workflows broke on a given n8n transition — and each upgrade check now
  carries a `fleet` block saying the same thing for the workflows it just
  checked. It is deliberately hard to overstate: the instance being checked is
  excluded from its own history, no failure rate is shown until at least three
  *distinct* workflows have been observed, and a single other workflow
  breaking is listed but never raises the risk level on its own.
- **It can tell four copies of one template from four independent findings.**
  Most agencies run the same automation for several clients with different
  URLs and credentials. Those share a fingerprint of their *shape*, so the
  report says "4 instances, 1 distinct workflow" and counts it as one
  observation. Counting them as four would have been the most flattering and
  least true number this feature could produce.
- **The check finally tells you which version it compared against.** It always
  replayed against "the version you run today" and never said what that was,
  so "safe" could mean safe from 1.60 or safe from something Preflight could
  not identify. Those are different claims. If your n8n does not report its
  version (2.35 and later do not tell API-key clients) and you have not
  declared one on the instance page, the check now says so instead of implying
  a comparison it could not name — and records nothing, rather than filing a
  transition nobody measured.
- **It counts the nodes it could not test.** A node answered from its own
  recording, or switched off during the replay because it sends email, was
  never actually compared. Those now appear as `not_observed` with the reason,
  beside the nodes that were. Previously they were either dropped — making
  every count a count of the testable ones, presented as a count of all of
  them — or, worse, reported as passing.
- **Preflight now does things on a schedule.** Until this, nothing ran unless
  you clicked it. It runs seven jobs: a heartbeat, the observed cadence per
  workflow, closing deploy watch windows, pruning old collector reports,
  refreshing the sandbox's list of node types, and the background secret
  scrub and key rotation. Right after a restart it reads `standby` for up to
  ten minutes before taking over.
- **It records what it actually watched**, not just what it found. That is
  what will let a future "this workflow has not run since Tuesday" alert tell
  the difference between your automation being stopped and Preflight not
  having been running — the second is not a fact about your system, and
  Preflight will not report it as one.
- `PREFLIGHT_RUNNER=false` turns it off. `/health` gains a `runner` block
  saying what it is doing; a background job falling behind does **not** make
  the API report unhealthy.
- **Fixed: `PREFLIGHT_AUTO_MIGRATE` did nothing in 0.1.0.** If you set it to
  `false` to keep Preflight from migrating your database on start, it migrated
  anyway — the code was reading a different variable name than the one this
  file and the install guide told you to set, and on the self-host stack the
  variable was never handed to Preflight at all (first paragraph above). Both
  are fixed; it now works as documented.
- **Fixed: accepting a replay as the new baseline lost that behaviour's place
  in the corpus.** Coverage of a workflow path could silently drop after using
  the accept button, on a day nothing had actually gone wrong.

## 0.1.0 — 2026-09-13

The first release, and the first version that can be installed twice: it
introduces the mechanism that carries a database from one release to the next.

**Database:** changes. Preflight now manages its schema with Alembic. On
first start this release adopts whatever database it finds — one created by
any earlier commit, or an empty one — and records schema revision
`0001_baseline`. Nothing is rewritten: it creates tables and columns that are
missing and relaxes four columns that some databases had stricter than
others. **Back up first** all the same (step 1 of
[Updating](docs/INSTALL.md#updating-in-this-order)); there are no downgrades,
and the backup is the way back.

What it means for you:

- **Updating is now a procedure with a safety net.** Back up, read the entry
  here, check out the release, `up -d --build`. Migrations run on boot;
  `docker compose logs api` shows what ran. `/health` reports the schema
  state, and the API refuses to run older code against a newer database
  rather than guessing.
- **Self-hosting from a clean clone**, on your own n8n version:
  `docker-compose.selfhost.yml`, with `PREFLIGHT_SECRET` and
  `PREFLIGHT_N8N_VERSION` required. The API listens on `127.0.0.1` only;
  there is no login yet.
- **A replay never hides which n8n it ran on.** The sandbox is pinned to the
  version you declare; a mismatch between your instance and the sandbox
  refuses rather than reporting a verdict about an engine you do not run.
  Every replay report says which versions were involved.
- **`docs/INSTALL.md`** is the install guide, Windows-first.

Known limits, said plainly: no login (keep it on localhost); no downgrades;
one operator; replay proves your workflow's logic, not that a node still
understands a changed third-party API. Full list in INSTALL under
"What this does not do yet".
