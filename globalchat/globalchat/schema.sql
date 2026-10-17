-- =============================================================================
-- GlobalChat — complete Supabase migration
-- One world. One chat.
--
-- Run this whole file once in Supabase Dashboard → SQL Editor → New query.
-- It is written to be re-runnable: objects use IF NOT EXISTS / OR REPLACE and
-- policies are dropped before being recreated.
--
-- What this file sets up
--   1. Tables: messages, reports, guest_names, banned_users, moderators
--   2. Server-side rules (triggers): timestamps, 1-hour expiry, content
--      normalisation, rate limits, duplicate/flood protection, bans,
--      username ownership, report snapshots
--   3. Row Level Security + column-level grants
--   4. Realtime: database → "room:global" private broadcast channel
--   5. Scheduled cleanup with pg_cron (every 5 minutes)
--
-- Security model in one paragraph
--   Browsers only ever hold the public anon/publishable key plus an anonymous
--   user's JWT. Every rule that matters (who can insert, what a message may
--   contain, when it expires, how fast you may post) is enforced here, in the
--   database. Frontend checks exist only for a nicer experience.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Tunables (edit here, then re-run the file)
-- -----------------------------------------------------------------------------
-- These are plain SQL functions so triggers can read them; change the numbers
-- and re-run this file to apply.
create or replace function public.gc_setting(key text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case key
    when 'max_message_length'      then 500
    when 'burst_limit'             then 5     -- messages ...
    when 'burst_window_seconds'    then 10    -- ... per rolling window
    when 'hourly_limit'            then 120   -- messages per rolling hour
    when 'duplicate_window_seconds' then 60   -- same text again within N s is rejected
    when 'report_limit'            then 10    -- reports ...
    when 'report_window_minutes'   then 10    -- ... per rolling window
    when 'max_report_details'      then 500
  end;
$$;


-- -----------------------------------------------------------------------------
-- 1. Tables
-- -----------------------------------------------------------------------------

-- Public chat messages. Rows live for one hour, then become unreadable (RLS)
-- and are physically deleted by the scheduled cleanup job.
create table if not exists public.messages (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        not null default auth.uid()
                          references auth.users (id) on delete cascade,
  username    text        not null,
  content     text        not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '1 hour'),

  constraint messages_username_format
    check (username ~ '^[A-Za-z]{2,20}_[0-9]{4}$'),
  constraint messages_content_length
    check (char_length(content) between 1 and 500),
  constraint messages_expiry_after_creation
    check (expires_at > created_at)
);

comment on table public.messages is
  'GlobalChat public messages. Expire 1 hour after creation (server-enforced).';

-- History query: newest unexpired messages first.
create index if not exists messages_created_at_idx
  on public.messages (created_at desc);
-- Cleanup job + RLS filter.
create index if not exists messages_expires_at_idx
  on public.messages (expires_at);
-- Per-user rate limiting / duplicate detection.
create index if not exists messages_user_created_idx
  on public.messages (user_id, created_at desc);


-- Display-name ownership. The first message a guest sends "claims" their
-- generated name; nobody else can post under it while the claim exists.
-- Not readable by clients at all (RLS on, no policies).
create table if not exists public.guest_names (
  user_id      uuid        primary key references auth.users (id) on delete cascade,
  username     text        not null unique,
  claimed_at   timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);


-- Abuse reports. Reporters can create them; only moderators can read them.
-- A snapshot of the reported message is copied in so the evidence survives
-- after the message itself expires and is deleted.
create table if not exists public.reports (
  id                uuid        primary key default gen_random_uuid(),
  reporter_id       uuid        not null default auth.uid(),
  message_id        uuid        references public.messages (id) on delete set null,
  reason            text        not null,
  details           text,
  created_at        timestamptz not null default now(),

  -- Evidence snapshot, filled by trigger — never by the client.
  reported_user_id  uuid,
  reported_username text,
  reported_content  text,
  reported_at       timestamptz,

  -- Moderation workflow
  status            text        not null default 'open',
  resolved_by       uuid,
  resolved_at       timestamptz,
  resolution_note   text,

  constraint reports_reason_valid
    check (reason in ('harassment', 'threat', 'spam', 'personal_info', 'other')),
  constraint reports_details_length
    check (details is null or char_length(details) <= 500),
  constraint reports_status_valid
    check (status in ('open', 'actioned', 'dismissed'))
);

