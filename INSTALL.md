# Install the Preflight beta

Preflight runs on your machine, next to the n8n you already run. It records
real executions, replays an edited workflow against them with every outside
call answered from the recording, and shows you which node's output changed
before you deploy. Your workflows, recordings and credentials stay on your
machine; the only thing that ever leaves it is a report you choose to send
with the **Report a bug or request a feature** button, after seeing exactly
what it contains.

Every command below works in **Windows PowerShell** and in a macOS or Linux
terminal, unless it says otherwise. Run them from this folder.

## The quick way on Windows

If you are on Windows 10 or 11, the installer does steps 1 to 4 below for you
and checks that your computer is ready first. Everything it does is described
step by step in this guide, so you can read what it will do, or do it by hand.

1. Download this folder: on GitHub choose **Code → Download ZIP**.
2. **Before you extract it**, right-click the ZIP file, choose **Properties**,
   tick **Unblock** at the bottom, and press **OK**. (Windows marks downloaded
   files as untrusted and shows warnings for scripts. Unblocking the ZIP first
   means the files inside are not marked. Unblocking after extracting does not
   work for files already written.) If you have git you can instead run
   `git clone https://github.com/sleepvista/preflight-install.git`, which
   carries no mark.
3. Extract the ZIP, open the folder, and double-click **install.cmd**. Do not
   run it as administrator.
4. Follow the questions. It will:
   - check your Windows version, free disk space, and that Docker Desktop is
     installed, running, and in Linux-container mode (if Docker Desktop is
     missing it offers to install it, and tells you to restart and run it
     again);
   - ask for your n8n version, your time zone and your beta key, and write
     `.env` with two long random secrets;
   - download and start Preflight, wait until it says it is ready, put your
     operator token on the clipboard and open the page.
5. Paste the token into the page, then go to step 5 below to register your n8n.

You can run **install.cmd** again at any time. To update to a new release,
download the new folder, copy your `.env` into it, and run **install.cmd**: it
asks first, then backs up your data into a `backups` folder before it changes
anything. It never deletes your data and never replaces a secret that is in
use. If it finds data from an earlier install but no `.env`, it stops and tells
you, because new secrets would lock you out of that data.

**If Windows warns you.** The installer is an ordinary text script, not a signed
program, so Windows or your antivirus may say it is from an unknown publisher.
That is expected for a beta. Open **install.cmd** and **install.ps1** in
Notepad if you want to read them first. `install.cmd` starts PowerShell with
`-ExecutionPolicy Bypass`, which applies to that one run only and changes no
setting on your computer. It does not remove Windows warnings; the Unblock step
above is what prevents them. If something goes wrong, `install-log.txt` in this
folder records what the installer did (it never contains your secrets).

The numbered steps below are the same thing by hand, and they stay the
reference.

## What you need

- **Docker Desktop**, installed and running, with Docker Engine 28 or later
  (Docker Desktop 4.38+). Preflight runs entirely inside Docker, so nothing
  below works without it. Download it from
  <https://www.docker.com/products/docker-desktop/>, install it, and open it
  once so it finishes starting (on Windows it may ask you to restart). To
  check, run this in PowerShell or a terminal; it should print a version
  number of 28 or higher and no error:

  ```
  docker version --format "{{.Server.Version}}"
  ```

  If it says it cannot connect to the Docker daemon, Docker Desktop is not
  running yet.
- **Your n8n's exact version** — `2.44.6`, not `2.44`. In n8n it is under
  **Help → About**.
- **An n8n API key** for the instance: in n8n, **Settings → n8n API → Create
  an API key**. Copy it when n8n shows it; it is shown once.
- **Your beta key**, from your invitation email. It starts `pfb1.`.

## 1. Get this folder

Either download it (on GitHub: **Code → Download ZIP**, then unzip it), or:

```
git clone https://github.com/sleepvista/preflight-install.git
cd preflight-install
```

## 2. Write your `.env`

Copy the example and open it:

