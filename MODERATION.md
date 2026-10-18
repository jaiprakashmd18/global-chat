# GlobalChat moderation

## Who can moderate

A moderator is a **real, non-anonymous Supabase user** whose id is in `public.moderators`. The check is `public.is_moderator()` in the database; nothing in the frontend can grant moderator access, and an anonymous guest is never a moderator even if their id is added to the table.

Moderators use the **admin page**, `/admin.html` on your site. It shows open reports (grouped by message), live messages including ones auto-hidden after reports, and lets you pin, hide/unhide, delete, ban (1 hour, 24 hours or permanently), set slow mode, and edit the word filter. Every action is checked again by the database (`is_moderator()`, RLS and the `gc_mod_*` functions), so the page itself grants nothing. The SQL below still works in the Supabase **SQL Editor** for anything the page doesn't cover.

### Add a moderator (for the admin page)

1. Dashboard → **Authentication → Users → Add user** → create the person with email and password (or invite them).
2. In SQL Editor:

```sql
insert into public.moderators (user_id)
select id from auth.users where email = 'moderator@example.com';
```

Remove one with `delete from public.moderators where user_id = '...';`.

## Daily workflow

1. **Review open reports**, oldest first.
2. **Decide**: remove the message, ban the session, or dismiss.
3. **Record the outcome** on the report.
4. **Purge** handled reports after your retention period.

### 1. Open reports

```sql
select id, created_at, reason, details,
       reported_username, reported_content, reported_at,
       reported_user_id, reporter_id
from public.reports
where status = 'open'
order by created_at;
```

`reported_content` is a snapshot taken when the report was filed, so it's still there after the message itself expires.

Repeat offenders and coordinated reporting:

```sql
-- Sessions with the most reports in the last 24h
select reported_user_id, reported_username, count(*) as reports
from public.reports
where created_at > now() - interval '1 day'
group by 1, 2 order by reports desc limit 20;
```

### 2a. Remove a message

```sql
delete from public.messages where id = '<message-id>';
```

If it hasn't expired yet, everyone online sees it disappear immediately (the delete trigger broadcasts `message_deleted`).

Remove everything a session has posted:

```sql
delete from public.messages where user_id = '<reported_user_id>';
```

### 2b. Ban a guest session

```sql
insert into public.banned_users (user_id, reason, banned_until)
values ('<reported_user_id>', 'harassment', now() + interval '24 hours')  -- or null for permanent
on conflict (user_id) do update
  set reason = excluded.reason, banned_until = excluded.banned_until;
```

A banned session gets "This guest session can't post because of a moderation action." Lift a ban with `delete from public.banned_users where user_id = '...';`.

To end the session entirely (they'll be given a fresh guest identity), delete the anonymous user: `delete from auth.users where id = '<reported_user_id>' and is_anonymous;`. Their unexpired messages are removed with it.

**Limits of bans:** anyone can open a new tab and get a new anonymous session. Bans stop a session, not a person. Turnstile on sign-in and anonymous sign-in rate limits (see README, "Before public launch") are what slow down people who keep coming back. For persistent abuse, tighten those limits and consider Cloudflare WAF rules on your domain.

### 3. Record the outcome

```sql
update public.reports
set status = 'actioned',            -- or 'dismissed'
    resolved_at = now(),
    resolution_note = 'Message removed, 24h ban'
where id = '<report-id>';
```

### 4. Retention

Reports contain copies of message text, so don't keep them longer than you need:

```sql
delete from public.reports
where status <> 'open' and resolved_at < now() - interval '30 days';
```

You can schedule this with pg_cron the same way as `globalchat-cleanup`.

## Urgent content

For credible threats of violence, child sexual abuse material, or other content you may be legally required to act on: remove it immediately, preserve the report row, and follow the reporting obligations in your jurisdiction (for example, NCMEC in the US or the relevant national hotline elsewhere). Don't wait for the hourly expiry.

## Images, polls, reactions and self-deletion

- **Reported images.** `reports.reported_image_path` holds the storage path of a reported image. While the report is `open`, the image cleanup keeps the file, so you can view it in Dashboard → **Storage → chat-images**. Once you mark the report `actioned` or `dismissed`, the next cleanup run deletes the file.

```sql
select id, reason, reported_username, reported_content, reported_image_path
from public.reports
where status = 'open' and reported_image_path is not null
order by created_at;
```

- **Removing a message** (`delete from public.messages where id = '...'`) also removes its reactions and votes, tells every open page to hide it, and leaves the image for the cleanup to delete. Anyone who already had the image open can keep seeing it until it would have expired.
- **Self-deletion.** Guests can delete their own messages before they expire. A report that was already filed keeps its evidence snapshot, so deleting doesn't help someone escape a report.
- **Who reacted or voted** is in `public.reactions` / `public.poll_votes` (with `user_id`), readable only from the SQL Editor. Use it to spot vote-stuffing, e.g. many sessions created at once voting the same way.
- **New-user cooldown**: guest sessions younger than 2 minutes can't post links, photos or voice notes (`new_user_seconds` in `gc_setting()`; set it higher, e.g. 600, during a spam wave, and re-run `schema.sql`).
- **Limits** for reactions/votes (30 per minute) and image uploads (10 per 10 minutes) are in `gc_setting()` at the top of `schema.sql`.

## Admin page tips

- **Auto-hidden messages** (3+ different reporters) appear on the admin page with an orange border and "HIDDEN after reports". **Unhide** puts them back for everyone; **Delete** removes them.
- **Ban from a report** uses the reported guest's session id from the report, so it works even after the message is deleted. **Ban** on a live message works through `gc_mod_ban_author()`.
- **Slow mode** limits every guest to one message per N seconds (up to 5 minutes). The page shows a 🐢 banner while it's on.
- **Pin** shows a message at the top of the room until it expires (one hour after it was sent) or you unpin it.
- **Word filter** changes apply to new messages only.
- The **room bot** posts as "GlobalChat Bot" (`is_bot = true`). Change trivia and daily questions with SQL: `insert into public.trivia_questions (question, answers) values ('…?', array['answer', 'alternative']);` and `insert into public.daily_questions (question) values ('…');`. Stop the bot with `select cron.unschedule('globalchat-trivia');` / `select cron.unschedule('globalchat-daily-question');`.