-- One report per guest per message.
create unique index if not exists reports_reporter_message_uniq
  on public.reports (reporter_id, message_id)
  where message_id is not null;
create index if not exists reports_status_created_idx
  on public.reports (status, created_at desc);
create index if not exists reports_reporter_created_idx
  on public.reports (reporter_id, created_at desc);


-- Banned guests. A ban applies to a specific anonymous user id; see
-- MODERATION.md for why bans alone cannot stop someone opening a new session,
-- and what the sign-in CAPTCHA / IP rate limit add on top.
create table if not exists public.banned_users (
  user_id      uuid        primary key,
  reason       text,
  banned_until timestamptz,          -- null = permanent
  created_at   timestamptz not null default now(),
  created_by   uuid
);


-- Moderators: real (non-anonymous) Supabase users you add by hand.
-- Nothing in the frontend can make someone a moderator.
create table if not exists public.moderators (
  user_id    uuid        primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);


-- -----------------------------------------------------------------------------
-- 2. Helper functions
-- -----------------------------------------------------------------------------

-- True only for signed-in, NON-anonymous users listed in public.moderators.
create or replace function public.is_moderator()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
     and exists (
       select 1 from public.moderators m where m.user_id = auth.uid()
     );
$$;

revoke all on function public.is_moderator() from public;
grant execute on function public.is_moderator() to authenticated;


-- Clean up user text: unify newlines, strip control and bidi-override
-- characters (used for spoofing), collapse runs of blank lines, trim.
create or replace function public.gc_normalize_text(input text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(
                 replace(coalesce(input, ''), E'\r\n', E'\n'),
                 -- C0 controls except \t and \n, DEL, C1 controls,
                 -- bidi embeddings/overrides/isolates, BOM
                 '[\u0001-\u0008\u000B-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069\uFEFF]',
                 '', 'g'),
               E'\n{3,}', E'\n\n', 'g'),           -- max one blank line
             E'[ \t]+\n', E'\n', 'g'),            -- trailing spaces on lines
           E'^[\\s]+|[\\s]+$', '', 'g');         -- trim both ends
$$;


-- -----------------------------------------------------------------------------
-- 3. Message trigger: the heart of server-side enforcement
-- -----------------------------------------------------------------------------
-- Runs BEFORE every insert. SECURITY DEFINER so it can read guest_names /
-- banned_users, which clients cannot see. auth.uid() still returns the
-- caller's id because it reads the request JWT, not the current role.
create or replace function public.messages_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid        uuid := auth.uid();
  v_recent     integer;
  v_hourly     integer;
  v_claimed    text;
  v_ban        public.banned_users%rowtype;
