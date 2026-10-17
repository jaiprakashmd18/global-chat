# GlobalChat moderation

## Who can moderate

A moderator is a **real, non-anonymous Supabase user** whose id is in `public.moderators`. The check is `public.is_moderator()` in the database; nothing in the frontend can grant moderator access, and an anonymous guest is never a moderator even if their id is added to the table.

This project doesn't ship a moderator dashboard. Day-to-day moderation happens in the Supabase **SQL Editor**, which runs as the database owner and only people with access to your Supabase project can use. The RLS policies for moderators (read/resolve reports, delete messages, manage bans) are already in place, so a separate authenticated moderator app can be built later without changing the schema.

### Add a moderator (for a future moderator app)

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
