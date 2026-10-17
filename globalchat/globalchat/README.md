# GlobalChat

**One world. One chat.**

GlobalChat is a single public chatroom. Anyone who opens the site gets a random guest name and can start talking with everyone online, with no sign-up. Messages disappear after an hour.

It's a static frontend (HTML, CSS, vanilla JS modules) on top of Supabase: anonymous auth, Postgres with Row Level Security, and Realtime for live messages and online presence.

### Features

- **Chat bubbles**: your messages on the right in your accent colour, everyone else on the left with a coloured avatar and name. Messages from one person in a row are grouped.
- **Themes**: light, dark, or follow the system, with five accent colours (violet, ocean, sunset, mint, rose) and a compact density. Choices are saved in the browser only (`localStorage`).
- **Online now**: a live list of who's in the room (sidebar on desktop, tap the online count on phones).
- **Typing indicator**: "QuietFox_1937 is typing…" above the message box.
- **@mentions**: click a name to mention them. Messages that mention you are highlighted, and you can turn on a sound and/or a desktop notification for mentions.
- **Links**: `http(s)` URLs become safe links (`rel="noopener noreferrer nofollow ugc"`).
- **Emoji picker**, **message search**, **copy message**, **unread count in the tab title**, and quick conversation starters when the room is empty.
- **Fading messages**: messages fade slightly in their last five minutes before they disappear.
- Keyboard: <kbd>/</kbd> focuses the message box, <kbd>Esc</kbd> closes search and the emoji picker.

Presence and typing use the existing Realtime presence permission, so none of these features need database changes.

---

## Contents