begin
  -- 1. Must be an authenticated guest. Ignore any client-supplied user id.
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501',
      hint = 'Sign in (anonymously) before sending messages.';
  end if;
  new.user_id := v_uid;

  -- 2. Never trust client timestamps: the server decides both.
  new.created_at := now();
  new.expires_at := now() + interval '1 hour';

  -- 3. Bans.
  select * into v_ban from public.banned_users b where b.user_id = v_uid;
  if found and (v_ban.banned_until is null or v_ban.banned_until > now()) then
    raise exception 'BANNED' using errcode = 'P0001',
      hint = 'This guest session has been blocked from posting.';
  end if;

  -- 4. Content: normalise, then validate.
  new.content := public.gc_normalize_text(new.content);
  if new.content = '' then
    raise exception 'EMPTY_MESSAGE' using errcode = 'P0001',
      hint = 'Messages cannot be empty.';
  end if;
  if char_length(new.content) > public.gc_setting('max_message_length') then
    raise exception 'MESSAGE_TOO_LONG' using errcode = 'P0001',
      hint = 'Messages can be at most 500 characters.';
  end if;

  -- 5. Username format (also a CHECK constraint, but this gives a clear error).
  if new.username is null or new.username !~ '^[A-Za-z]{2,20}_[0-9]{4}$' then
    raise exception 'INVALID_USERNAME' using errcode = 'P0001',
      hint = 'Display names look like Word_1234.';
  end if;

  -- 6. Serialise this guest's inserts so parallel requests cannot all slip
  --    under the rate limit at once. Transaction-scoped: released on commit.
  perform pg_advisory_xact_lock(hashtextextended('gc_msg:' || v_uid::text, 0));

  -- 7. Burst limit: 5 messages per rolling 10 seconds.
  select count(*) into v_recent
  from public.messages m
  where m.user_id = v_uid
    and m.created_at > now() - make_interval(secs => public.gc_setting('burst_window_seconds'));
  if v_recent >= public.gc_setting('burst_limit') then
    raise exception 'RATE_LIMITED' using errcode = 'P0001',
      hint = 'Too many messages. Wait a few seconds and try again.';
  end if;

  -- 8. Sustained limit: caps long-running spam from a single session.
  select count(*) into v_hourly
  from public.messages m
  where m.user_id = v_uid
    and m.created_at > now() - interval '1 hour';
  if v_hourly >= public.gc_setting('hourly_limit') then
    raise exception 'HOURLY_LIMIT' using errcode = 'P0001',
      hint = 'Hourly message limit reached for this session.';
  end if;

  -- 9. Repeat-spam: same text from the same guest within the window.
  if exists (
    select 1 from public.messages m
    where m.user_id = v_uid
      and m.created_at > now() - make_interval(secs => public.gc_setting('duplicate_window_seconds'))
      and lower(m.content) = lower(new.content)
  ) then
    raise exception 'DUPLICATE_MESSAGE' using errcode = 'P0001',
      hint = 'You just sent that. Try saying something new.';
  end if;

  -- 10. Display-name ownership. First use claims the name for this guest;
  --     afterwards the stored name always wins, so a guest cannot switch to
  --     someone else's name mid-session.
  select g.username into v_claimed from public.guest_names g where g.user_id = v_uid;
  if v_claimed is null then
    begin
      insert into public.guest_names (user_id, username) values (v_uid, new.username);
      v_claimed := new.username;
    exception when unique_violation then
      raise exception 'USERNAME_TAKEN' using errcode = 'P0001',
        hint = 'That display name is in use. A new one will be generated.';
    end;
  else
    update public.guest_names set last_used_at = now() where user_id = v_uid;
  end if;
  new.username := v_claimed;

  return new;
end;
$$;

drop trigger if exists messages_before_insert on public.messages;
create trigger messages_before_insert
  before insert on public.messages
  for each row execute function public.messages_before_insert();

-- Messages are immutable once sent.
create or replace function public.messages_block_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'MESSAGES_ARE_IMMUTABLE' using errcode = '42501';
end;
$$;

drop trigger if exists messages_block_update on public.messages;
create trigger messages_block_update
  before update on public.messages
  for each row execute function public.messages_block_update();


-- -----------------------------------------------------------------------------
-- 4. Realtime: broadcast from the database
-- -----------------------------------------------------------------------------
-- Instead of "Postgres Changes" (which ships whole rows, including user_id),
-- an AFTER trigger sends a trimmed public payload to the private Realtime
-- topic "room:global". Clients cannot forge these events: the RLS policies on
-- realtime.messages below only let clients RECEIVE broadcasts and TRACK
-- presence, never send broadcasts themselves.
create or replace function public.messages_broadcast()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    if tg_op = 'INSERT' then
      perform realtime.send(
        jsonb_build_object(
          'id',         new.id,
          'username',   new.username,
          'content',    new.content,
          'created_at', new.created_at,
          'expires_at', new.expires_at
        ),
        'message_created',
        'room:global',
        true
      );
    elsif tg_op = 'DELETE' and old.expires_at > now() then
      -- Deleted before expiry = removed by a moderator. Tell clients to hide it.
      -- (Expired rows removed by the cleanup job are already hidden client-side.)
      perform realtime.send(
        jsonb_build_object('id', old.id),
        'message_deleted',
        'room:global',
        true
      );
    end if;
  exception when others then
    -- Never let a Realtime hiccup roll back a chat message or moderation delete.
    raise warning 'GlobalChat broadcast failed: %', sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists messages_broadcast on public.messages;
create trigger messages_broadcast
  after insert or delete on public.messages
  for each row execute function public.messages_broadcast();