```powershell
# Windows (PowerShell)
Copy-Item .env.example .env
notepad .env
```

```bash
# macOS / Linux
cp .env.example .env
nano .env
```

Fill in:

- **`PREFLIGHT_SECRET`** — a long random string that encrypts the n8n API keys
  you register. Make one with this command and paste its output:

  ```
  docker run --rm python:3.12-slim python -c "import secrets; print(secrets.token_urlsafe(32))"
  ```

  Set it once, before registering anything. Changing it later makes the keys
  already stored unreadable.
- **`POSTGRES_PASSWORD`** — the password of Preflight's own database, which
  holds your recordings, workflow versions and audit log. Run the same
  command again and paste its output; use a different value from
  `PREFLIGHT_SECRET`. The database takes it when it is first created and
  keeps it, so set it before the first start (to change it later, see
  [Changing the database password](#changing-the-database-password)). Use
  the command's output: a password you make up yourself must not contain
  `@` or `%`, which Preflight cannot pass to its database, and it says so
  and stops if one does. Nor a space: in `.env` a space followed by `#`
  starts a comment, so the rest of the password is silently dropped.
- **`PREFLIGHT_N8N_VERSION`** — your n8n's exact version. Preflight replays on
  its own copy of n8n at this version, and refuses to replay if your instance
  runs a different one, because a green result on another version is not
  evidence about yours.
- **`PREFLIGHT_TIMEZONE`** — the timezone your n8n uses, e.g.
  `America/Edmonton`. If they differ, anything that formats a date looks
  changed on replay.
- **`PREFLIGHT_BETA_KEY`** — your beta key. Optional here: you can paste it
  into Preflight's page instead (step 4).

## 3. Start it

```
docker compose up -d
```

The first start downloads Preflight, PostgreSQL and n8n, so give it a few
minutes. Then open **http://localhost:8000**.

## 4. Sign in, and enter your beta key

The page asks for an **operator token**. Preflight made one when it first
started; print it with:

```
docker compose exec -u app api cat /preflight-state/api-token
```

Paste it into the page. It is remembered in that browser.

If you did not put your beta key in `.env`, the bar at the top says
**Read-only — enter your beta key**. Click it and paste the key. The bar then
shows how many days your beta has left.

## 5. Register your n8n

On the instances page fill in a name, the base URL, your n8n version and the
API key. Preflight runs inside Docker, so `localhost` there means Preflight's
own container, not your computer:

| Your n8n runs… | Base URL |
|---|---|
| Directly on this computer | `http://host.docker.internal:5678` |
| In Docker on this computer, publishing a port | `http://host.docker.internal:5678` |
| On another server | `https://n8n.yourdomain.com` |

On **Linux**, `host.docker.internal` is the Docker bridge address (usually
`172.17.0.1`), so an n8n listening only on `127.0.0.1` cannot be reached:
publish it on `172.17.0.1:5678:5678` instead. **Never on `0.0.0.0`**: a
workflow being replayed could then reach your real n8n.

Registration checks the URL and the key straight away, so a mistake shows now
rather than later. Then press **Poll now** to pull your workflows.

## 6. Your first check

1. Let a workflow run for real a few times in n8n.
2. Open it in Preflight and, under **Promote a recent run**, pick one. The
   recording shows a completeness score: n8n does not always save everything,
   and Preflight says what it actually captured.
3. Edit the workflow in n8n, then press **Poll now** in Preflight.
4. On the new version, press **Replay vs fixture**. It runs on Preflight's own
   n8n with outside calls answered from the recording — nothing is called for
   real and no credentials are used.
5. Read the result. Green means every recorded node produced what it did
   before. Red names the first node that changed.

## Reporting a problem

The **Report a bug or request a feature** button is at the top of every page.
You choose what goes with your message — versions, the page you were on, a
health summary, the error on the page, your email — and **Show exactly what
will be sent** shows the report byte for byte before anything leaves. Passwords,
keys and tokens in your text are removed first; names you type are not, so
read the preview. It goes to preflightgate.com with your beta key, so Logan
knows who sent it. If it cannot be sent, Preflight gives you the text to copy
and email instead.

## When your beta ends

Each beta key lasts 90 days. When it ends Preflight goes **read-only**: your
history, polling and the report button keep working; new replays, recordings
and deploys stop until you enter a new key. **Rollback keeps working too, and
it is the one thing that still changes your n8n**: it puts back a version that
was live there before, never one that was not. Ask for a renewal with the
report button.

## Stopping, and updating

```
docker compose down
```

stops Preflight and keeps your data.

To update, **back up first** — Preflight does not undo database changes, so
the backup is the way back:

```
docker compose exec -T postgres pg_dump -U preflight -f /tmp/preflight-backup.sql preflight
docker compose cp postgres:/tmp/preflight-backup.sql ./preflight-backup.sql
```

Then read `RELEASES.md` for the version you are moving to, replace this
folder's files with the new release's (download it again, or `git pull`), and
start it:

```
docker compose up -d
```

To restore a backup: `docker compose down`, remove the database volume with
`docker volume rm preflight-selfhost_postgres-data`, start the version the
backup came from, then:

```
docker compose cp ./preflight-backup.sql postgres:/tmp/preflight-backup.sql
docker compose exec -T postgres psql -U preflight -q -f /tmp/preflight-backup.sql preflight
```

## Changing the database password

The database reads `POSTGRES_PASSWORD` once, when it is first created, and
keeps its own copy after that. Changing `.env` alone therefore leaves
Preflight unable to sign in to it: nothing is lost, but the page stops
working and `docker compose logs api` says `password authentication failed`.
Do it in this order instead.

**Installed with 0.3.1 or earlier? Do this once when you update.** Those
releases gave the database a default password that is printed in Preflight's
source, and `docker compose up -d` now stops with *"required variable
POSTGRES_PASSWORD is missing a value"* until you replace it.

1. Make a new value with the command in step 2 and put it in `.env` as
   `POSTGRES_PASSWORD=...`.
2. Start the database on its own:

   ```
   docker compose up -d postgres
   ```

3. Give the database the same value. Paste it when asked, twice; nothing
   shows as you type:

   ```
   docker compose exec postgres psql -U preflight -d preflight -c "\password preflight"
   ```

4. Start everything:

   ```
   docker compose up -d
   ```

## If something goes wrong

- **The page does not load.** `docker compose ps` shows what is running;
  `docker compose logs api` says why the API is not. A message naming
  `PREFLIGHT_SECRET` means it is missing or under 16 characters.
- **`required variable … is missing a value`.** `.env` is missing, misspelled,
  or not in this folder. If it names `POSTGRES_PASSWORD` and Preflight has
  run here before, see
  [Changing the database password](#changing-the-database-password).
- **`password authentication failed`, or a message naming
  `POSTGRES_PASSWORD`, in `docker compose logs api`.** The database and
  `.env` disagree, or `.env` still has the old published value. See
  [Changing the database password](#changing-the-database-password).
- **A replay refuses with two different n8n versions.** `PREFLIGHT_N8N_VERSION`
  and the version you declared for the instance disagree. Fix whichever is
  wrong, then `docker compose up -d`.
- **Registration fails with a connection error.** The base URL is wrong for
  where your n8n runs — see step 5.

For anything else, use the report button, and tick **The error on this page**
if one is showing.

## What this beta does not do yet

- **One operator token, no user accounts.** Keep Preflight on this computer;
  it listens on `127.0.0.1` only, and the token travels over plain HTTP.
- **A replay proves your workflow's own logic**, not that a node still
  understands a changed outside API: those answers come from the recording.
- **Run-count watching after a deploy needs an extra workflow on your n8n,
  and that only works when n8n runs directly on this computer**, not in Docker.
  Everything else here works without it.
- **No automatic rollback.** Rollback is a button you press.