1. [How it works](#how-it-works)
2. [Project files](#project-files)
3. [Setup: Supabase](#setup-supabase) (steps 1–5)
4. [Setup: frontend and local run](#setup-frontend-and-local-run) (steps 6–7)
5. [Deploy](#deploy) (step 8)
6. [Scheduled expiry cleanup](#scheduled-expiry-cleanup) (step 9)
7. [Testing](#testing) (step 10)
8. [Troubleshooting Supabase errors](#troubleshooting-supabase-errors) (step 11)
9. [Before public launch: abuse prevention and moderation](#before-public-launch) (step 12)
10. [Manual configuration still required](#manual-configuration-still-required)
11. [Privacy notes and limits](#privacy-notes-and-limits)

---

## How it works

```
Browser tab                                   Supabase
───────────                                   ────────
1. signInAnonymously() ─────────────────────► Auth: new anonymous user (JWT)
   session kept in sessionStorage                (optional Turnstile check)

2. subscribe to private channel "room:global" ► Realtime (RLS on realtime.messages:
   track presence (random key,                    receive + presence only)
   guest name + typing flag)

3. select latest 100 messages ──────────────► Postgres: RLS returns only
                                                  unexpired rows, public columns

4. insert { username, content } ────────────► BEFORE INSERT trigger:
                                                  sets user_id, timestamps, expiry,
                                                  normalises text, rate limits,
                                                  duplicate check, bans, name ownership
                                               AFTER INSERT trigger:
   ◄──────────── "message_created" broadcast ──  realtime.send(public fields only)

5. pg_cron every 5 min ─────────────────────► delete expired rows
```

Design decisions worth knowing:

- **Live messages use "Broadcast from Database", not "Postgres Changes".** Postgres Changes would send whole rows to every client, including the author's internal `user_id`. A trigger instead sends only `id, username, content, created_at, expires_at`. Clients cannot forge chat events because the Realtime policies don't let them send broadcasts at all.
- **`user_id` is never readable through the API.** Column-level grants expose only the public columns.
- **Display names are owned server-side.** The first message a guest sends claims their name; nobody else can post under it while the claim is active, and a guest can't switch to someone else's name.
- **All rules live in the database.** The browser's checks (counter, cooldown) only make the experience smoother.

## Project files

| File | Purpose |
|---|---|
| `index.html` | Page structure, dialogs, message template |
| `styles.css` | All styling (light/dark themes, accents, responsive, reduced motion) |
| `theme.js` | Applies the saved theme before first paint; stores appearance and alert preferences |
| `app.js` | Auth, realtime, presence, typing, messaging, mentions, search, expiry, reporting |
| `config.js` | **Your** Supabase URL and public key (placeholders until you edit it) |
| `schema.sql` | Complete database migration (run once) |
| `favicon.svg`, `fonts/` | Brand mark and self-hosted fonts (OFL licensed) |
| `vercel.json`, `_headers` | Security headers (CSP etc.) for Vercel / Cloudflare Pages |
| `MODERATION.md` | Moderation workflow and SQL snippets |
| `TESTING.md` | Test checklist |
| `tests/local-db/` | Optional: run the migration + security tests against local Postgres |

---

## Setup: Supabase

### 1. Create a Supabase project

1. Sign in at [supabase.com](https://supabase.com) and click **New project**.
2. Choose a name, a strong database password (store it in a password manager), and the region closest to most of your users.
3. Wait for the project to finish provisioning.

### 2. Enable anonymous sign-in

1. Dashboard → **Authentication** → **Sign In / Providers** (in some dashboard versions: *Providers* or *Settings*).
2. Turn on **Allow anonymous sign-ins** and save.

While you're in Authentication, open **Rate Limits** and note the limit for anonymous sign-ins per IP. The default is fine to start with; lower it if you see abuse.

### 3. Run the SQL migration

1. Dashboard → **SQL Editor** → **New query**.
2. Paste the entire contents of `schema.sql` and click **Run**.
3. Check the output: you should see the notice `GlobalChat: pg_cron job "globalchat-cleanup" scheduled every 5 minutes.` If you instead see `pg_cron not available`, follow [Scheduled cleanup without pg_cron](#scheduled-cleanup-without-pg_cron).

The file is safe to run again (for example after changing limits in `gc_setting`).

### 4. Realtime

This project uses **private Broadcast channels fed by a database trigger**, so you do **not** add the `messages` table to the `supabase_realtime` publication. Doing so isn't needed and would make Postgres Changes available, which ships full rows.

What you should check:

1. Dashboard → **Realtime**. Realtime is enabled by default on new projects.
2. In Realtime's **Settings**, if your dashboard shows an option to allow public channel access, turn it **off** so only authorised private channels can be used. GlobalChat only uses a private channel.
3. Confirm the two policies created by `schema.sql` exist: Dashboard → **Authentication → Policies** (or **Database → Policies**), schema `realtime`, table `messages`: *globalchat: receive room events* and *globalchat: track presence*.

`schema.sql` calls `realtime.send(...)`, which exists on current Supabase projects. If broadcasts don't arrive, see [Troubleshooting](#troubleshooting-supabase-errors).

### 5. Get the project URL and public key

Dashboard → **Project Settings** → **API** (newer dashboards: **API Keys** and **Data API**):

- **Project URL**: `https://<project-ref>.supabase.co`
- **Public key**: either the legacy **anon public** key (a long string starting with `eyJ`) or a **publishable** key (starts with `sb_publishable_`).

Never use the **service_role** key or a **secret** key (`sb_secret_…`) in the frontend. They bypass every security rule in this project.

---

## Setup: frontend and local run

### 6. Configure the frontend

Edit `config.js`:

```js
export const CONFIG = {
  SUPABASE_URL: 'https://abcdefghijklmnop.supabase.co',   // yours
  SUPABASE_ANON_KEY: 'eyJhbGciOi...',                      // yours (public)
  TURNSTILE_SITE_KEY: '',                                  // see "Before public launch"
};
```

Until you do, the app shows a "Connect GlobalChat to Supabase" screen instead of failing silently.

`config.js` is committed on purpose: the values in it are public by design and every visitor's browser downloads them. Security comes from the database rules.

### 7. Run locally

ES modules don't load from `file://`, so serve the folder over HTTP. Any static server works:

```bash
# Python 3
python3 -m http.server 8080

# or Node
npx serve -l 8080 .
```

Open <http://localhost:8080>. To see real-time behaviour, open a second **window** (or a private window). Each tab gets its own guest identity because sessions live in `sessionStorage`.

Local servers don't send the CSP headers from `vercel.json` / `_headers`; that's expected.

---

## Deploy

### 8a. Vercel

1. Push the project to a Git repository (GitHub, GitLab, or Bitbucket).
2. In Vercel: **Add New → Project**, import the repository.
3. Framework preset: **Other**. Build command: *(leave empty)*. Output directory: `.` (the project root).
4. Deploy. `vercel.json` applies the security headers automatically.

Or from the CLI in the project folder: `npx vercel` (preview) then `npx vercel --prod`.

### 8b. Cloudflare Pages

1. Push the project to GitHub or GitLab.
2. Cloudflare dashboard → **Workers & Pages → Create → Pages → Connect to Git**.
3. Framework preset: **None**. Build command: *(empty)*. Build output directory: `/`.
4. Deploy. The `_headers` file applies the security headers.

Or with the CLI: `npx wrangler pages deploy . --project-name globalchat`.

### After deploying

1. Supabase Dashboard → **Authentication → URL Configuration**: set **Site URL** to your production URL. (GlobalChat doesn't use email links, but keeping this correct avoids surprises later.)
2. Open the site in two browsers and run through [TESTING.md](TESTING.md).
3. If you use a custom Supabase domain, add it to `connect-src` in both `vercel.json` and `_headers`; the default CSP only allows `*.supabase.co`.

---

## Scheduled expiry cleanup

Expiry has two layers:

1. **Visibility (always on):** the RLS policy only returns rows where `expires_at > now()`, and `expires_at` is set by the server to exactly one hour after `created_at`. Clients can't read an expired message even if cleanup never runs.
2. **Physical deletion:** `public.gc_cleanup()` deletes expired rows, idle display-name claims, lapsed bans, and Realtime's internal copy of our broadcasts older than an hour.

### 9a. With pg_cron (default)

`schema.sql` enables `pg_cron` and schedules `globalchat-cleanup` every 5 minutes. Verify in **SQL Editor**:

```sql
select jobname, schedule, active from cron.job;
select status, start_time, return_message
from cron.job_run_details order by start_time desc limit 5;
```

Or use Dashboard → **Integrations → Cron** (if your dashboard shows it).

### Scheduled cleanup without pg_cron

If `pg_cron` isn't available, run `select public.gc_cleanup();` on a schedule from a trusted backend that holds a database connection string as a secret. A simple option is a GitHub Actions workflow in a **private** repository:

```yaml
# .github/workflows/cleanup.yml
name: GlobalChat cleanup
on:
  schedule:
    - cron: "*/5 * * * *"   # GitHub may delay scheduled runs
  workflow_dispatch:
jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - run: sudo apt-get update && sudo apt-get install -y postgresql-client
      - run: psql "$DATABASE_URL" -c "select public.gc_cleanup();"
        env:
          DATABASE_URL: ${{ secrets.SUPABASE_DB_URL }}
```

Get the connection string from Dashboard → **Connect** (use the pooler string), and store it as the repository secret `SUPABASE_DB_URL`. Never put it in frontend code. `gc_cleanup()` can't be called by guests: execute rights are revoked from `anon` and `authenticated`.

---

## Testing

See **[TESTING.md](TESTING.md)** for the full checklist: sign-in, two-browser messaging, presence, validation, rate limits, unauthorized access, expiry, reports, mobile, reconnection, and safe rendering.

For changes to `schema.sql`, `tests/local-db/run.sh` runs the migration plus 15 groups of security tests against a local PostgreSQL with stand-ins for Supabase's `auth` and `realtime` schemas.

---

## Troubleshooting Supabase errors

Open the browser's developer console first; GlobalChat logs failures with a `[GlobalChat]` prefix.

| Symptom / message | Likely cause | Fix |
|---|---|---|
| "Connect GlobalChat to Supabase" screen | `config.js` still has placeholders | Step 6 |
| `Anonymous sign-ins are disabled` | Provider not enabled | Step 2 |
| `Invalid API key` / 401 on every request | Wrong key or URL, or a secret key used | Re-copy from step 5; use the anon/publishable key |
| `permission denied for table messages` | `schema.sql` not run, or code selecting `*` / `user_id` | Run step 3; always select the public columns only |
| `new row violates row-level security policy` | Not signed in, or JWT expired | Reload; check Auth logs |
| `RATE_LIMITED`, `HOURLY_LIMIT`, `DUPLICATE_MESSAGE` | Working as intended | Wait, or adjust `gc_setting` in `schema.sql` and re-run |
| Status stuck on "Connecting"/"Reconnecting", console mentions `Unauthorized` or channel permissions | Realtime policies missing, or public-only channel settings | Re-run `schema.sql`; check step 4 |
| History loads but new messages only appear after reload | Broadcast trigger failing | **Dashboard → Logs → Postgres**: look for `GlobalChat broadcast failed`. Check `select proname from pg_proc where proname = 'send' and pronamespace = 'realtime'::regnamespace;` returns a row |
| Online count shows "–" | Presence not syncing (same cause as above) or not yet connected | Check Realtime logs |
| `captcha verification process failed` | Turnstile site key in `config.js` doesn't match the secret in Supabase, or CAPTCHA enabled without a site key | Fix the key pair, or clear CAPTCHA in Supabase |
| `Request rate limit reached` on sign-in | Too many anonymous sign-ins from one IP | Wait, or raise the limit in Auth → Rate Limits |
| Blank page, console shows CSP errors | Custom Supabase domain or extra script host not in the CSP | Add it to `vercel.json` / `_headers` |
| Module/CORS errors locally | Opened via `file://` | Use a local HTTP server (step 7) |

Useful places: **Logs → Auth / Postgres / Realtime / API**, and **Database → Advisors** (Security Advisor should show no RLS warnings for these tables).

---

## Before public launch

Rate limits and validation are already enforced by the database. Do these before sharing the link widely:

1. **Turn on Cloudflare Turnstile for sign-ins.**
   - Create a Turnstile widget in the Cloudflare dashboard for your domain(s) (add `localhost` for testing). You'll get a *site key* and a *secret key*.
   - Supabase → **Authentication → Attack Protection** → enable **CAPTCHA protection**, provider **Turnstile**, paste the **secret** key.
   - Put the **site** key in `config.js` → `TURNSTILE_SITE_KEY` and redeploy.
   - Effect: every new anonymous session must pass Turnstile, verified by Supabase on the server, so scripts can't mint unlimited guest accounts.
2. **Tighten anonymous sign-in rate limits** (Authentication → Rate Limits) to what a real person needs, for example a handful per hour per IP.
3. **Set up moderators** following [MODERATION.md](MODERATION.md), and decide who checks reports and how often.
4. **Turn off public Realtime channel access** if your dashboard offers it (step 4).
5. **Review `gc_setting`** in `schema.sql`: burst 5 per 10 s, 120 per hour, duplicate window 60 s, 10 reports per 10 minutes.
6. **Publish a short privacy notice and terms** appropriate to your jurisdiction. The in-app "How GlobalChat works" dialog is a starting point, not legal advice. Public anonymous chat can attract minors and illegal content; know your reporting obligations.
7. **Optional:** enable the commented-out job at the end of `schema.sql` that purges anonymous auth users older than 7 days.

Why bans alone aren't enough: a ban applies to one anonymous session, and anyone can open a new tab to get a new one. Turnstile plus sign-in rate limits are what make repeat abuse slow and costly; bans, per-session limits, and duplicate detection handle the rest.

---

## Manual configuration still required

Nothing here has been deployed or connected to a live Supabase project yet. You need to:

- [ ] Create the Supabase project (step 1)
- [ ] Enable anonymous sign-ins (step 2)
- [ ] Run `schema.sql` and confirm the pg_cron notice (steps 3, 9)
- [ ] Check Realtime settings and policies (step 4)
- [ ] Put your URL and public key in `config.js` (steps 5–6)
- [ ] Deploy to Vercel or Cloudflare Pages (step 8)
- [ ] Set Site URL in Supabase Auth (after deploy)
- [ ] Configure Turnstile + CAPTCHA protection and sign-in rate limits (before launch)
- [ ] Add at least one moderator account (MODERATION.md)
- [ ] Run the TESTING.md checklist against the live deployment

## Privacy notes and limits

- Other visitors see only random names, message text, and times, plus each open tab's random name in the online list and a typing hint while someone writes. IP addresses, emails, and internal IDs are never shown, and `user_id` isn't readable through the API.
- GlobalChat isn't fully anonymous. Supabase and your host process IP addresses and request logs to operate and secure the service.
- Expiry hides messages after one hour and cleanup deletes them within about five minutes after that. It does **not** guarantee removal from database backups, provider logs, or screenshots and copies other people made.
- Reported messages are copied into `reports` as evidence and kept until a moderator deletes the report.
- Live delivery is best-effort: if a tab is disconnected for a while, it reloads the latest 100 messages on reconnect, so a very busy room can leave a gap.