-- -----------------------------------------------------------------------------
-- 5. Report trigger
-- -----------------------------------------------------------------------------
create or replace function public.reports_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_recent integer;
  v_msg    public.messages%rowtype;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;

  -- Server owns identity, time and workflow fields.
  new.reporter_id     := v_uid;
  new.created_at      := now();
  new.status          := 'open';
  new.resolved_by     := null;
  new.resolved_at     := null;
  new.resolution_note := null;

  -- Details: normalise, drop if blank, enforce length.
  new.details := nullif(public.gc_normalize_text(new.details), '');
  if new.details is not null
     and char_length(new.details) > public.gc_setting('max_report_details') then
    raise exception 'DETAILS_TOO_LONG' using errcode = 'P0001',
      hint = 'Report details can be at most 500 characters.';
  end if;

  -- Report rate limit.
  perform pg_advisory_xact_lock(hashtextextended('gc_rep:' || v_uid::text, 0));
  select count(*) into v_recent
  from public.reports r
  where r.reporter_id = v_uid
    and r.created_at > now() - make_interval(mins => public.gc_setting('report_window_minutes'));
  if v_recent >= public.gc_setting('report_limit') then
    raise exception 'REPORT_RATE_LIMITED' using errcode = 'P0001',
      hint = 'Too many reports in a short time. Try again in a few minutes.';
  end if;

  -- Evidence snapshot. Only live (unexpired) messages can be reported.
  new.reported_user_id  := null;
  new.reported_username := null;
  new.reported_content  := null;
  new.reported_at       := null;
  if new.message_id is not null then
    select * into v_msg
    from public.messages m
    where m.id = new.message_id and m.expires_at > now();
    if not found then
      raise exception 'MESSAGE_NOT_FOUND' using errcode = 'P0001',
        hint = 'That message has expired or was removed.';
    end if;
    if v_msg.user_id = v_uid then
      raise exception 'CANNOT_REPORT_SELF' using errcode = 'P0001',
        hint = 'You cannot report your own message.';
    end if;
    new.reported_user_id  := v_msg.user_id;
    new.reported_username := v_msg.username;
    new.reported_content  := v_msg.content;
    new.reported_at       := v_msg.created_at;
  end if;

  return new;
end;
$$;

drop trigger if exists reports_before_insert on public.reports;
create trigger reports_before_insert
  before insert on public.reports
  for each row execute function public.reports_before_insert();


-- -----------------------------------------------------------------------------
-- 6. Privileges (column level) — defence in depth alongside RLS
-- -----------------------------------------------------------------------------
-- Supabase grants broad table privileges to anon/authenticated by default.
-- Start from zero and grant only what the app needs.
revoke all on public.messages     from anon, authenticated;
revoke all on public.reports      from anon, authenticated;
revoke all on public.guest_names  from anon, authenticated;
revoke all on public.banned_users from anon, authenticated;
revoke all on public.moderators   from anon, authenticated;

-- Guests read the public columns only — user_id is never readable via the API.
grant select (id, username, content, created_at, expires_at)
  on public.messages to authenticated;
-- Guests may only supply username + content; everything else is server-set.
grant insert (username, content) on public.messages to authenticated;
-- Deletion is granted but RLS limits it to moderators.
grant delete on public.messages to authenticated;

-- Reports: guests insert three fields; moderators read/update/delete via RLS.
grant insert (message_id, reason, details) on public.reports to authenticated;
grant select, delete on public.reports to authenticated;
grant update (status, resolved_by, resolved_at, resolution_note)
  on public.reports to authenticated;

-- Bans: moderators only (via RLS).
grant select, insert, update, delete on public.banned_users to authenticated;
-- moderators / guest_names: no client access at all.


-- -----------------------------------------------------------------------------
-- 7. Row Level Security
-- -----------------------------------------------------------------------------
alter table public.messages     enable row level security;
alter table public.reports      enable row level security;
alter table public.guest_names  enable row level security;
alter table public.banned_users enable row level security;
alter table public.moderators   enable row level security;

-- messages ------------------------------------------------------------------
drop policy if exists "messages: read unexpired"          on public.messages;
drop policy if exists "messages: guests insert own"       on public.messages;
drop policy if exists "messages: moderators delete"       on public.messages;

create policy "messages: read unexpired"
  on public.messages for select
  to authenticated
  using (expires_at > now());

create policy "messages: guests insert own"
  on public.messages for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "messages: moderators delete"
  on public.messages for delete
  to authenticated
  using ((select public.is_moderator()));
-- No UPDATE policy: messages cannot be edited by anyone through the API.

-- reports -------------------------------------------------------------------
drop policy if exists "reports: guests insert own"   on public.reports;
drop policy if exists "reports: moderators read"     on public.reports;
drop policy if exists "reports: moderators update"   on public.reports;
drop policy if exists "reports: moderators delete"   on public.reports;

create policy "reports: guests insert own"
  on public.reports for insert
  to authenticated
  with check (reporter_id = (select auth.uid()));

-- Reporters cannot read reports back, including their own.
create policy "reports: moderators read"
  on public.reports for select
  to authenticated
  using ((select public.is_moderator()));

create policy "reports: moderators update"
  on public.reports for update
  to authenticated
  using ((select public.is_moderator()))
  with check ((select public.is_moderator()));

create policy "reports: moderators delete"
  on public.reports for delete
  to authenticated
  using ((select public.is_moderator()));

-- banned_users --------------------------------------------------------------
drop policy if exists "bans: moderators manage" on public.banned_users;
create policy "bans: moderators manage"
  on public.banned_users for all
  to authenticated
  using ((select public.is_moderator()))
  with check ((select public.is_moderator()));

-- guest_names, moderators: RLS on, no policies → invisible to clients.


-- -----------------------------------------------------------------------------
-- 8. Realtime authorization for the private "room:global" channel
-- -----------------------------------------------------------------------------
-- Signed-in guests may receive broadcasts and presence for room:global, and
-- may publish their own presence. They may NOT insert broadcast messages, so
-- only the database trigger above can emit chat events.
drop policy if exists "globalchat: receive room events" on realtime.messages;
drop policy if exists "globalchat: track presence"      on realtime.messages;

create policy "globalchat: receive room events"
  on realtime.messages for select
  to authenticated
  using (
    (select realtime.topic()) = 'room:global'
    and realtime.messages.extension in ('broadcast', 'presence')
  );

create policy "globalchat: track presence"
  on realtime.messages for insert
  to authenticated
  with check (
    (select realtime.topic()) = 'room:global'
    and realtime.messages.extension = 'presence'
  );


-- -----------------------------------------------------------------------------
-- 9. Scheduled cleanup (pg_cron)
-- -----------------------------------------------------------------------------
-- Physically deletes expired messages every 5 minutes and forgets display-name
-- claims that have been idle for a day. If pg_cron is unavailable this block
-- prints a notice instead of failing; see README "Scheduled cleanup without
-- pg_cron" for the alternative.
create or replace function public.gc_cleanup()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.messages where expires_at <= now();
  delete from public.guest_names where last_used_at < now() - interval '1 day';
  delete from public.banned_users
    where banned_until is not null and banned_until < now() - interval '1 day';

  -- Realtime keeps its own copy of each broadcast payload in realtime.messages
  -- (Supabase also prunes this table automatically). Purge ours after an hour
  -- so message text doesn't outlive its expiry there. Guarded: if Supabase
  -- changes that internal table, cleanup of public.messages still succeeds.
  begin
    delete from realtime.messages
    where topic = 'room:global' and inserted_at < now() - interval '1 hour';
  exception when others then
    raise notice 'GlobalChat: realtime.messages purge skipped (%)', sqlerrm;
  end;
end;
$$;

-- Only the database owner / service role may run cleanup directly.
revoke all on function public.gc_cleanup() from public, anon, authenticated;

do $do$
begin
  create extension if not exists pg_cron;
  perform cron.schedule(
    'globalchat-cleanup',
    '*/5 * * * *',
    'select public.gc_cleanup();'
  );
  raise notice 'GlobalChat: pg_cron job "globalchat-cleanup" scheduled every 5 minutes.';
exception when others then
  raise notice 'GlobalChat: pg_cron not available (%). Use the alternative in README.', sqlerrm;
end;
$do$;

-- Optional: purge anonymous auth users older than 7 days (their messages are
-- long gone). Reports keep their evidence snapshot. Uncomment to enable.
-- select cron.schedule(
--   'globalchat-purge-anon-users',
--   '17 3 * * *',
--   $$delete from auth.users
--     where is_anonymous is true and created_at < now() - interval '7 days'$$
-- );

-- =============================================================================
-- Done. Next: README.md → "Enable Realtime" and "Configure the frontend".
-- =============================================================================
