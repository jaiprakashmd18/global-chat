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
--   5. Interactive features: replies, image messages (Supabase Storage),
--      polls, emoji reactions, deleting your own message
--   6. Community features: room bot (trivia, question of the day), dice /
--      coin / 8-ball commands, editing, renaming, stickers, voice notes,
--      country flags, word filter, slow mode, pinned message, auto-hide
--      after reports, room stats, moderator functions for admin.html
--   7. Scheduled cleanup with pg_cron (every 5 minutes)
--
-- Upgrading an existing project: just run the whole file again. New columns
-- and tables are added in place; existing messages are kept.
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
    when 'action_limit'            then 30    -- reactions + poll votes ...
    when 'action_window_seconds'   then 60    -- ... per rolling window
    when 'upload_limit'            then 10    -- image uploads ...
    when 'upload_window_minutes'   then 10    -- ... per rolling window
    when 'max_poll_question'       then 200
    when 'max_poll_option'         then 80
    when 'edit_window_seconds'     then 120   -- edit your message within 2 minutes
    when 'rename_cooldown_seconds' then 30    -- change your nickname at most this often
    when 'auto_hide_reports'       then 3     -- distinct open reports that hide a message
    when 'max_slow_mode_seconds'   then 300
    when 'trivia_every_minutes'    then 15    -- new trivia question at most this often ...
    when 'trivia_answer_minutes'   then 5     -- ... and this long to answer it
    when 'trivia_quiet_minutes'    then 30    -- skip trivia if nobody posted for this long
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
  constraint messages_expiry_after_creation
    check (expires_at > created_at)
);

comment on table public.messages is
  'GlobalChat public messages. Expire 1 hour after creation (server-enforced).';

-- Interactive-feature columns. Added with ALTER so re-running this file
-- upgrades an existing project in place.
--   kind          'text' | 'image' | 'poll'
--   reply_to      the message this one answers (cleared if that one goes)
--   image_path    object name in the private "chat-images" storage bucket
--   poll_options  2–4 answer labels; the poll question is `content`
alter table public.messages add column if not exists kind text not null default 'text';
alter table public.messages add column if not exists reply_to uuid
  references public.messages (id) on delete set null;
alter table public.messages add column if not exists image_path text;
alter table public.messages add column if not exists poll_options text[];

-- Community-feature columns (see section 10).
--   is_bot      posted by the room bot (trivia, question of the day); guests
--               can't set it: it isn't in their INSERT grant
--   command     set by the server for /roll, /flip, /8ball results so they
--               can't be faked by typing the same text
--   sticker     sticker id for kind = 'sticker'
--   country     optional ISO country code the guest chose to show
--   edited_at   when the author last edited the text
--   hidden      hidden after enough reports, until a moderator decides
alter table public.messages add column if not exists is_bot boolean not null default false;
alter table public.messages add column if not exists command text;
alter table public.messages add column if not exists sticker text;
alter table public.messages add column if not exists country text;
alter table public.messages add column if not exists edited_at timestamptz;
alter table public.messages add column if not exists hidden boolean not null default false;
-- Bot messages have no guest behind them.
alter table public.messages alter column user_id drop not null;
alter table public.messages drop constraint if exists messages_author_present;
alter table public.messages add constraint messages_author_present
  check (is_bot or user_id is not null);
-- Optional gender label the guest chose to show (never required).
alter table public.messages add column if not exists gender text;
alter table public.messages drop constraint if exists messages_gender_valid;
alter table public.messages add constraint messages_gender_valid
  check (gender is null or gender in ('male', 'female', 'nonbinary'));
alter table public.messages drop constraint if exists messages_country_format;
alter table public.messages add constraint messages_country_format
  check (country is null or country ~ '^[A-Z]{2}$');

-- Image messages may have an empty caption, so the length rule is "at most
-- 500"; the trigger requires text for text messages and poll questions.
alter table public.messages drop constraint if exists messages_content_length;
alter table public.messages add constraint messages_content_length
  check (char_length(content) <= 500);
alter table public.messages drop constraint if exists messages_kind_valid;
alter table public.messages add constraint messages_kind_valid
  check (kind in ('text', 'image', 'poll', 'sticker', 'voice'));

-- History query: newest unexpired messages first.
create index if not exists messages_created_at_idx
  on public.messages (created_at desc);
-- Cleanup job + RLS filter.
create index if not exists messages_expires_at_idx
  on public.messages (expires_at);
-- Per-user rate limiting / duplicate detection.
create index if not exists messages_user_created_idx
  on public.messages (user_id, created_at desc);
-- One message per uploaded image; also speeds up the storage read policy.
create unique index if not exists messages_image_path_uniq
  on public.messages (image_path) where image_path is not null;
create index if not exists messages_reply_to_idx
  on public.messages (reply_to) where reply_to is not null;


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
  reported_image_path text,

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
alter table public.reports add column if not exists reported_image_path text;

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


-- Emoji reactions. One row per (message, guest, emoji). Never readable
-- directly: clients get counts (not who reacted) through gc_* functions.
create table if not exists public.reactions (
  message_id uuid        not null references public.messages (id) on delete cascade,
  user_id    uuid        not null references auth.users (id) on delete cascade,
  emoji      text        not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji),
  constraint reactions_emoji_valid
    check (emoji in ('❤️', '👍', '😂', '😮', '😢', '🔥'))
);


-- Poll votes. One vote per guest per poll; changing your vote replaces it.
-- Like reactions, only totals are ever shown to clients.
create table if not exists public.poll_votes (
  message_id uuid        not null references public.messages (id) on delete cascade,
  user_id    uuid        not null references auth.users (id) on delete cascade,
  option_idx smallint    not null check (option_idx between 0 and 3),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);


-- Rate-limit ledger for reactions and votes. Toggling a reaction on and off
-- deletes rows from public.reactions, so those can't be counted directly.
-- Pruned by the cleanup job.
create table if not exists public.rate_events (
  user_id    uuid        not null,
  action     text        not null,
  created_at timestamptz not null default now()
);
create index if not exists rate_events_user_action_idx
  on public.rate_events (user_id, action, created_at desc);


-- Room-wide state set by moderators: pinned message and slow mode.
-- Exactly one row. Read through gc_room_state(); changed through gc_mod_*.
create table if not exists public.room_state (
  id                smallint primary key default 1 check (id = 1),
  pinned_message_id uuid references public.messages (id) on delete set null,
  slow_mode_seconds integer not null default 0 check (slow_mode_seconds between 0 and 3600),
  updated_at        timestamptz not null default now()
);
insert into public.room_state (id) values (1) on conflict (id) do nothing;


-- Word filter. Matching whole words (any case) are masked as f*** in
-- messages, poll options and nicknames. Moderators can edit the list on the
-- admin page; add more with: insert into public.blocked_words values ('word');
create table if not exists public.blocked_words (
  word       text primary key check (word ~ '^[a-z]{2,30}$'),
  created_at timestamptz not null default now()
);
insert into public.blocked_words (word) values
  ('fuck'), ('fucking'), ('fucker'), ('motherfucker'), ('shit'), ('bitch'),
  ('asshole'), ('cunt'), ('dick'), ('bastard'), ('whore'), ('slut')
on conflict (word) do nothing;


-- Room statistics. Messages are deleted after an hour, so counts are kept
-- here: messages per UTC hour, and which guests posted on each day (only to
-- count distinct people; pruned after two days).
create table if not exists public.stats_hourly (
  day      date     not null,
  hour     smallint not null check (hour between 0 and 23),
  messages integer  not null default 0,
  primary key (day, hour)
);
create table if not exists public.stats_posters (
  day     date not null,
  user_id uuid not null,
  primary key (day, user_id)
);


-- Room bot content: trivia questions (answers compared loosely: case,
-- punctuation and a leading "the"/"a" are ignored) and questions of the day.
create table if not exists public.trivia_questions (
  id       serial primary key,
  question text not null unique,
  answers  text[] not null check (cardinality(answers) >= 1)
);
create table if not exists public.trivia_rounds (
  id          bigserial primary key,
  question_id integer not null references public.trivia_questions (id) on delete cascade,
  asked_at    timestamptz not null default now(),
  ends_at     timestamptz not null,
  solved_by   text,
  closed_at   timestamptz
);
create index if not exists trivia_rounds_asked_idx on public.trivia_rounds (asked_at desc);

create table if not exists public.daily_questions (
  id       serial primary key,
  question text not null unique
);

insert into public.trivia_questions (question, answers) values
  ('What is the largest planet in our solar system?', array['jupiter']),
  ('What is the capital of Japan?', array['tokyo']),
  ('How many continents are there?', array['7', 'seven']),
  ('Which ocean is the largest?', array['pacific', 'pacific ocean']),
  ('What is the chemical symbol for gold?', array['au']),
  ('Which planet is known as the Red Planet?', array['mars']),
  ('What is the tallest mountain on Earth?', array['everest', 'mount everest', 'mt everest']),
  ('How many legs does a spider have?', array['8', 'eight']),
  ('What is the smallest prime number?', array['2', 'two']),
  ('Which country has the most people?', array['india']),
  ('What is the longest river in Africa?', array['nile', 'river nile']),
  ('What gas do plants take in from the air?', array['carbon dioxide', 'co2']),
  ('What is the capital of Australia?', array['canberra']),
  ('How many minutes are in a day?', array['1440']),
  ('Which language has the most native speakers?', array['mandarin', 'mandarin chinese', 'chinese']),
  ('What is the hardest natural substance?', array['diamond']),
  ('Which country is home to the kangaroo?', array['australia']),
  ('What is the freezing point of water in Fahrenheit?', array['32', '32f']),
  ('Who painted the Mona Lisa?', array['leonardo da vinci', 'da vinci', 'leonardo']),
  ('What is the largest desert in the world?', array['antarctica', 'antarctic']),
  ('How many players are on a football (soccer) team on the field?', array['11', 'eleven']),
  ('What is the currency of Japan?', array['yen', 'japanese yen']),
  ('Which element has the symbol O?', array['oxygen']),
  ('What is the capital of Canada?', array['ottawa']),
  ('How many sides does a hexagon have?', array['6', 'six']),
  ('Which planet has the most famous rings?', array['saturn']),
  ('What is the fastest land animal?', array['cheetah']),
  ('In which country are the pyramids of Giza?', array['egypt']),
  ('What is 12 x 12?', array['144']),
  ('Which bird is a symbol of peace?', array['dove']),
  ('What is the largest mammal?', array['blue whale', 'whale']),
  ('What is the capital of Brazil?', array['brasilia', 'brasília']),
  ('How many hours are in a week?', array['168']),
  ('Which instrument has 88 keys?', array['piano']),
  ('What is the main language of Brazil?', array['portuguese']),
  ('Which country gifted the Statue of Liberty to the USA?', array['france']),
  ('What is the boiling point of water in Celsius?', array['100', '100c']),
  ('How many strings does a standard guitar have?', array['6', 'six']),
  ('What is the closest star to Earth?', array['sun', 'the sun']),
  ('Which continent is Kenya in?', array['africa'])
on conflict (question) do nothing;

insert into public.daily_questions (question) values
  ('Where in the world are you chatting from today? 🌍'),
  ('What''s the best thing that happened to you this week?'),
  ('What song is stuck in your head right now? 🎵'),
  ('What''s the weather like where you are?'),
  ('If you could visit any country tomorrow, where would you go?'),
  ('What''s your favourite food from your country?'),
  ('What are you learning at the moment?'),
  ('Tea or coffee? ☕'),
  ('What''s a movie everyone should watch at least once?'),
  ('What time is it where you are, and what are you up to?'),
  ('What''s one word in your language that you love?'),
  ('Morning person or night owl? 🦉'),
  ('What''s the last thing that made you laugh?'),
  ('What''s a small habit that makes your day better?'),
  ('Which game are you playing these days? 🎮'),
  ('What''s your dream job?'),
  ('Cats or dogs? 🐱🐶'),
  ('What would you do with an extra hour every day?'),
  ('What''s a festival or holiday from your country we should know about?'),
  ('Share a fun fact about where you live!'),
  ('What''s on your playlist this week?'),
  ('Beach or mountains? 🏖️⛰️'),
  ('What''s a skill you''d love to master?'),
  ('What''s the best advice you''ve ever been given?'),
  ('What''s your comfort food?'),
  ('Which app do you use the most?'),
  ('What''s something you''re looking forward to?'),
  ('If you could talk to anyone in history, who would it be?'),
  ('What''s your favourite season and why?'),
  ('Say hello in your language! 👋')
on conflict (question) do nothing;


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


-- True when a guest is currently banned.
create or replace function public.gc_is_banned(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.banned_users b
    where b.user_id = p_uid and (b.banned_until is null or b.banned_until > now())
  );
$$;

revoke all on function public.gc_is_banned(uuid) from public, anon, authenticated;


-- Shared rate limiter for small actions (reactions, votes). Serialised per
-- guest so parallel requests can't all slip under the limit.
create or replace function public.gc_rate_check(p_uid uuid, p_action text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('gc_act:' || p_uid::text, 0));
  select count(*) into v_recent
  from public.rate_events e
  where e.user_id = p_uid
    and e.created_at > now() - make_interval(secs => public.gc_setting('action_window_seconds'));
  if v_recent >= public.gc_setting('action_limit') then
    raise exception 'RATE_LIMITED' using errcode = 'P0001',
      hint = 'Slow down a little and try again.';
  end if;
  insert into public.rate_events (user_id, action) values (p_uid, p_action);
end;
$$;

revoke all on function public.gc_rate_check(uuid, text) from public, anon, authenticated;


-- Mask blocked words: "fuck" -> "f***" (whole words, any case).
create or replace function public.gc_mask_words(p_text text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_text text := p_text;
  v_word text;
begin
  if v_text is null or v_text = '' then
    return v_text;
  end if;
  for v_word in select b.word from public.blocked_words b loop
    v_text := regexp_replace(
      v_text,
      '\m(' || left(v_word, 1) || ')' || substr(v_word, 2) || '\M',
      '\1' || repeat('*', length(v_word) - 1),
      'gi');
  end loop;
  return v_text;
end;
$$;

-- True if a nickname contains a blocked word anywhere (NiceShitFox_1234).
create or replace function public.gc_name_is_blocked(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select lower(p_name) like 'globalbot%'
      or exists (select 1 from public.blocked_words b where strpos(lower(p_name), b.word) > 0);
$$;

-- Stickers the page ships in /stickers (<id>.svg).
create or replace function public.gc_sticker_ids()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['hi', 'gg', 'lol', 'love', 'gn', 'brb', 'wow', 'thanks'];
$$;

-- Loose comparison key for trivia answers: case, punctuation, extra spaces
-- and a leading "the" / "a" / "an" don't matter.
create or replace function public.gc_answer_key(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
           btrim(regexp_replace(
             regexp_replace(lower(coalesce(p_text, '')), '[^[:alnum:][:space:]]', '', 'g'),
             '\s+', ' ', 'g')),
           '^(the|a|an) ', '');
$$;

-- Chat commands, run on the server so results can't be faked:
--   /roll [N|dN]  dice (default 6 sides, 2–1000)
--   /flip         coin
--   /8ball [q]    magic 8-ball
-- Anything else starting with "/" is sent as normal text.
create or replace function public.gc_run_command(p_text text, out content text, out command text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cmd     text;
  v_arg     text;
  v_sides   integer := 6;
  v_answers text[] := array[
    'It is certain.', 'Without a doubt.', 'You may rely on it.', 'Yes, definitely.',
    'As I see it, yes.', 'Most likely.', 'Outlook good.', 'Signs point to yes.',
    'Reply hazy, try again.', 'Ask again later.', 'Better not tell you now.',
    'Cannot predict now.', 'Concentrate and ask again.', 'Don''t count on it.',
    'My reply is no.', 'My sources say no.', 'Outlook not so good.', 'Very doubtful.'];
begin
  content := p_text;
  command := null;
  v_cmd := lower(substring(p_text from '^/([A-Za-z0-9]+)'));
  if v_cmd is null then
    return;
  end if;
  v_arg := btrim(coalesce(substring(p_text from '^/[A-Za-z0-9]+\s*(.*)$'), ''));

  if v_cmd = 'roll' then
    if v_arg ~* '^d?[0-9]{1,4}$' then
      v_sides := regexp_replace(v_arg, '\D', '', 'g')::integer;
    end if;
    if v_sides not between 2 and 1000 then
      v_sides := 6;
    end if;
    content := '🎲 rolled ' || (1 + floor(random() * v_sides))::integer || ' (1–' || v_sides || ')';
    command := 'roll';
  elsif v_cmd = 'flip' then
    content := '🪙 flipped ' || case when random() < 0.5 then 'heads' else 'tails' end;
    command := 'flip';
  elsif v_cmd = '8ball' then
    content := '🎱 ' || case when v_arg <> '' then left(v_arg, 400) || ' → ' else '' end
               || v_answers[1 + floor(random() * cardinality(v_answers))::integer];
    command := '8ball';
  end if;
end;
$$;

revoke all on function public.gc_mask_words(text)        from public, anon, authenticated;
revoke all on function public.gc_name_is_blocked(text)   from public, anon, authenticated;
revoke all on function public.gc_run_command(text)       from public, anon, authenticated;


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
  v_options    text[];
  v_option     text;
  v_slow       integer;
begin
  -- 0. Room-bot rows. Only gc_bot_post() can set is_bot (guests have no
  --    INSERT grant on that column), so these skip the guest rules.
  if new.is_bot then
    new.user_id      := null;
    new.username     := 'GlobalBot_0000';
    new.created_at   := now();
    new.expires_at   := now() + interval '1 hour';
    new.kind         := 'text';
    new.content      := left(public.gc_normalize_text(new.content), 500);
    new.image_path   := null;
    new.poll_options := null;
    new.sticker      := null;
    new.country      := null;
    new.gender       := null;
    new.command      := null;
    new.edited_at    := null;
    new.hidden       := false;
    return new;
  end if;

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

  -- Server-owned fields (also outside the guests' INSERT grant).
  new.command   := null;
  new.edited_at := null;
  new.hidden    := false;
  new.country   := nullif(upper(btrim(coalesce(new.country, ''))), '');
  if new.country !~ '^[A-Z]{2}$' then
    new.country := null;
  end if;
  new.gender := lower(btrim(coalesce(new.gender, '')));
  if new.gender not in ('male', 'female', 'nonbinary') then
    new.gender := null;
  end if;

  -- 4. Content: normalise, then validate.
  new.content := public.gc_normalize_text(new.content);
  if char_length(new.content) > public.gc_setting('max_message_length') then
    raise exception 'MESSAGE_TOO_LONG' using errcode = 'P0001',
      hint = 'Messages can be at most 500 characters.';
  end if;

  -- 4b. Message kind. Each kind keeps only the fields that belong to it.
  new.kind := coalesce(new.kind, 'text');
  if new.kind = 'text' then
    new.image_path := null;
    new.poll_options := null;
    new.sticker := null;
    if new.content = '' then
      raise exception 'EMPTY_MESSAGE' using errcode = 'P0001',
        hint = 'Messages cannot be empty.';
    end if;
    -- /roll, /flip, /8ball: the server writes the result.
    select c.content, c.command into new.content, new.command
    from public.gc_run_command(new.content) c;

  elsif new.kind = 'image' then
    -- Caption is optional. The image must be a file this guest uploaded to
    -- their own folder in the private bucket, named <uuid>.<ext>.
    new.poll_options := null;
    new.sticker := null;
    if new.image_path is null
       or new.image_path !~ ('^' || v_uid::text
            || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|webp|gif)$')
       or not exists (
            select 1 from storage.objects o
            where o.bucket_id = 'chat-images'
              and o.name = new.image_path
              and o.owner_id = v_uid::text
          ) then
      raise exception 'INVALID_IMAGE' using errcode = 'P0001',
        hint = 'Upload the image first, then send it.';
    end if;

  elsif new.kind = 'poll' then
    -- The question is `content`; 2–4 distinct, non-empty options.
    new.image_path := null;
    new.sticker := null;
    if new.content = '' or char_length(new.content) > public.gc_setting('max_poll_question') then
      raise exception 'INVALID_POLL' using errcode = 'P0001',
        hint = 'A poll needs a question of up to 200 characters.';
    end if;
    v_options := array[]::text[];
    foreach v_option in array coalesce(new.poll_options, array[]::text[]) loop
      v_option := public.gc_normalize_text(replace(v_option, E'\n', ' '));
      if v_option = '' or char_length(v_option) > public.gc_setting('max_poll_option') then
        raise exception 'INVALID_POLL' using errcode = 'P0001',
          hint = 'Poll options must be 1 to 80 characters.';
      end if;
      v_options := v_options || public.gc_mask_words(v_option);
    end loop;
    if cardinality(v_options) not between 2 and 4
       or (select count(distinct lower(o)) from unnest(v_options) o) <> cardinality(v_options) then
      raise exception 'INVALID_POLL' using errcode = 'P0001',
        hint = 'A poll needs 2 to 4 different options.';
    end if;
    new.poll_options := v_options;

  elsif new.kind = 'sticker' then
    new.image_path := null;
    new.poll_options := null;
    new.content := '';
    if new.sticker is null or not (new.sticker = any (public.gc_sticker_ids())) then
      raise exception 'INVALID_STICKER' using errcode = 'P0001';
    end if;

  elsif new.kind = 'voice' then
    -- A voice note this guest uploaded to their own folder (same bucket and
    -- rules as images).
    new.poll_options := null;
    new.sticker := null;
    new.content := '';
    if new.image_path is null
       or new.image_path !~ ('^' || v_uid::text
            || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webm|ogg|m4a)$')
       or not exists (
            select 1 from storage.objects o
            where o.bucket_id = 'chat-images'
              and o.name = new.image_path
              and o.owner_id = v_uid::text
          ) then
      raise exception 'INVALID_VOICE' using errcode = 'P0001',
        hint = 'Record and upload the voice note first, then send it.';
    end if;

  else
    raise exception 'INVALID_KIND' using errcode = 'P0001';
  end if;

  -- 4b2. Word filter (command results are server text and stay as they are,
  --      except an 8-ball question, which is masked like any text).
  new.content := public.gc_mask_words(new.content);

  -- 4c. Replies must point at a message that is still visible.
  if new.reply_to is not null and not exists (
    select 1 from public.messages m
    where m.id = new.reply_to and m.expires_at > now() and not m.hidden
  ) then
    raise exception 'REPLY_NOT_FOUND' using errcode = 'P0001',
      hint = 'The message you replied to has expired or was removed.';
  end if;

  -- 5. Username format (also a CHECK constraint, but this gives a clear error).
  if new.username is null or new.username !~ '^[A-Za-z]{2,20}_[0-9]{4}$'
     or public.gc_name_is_blocked(new.username) then
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

  -- 7b. Slow mode (set by moderators): one message per N seconds each.
  select r.slow_mode_seconds into v_slow from public.room_state r where r.id = 1;
  if coalesce(v_slow, 0) > 0 and exists (
    select 1 from public.messages m
    where m.user_id = v_uid and m.created_at > now() - make_interval(secs => v_slow)
  ) then
    raise exception 'SLOW_MODE' using errcode = 'P0001',
      hint = format('Slow mode is on: one message every %s seconds.', v_slow);
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
  --    (Empty captions, stickers, voice notes and command results are exempt.)
  if new.content <> '' and new.command is null and exists (
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

-- Messages are immutable once sent, with two exceptions: when a message is
-- deleted, replies to it have reply_to cleared by the foreign key (ON DELETE
-- SET NULL); and the trusted functions in section 10 (edit, hide/unhide).
create or replace function public.messages_block_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.reply_to is not null and new.reply_to is null
     and (to_jsonb(new) - 'reply_to') = (to_jsonb(old) - 'reply_to') then
    return new;
  end if;
  -- Edits, hiding and unhiding go through SECURITY DEFINER functions in
  -- section 10, which set this transaction-local flag first. Guests have no
  -- UPDATE grant, so they can never reach this trigger themselves.
  if current_setting('gc.trusted_update', true) = 'on' then
    return new;
  end if;
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
          'id',           new.id,
          'username',     new.username,
          'content',      new.content,
          'created_at',   new.created_at,
          'expires_at',   new.expires_at,
          'kind',         new.kind,
          'reply_to',     new.reply_to,
          'image_path',   new.image_path,
          'poll_options', new.poll_options,
          'is_bot',       new.is_bot,
          'command',      new.command,
          'sticker',      new.sticker,
          'country',      new.country,
          'gender',       new.gender,
          'edited_at',    new.edited_at
        ),
        'message_created',
        'room:global',
        true
      );
    elsif tg_op = 'DELETE' and old.expires_at > now() then
      -- Deleted before expiry = removed by a moderator or by its author.
      -- Tell clients to hide it.
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
  new.reported_image_path := null;
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
    new.reported_image_path := v_msg.image_path;
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
revoke all on public.reactions    from anon, authenticated;
revoke all on public.poll_votes   from anon, authenticated;
revoke all on public.rate_events  from anon, authenticated;
revoke all on public.room_state       from anon, authenticated;
revoke all on public.stats_hourly     from anon, authenticated;
revoke all on public.stats_posters    from anon, authenticated;
revoke all on public.trivia_questions from anon, authenticated;
revoke all on public.trivia_rounds    from anon, authenticated;
revoke all on public.daily_questions  from anon, authenticated;
revoke all on public.blocked_words    from anon, authenticated;
-- Moderators manage the word filter from admin.html (RLS below).
grant select, insert, delete on public.blocked_words to authenticated;

-- Guests read the public columns only — user_id is never readable via the API.
grant select (id, username, content, created_at, expires_at,
              kind, reply_to, image_path, poll_options,
              is_bot, command, sticker, country, edited_at, hidden, gender)
  on public.messages to authenticated;
-- Guests supply only these; the trigger validates them and sets the rest.
grant insert (username, content, kind, reply_to, image_path, poll_options,
              sticker, country, gender)
  on public.messages to authenticated;
-- Deletion is granted but RLS limits it to moderators.
grant delete on public.messages to authenticated;

-- Reports: guests insert three fields; moderators read/update/delete via RLS.
grant insert (message_id, reason, details) on public.reports to authenticated;
grant select, delete on public.reports to authenticated;
grant update (status, resolved_by, resolved_at, resolution_note)
  on public.reports to authenticated;

-- Bans: moderators only (via RLS).
grant select, insert, update, delete on public.banned_users to authenticated;
-- moderators / guest_names / reactions / poll_votes / rate_events: no direct
-- client access at all; reactions and votes go through the gc_* functions.


-- -----------------------------------------------------------------------------
-- 7. Row Level Security
-- -----------------------------------------------------------------------------
alter table public.messages     enable row level security;
alter table public.reports      enable row level security;
alter table public.guest_names  enable row level security;
alter table public.banned_users enable row level security;
alter table public.moderators   enable row level security;
alter table public.reactions    enable row level security;
alter table public.poll_votes   enable row level security;
alter table public.rate_events  enable row level security;
alter table public.room_state       enable row level security;
alter table public.stats_hourly     enable row level security;
alter table public.stats_posters    enable row level security;
alter table public.trivia_questions enable row level security;
alter table public.trivia_rounds    enable row level security;
alter table public.daily_questions  enable row level security;
alter table public.blocked_words    enable row level security;

drop policy if exists "blocked words: moderators manage" on public.blocked_words;
create policy "blocked words: moderators manage"
  on public.blocked_words for all
  to authenticated
  using ((select public.is_moderator()))
  with check ((select public.is_moderator()));

-- messages ------------------------------------------------------------------
drop policy if exists "messages: read unexpired"          on public.messages;
drop policy if exists "messages: guests insert own"       on public.messages;
drop policy if exists "messages: moderators delete"       on public.messages;

-- Messages hidden after reports stay visible to moderators only.
create policy "messages: read unexpired"
  on public.messages for select
  to authenticated
  using (expires_at > now() and (not hidden or (select public.is_moderator())));

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

-- guest_names, moderators, reactions, poll_votes, rate_events: RLS on, no
-- policies → invisible to clients.


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
-- 9. Interactive features: reactions, polls, delete-own, images
-- -----------------------------------------------------------------------------
-- Guests never touch public.reactions / public.poll_votes directly. These
-- SECURITY DEFINER functions check the caller, rate-limit, change the data,
-- and broadcast the new totals to the room. Who reacted or voted is never
-- returned; only counts plus the caller's own choices.

-- Reaction totals for one message as {"❤️": 3, "👍": 1}.
create or replace function public.gc_reaction_counts(p_message_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(emoji, n), '{}'::jsonb)
  from (
    select r.emoji, count(*) as n
    from public.reactions r
    where r.message_id = p_message_id
    group by r.emoji
  ) t;
$$;

-- Vote totals for one poll as an array aligned with poll_options.
create or replace function public.gc_poll_counts(p_message_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(coalesce(v.n, 0) order by i), '[]'::jsonb)
  from public.messages m
  cross join lateral generate_series(0, coalesce(cardinality(m.poll_options), 0) - 1) as i
  left join (
    select pv.option_idx, count(*) as n
    from public.poll_votes pv
    where pv.message_id = p_message_id
    group by pv.option_idx
  ) v on v.option_idx = i
  where m.id = p_message_id;
$$;

revoke all on function public.gc_reaction_counts(uuid) from public, anon, authenticated;
revoke all on function public.gc_poll_counts(uuid)     from public, anon, authenticated;


-- Toggle one emoji reaction on a live message.
-- Returns {"reactions": {...}, "mine": ["❤️", ...]}.
create or replace function public.gc_toggle_reaction(p_message_id uuid, p_emoji text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_counts jsonb;
  v_mine   jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if public.gc_is_banned(v_uid) then
    raise exception 'BANNED' using errcode = 'P0001';
  end if;
  if p_emoji is null or p_emoji not in ('❤️', '👍', '😂', '😮', '😢', '🔥') then
    raise exception 'INVALID_REACTION' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.messages m
                 where m.id = p_message_id and m.expires_at > now() and not m.hidden) then
    raise exception 'MESSAGE_NOT_FOUND' using errcode = 'P0001',
      hint = 'That message has expired or was removed.';
  end if;

  perform public.gc_rate_check(v_uid, 'reaction');

  delete from public.reactions r
  where r.message_id = p_message_id and r.user_id = v_uid and r.emoji = p_emoji;
  if not found then
    insert into public.reactions (message_id, user_id, emoji) values (p_message_id, v_uid, p_emoji);
  end if;

  v_counts := public.gc_reaction_counts(p_message_id);
  select coalesce(jsonb_agg(r.emoji), '[]'::jsonb) into v_mine
  from public.reactions r where r.message_id = p_message_id and r.user_id = v_uid;

  begin
    perform realtime.send(jsonb_build_object('id', p_message_id, 'reactions', v_counts),
                          'message_reactions', 'room:global', true);
  exception when others then
    raise warning 'GlobalChat broadcast failed: %', sqlerrm;
  end;

  return jsonb_build_object('reactions', v_counts, 'mine', v_mine);
end;
$$;


-- Vote in a live poll. Voting for your current choice again removes the
-- vote. Returns {"counts": [..], "my_vote": 0..3 | null}.
create or replace function public.gc_vote(p_message_id uuid, p_option integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_msg     public.messages%rowtype;
  v_current smallint;
  v_mine    smallint;
  v_counts  jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if public.gc_is_banned(v_uid) then
    raise exception 'BANNED' using errcode = 'P0001';
  end if;
  select * into v_msg from public.messages m
  where m.id = p_message_id and m.expires_at > now() and m.kind = 'poll' and not m.hidden;
  if not found then
    raise exception 'MESSAGE_NOT_FOUND' using errcode = 'P0001',
      hint = 'That poll has expired or was removed.';
  end if;
  if p_option is null or p_option < 0 or p_option >= cardinality(v_msg.poll_options) then
    raise exception 'INVALID_OPTION' using errcode = 'P0001';
  end if;

  perform public.gc_rate_check(v_uid, 'vote');

  select pv.option_idx into v_current from public.poll_votes pv
  where pv.message_id = p_message_id and pv.user_id = v_uid;
  if v_current = p_option then
    delete from public.poll_votes pv where pv.message_id = p_message_id and pv.user_id = v_uid;
    v_mine := null;
  else
    insert into public.poll_votes (message_id, user_id, option_idx)
    values (p_message_id, v_uid, p_option)
    on conflict (message_id, user_id)
    do update set option_idx = excluded.option_idx, created_at = now();
    v_mine := p_option;
  end if;

  v_counts := public.gc_poll_counts(p_message_id);
  begin
    perform realtime.send(jsonb_build_object('id', p_message_id, 'counts', v_counts),
                          'poll_votes', 'room:global', true);
  exception when others then
    raise warning 'GlobalChat broadcast failed: %', sqlerrm;
  end;

  return jsonb_build_object('counts', v_counts, 'my_vote', v_mine);
end;
$$;


-- Reactions + poll totals (and the caller's own choices) for messages the
-- client has on screen. Used after loading history.
-- Returns {"<id>": {"reactions": {..}, "mine": [..], "poll": [..], "my_vote": n}}.
create or replace function public.gc_message_extras(p_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_out jsonb := '{}'::jsonb;
  v_msg record;
  v_entry jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if cardinality(p_ids) > 500 then
    raise exception 'TOO_MANY_IDS' using errcode = 'P0001';
  end if;

  for v_msg in
    select m.id, m.kind from public.messages m
    where m.id = any (p_ids) and m.expires_at > now()
  loop
    v_entry := '{}'::jsonb;
    if exists (select 1 from public.reactions r where r.message_id = v_msg.id) then
      v_entry := v_entry || jsonb_build_object(
        'reactions', public.gc_reaction_counts(v_msg.id),
        'mine', (select coalesce(jsonb_agg(r.emoji), '[]'::jsonb) from public.reactions r
                 where r.message_id = v_msg.id and r.user_id = v_uid));
    end if;
    if v_msg.kind = 'poll' then
      v_entry := v_entry || jsonb_build_object(
        'poll', public.gc_poll_counts(v_msg.id),
        'my_vote', (select pv.option_idx from public.poll_votes pv
                    where pv.message_id = v_msg.id and pv.user_id = v_uid));
    end if;
    if v_entry <> '{}'::jsonb then
      v_out := v_out || jsonb_build_object(v_msg.id::text, v_entry);
    end if;
  end loop;
  return v_out;
end;
$$;


-- Delete your own message (any time before it expires). The broadcast
-- trigger tells everyone to hide it. Reports already filed keep their
-- evidence snapshot.
create or replace function public.gc_delete_my_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  delete from public.messages m
  where m.id = p_message_id and m.user_id = v_uid and m.expires_at > now();
  if not found then
    raise exception 'MESSAGE_NOT_FOUND' using errcode = 'P0001',
      hint = 'That message has already expired or was removed.';
  end if;
end;
$$;

revoke all on function public.gc_toggle_reaction(uuid, text)  from public, anon;
revoke all on function public.gc_vote(uuid, integer)           from public, anon;
revoke all on function public.gc_message_extras(uuid[])        from public, anon;
revoke all on function public.gc_delete_my_message(uuid)       from public, anon;
grant execute on function public.gc_toggle_reaction(uuid, text) to authenticated;
grant execute on function public.gc_vote(uuid, integer)         to authenticated;
grant execute on function public.gc_message_extras(uuid[])      to authenticated;
grant execute on function public.gc_delete_my_message(uuid)     to authenticated;


-- Images ----------------------------------------------------------------------
-- Files live in a PRIVATE bucket, "chat-images", in a folder per guest:
--   <user id>/<random uuid>.<png|jpg|webp|gif>   (5 MB max)
-- Guests can upload to their own folder (rate-limited) and can view a file
-- only while a live message points at it; the page fetches short-lived
-- signed URLs. Files of expired or deleted messages are removed by the
-- "cleanup-images" Edge Function (see README → Image cleanup), because
-- Supabase doesn't allow deleting storage files from SQL.

-- Upload rate limit + ban check, used by the storage INSERT policy.
create or replace function public.gc_upload_allowed()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
     and not public.gc_is_banned(auth.uid())
     and (
       select count(*) from storage.objects o
       where o.bucket_id = 'chat-images'
         and o.owner_id = auth.uid()::text
         and o.created_at > now() - make_interval(mins => public.gc_setting('upload_window_minutes'))
     ) < public.gc_setting('upload_limit');
$$;

-- A file is viewable only while a live message references it.
create or replace function public.gc_image_visible(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.messages m
    where m.image_path = p_name and m.expires_at > now() and not m.hidden
  );
$$;

-- For the cleanup Edge Function (service role only): files older than five
-- minutes that no live message uses, except evidence for open reports.
create or replace function public.gc_dead_images()
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select o.name
  from storage.objects o
  where o.bucket_id = 'chat-images'
    and o.created_at < now() - interval '5 minutes'
    and not exists (
      select 1 from public.messages m
      where m.image_path = o.name and m.expires_at > now()
    )
    and not exists (
      select 1 from public.reports r
      where r.reported_image_path = o.name and r.status = 'open'
    )
  limit 1000;
$$;

revoke all on function public.gc_upload_allowed()      from public, anon;
revoke all on function public.gc_image_visible(text)   from public, anon;
revoke all on function public.gc_dead_images()         from public, anon, authenticated;
grant execute on function public.gc_upload_allowed()    to authenticated;
grant execute on function public.gc_image_visible(text) to authenticated;
do $do$
begin
  grant execute on function public.gc_dead_images() to service_role;
exception when undefined_object then
  raise notice 'GlobalChat: role service_role not found; skipping grant.';
end;
$do$;

-- Bucket + storage policies. Guarded so the rest of the file still applies
-- if Storage isn't available.
do $do$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('chat-images', 'chat-images', false, 5242880,
          array['image/png', 'image/jpeg', 'image/webp', 'image/gif',
                'audio/webm', 'audio/ogg', 'audio/mp4'])
  on conflict (id) do update
    set public = false,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

  drop policy if exists "chat-images: guests upload own" on storage.objects;
  drop policy if exists "chat-images: read while live"   on storage.objects;
  drop policy if exists "chat-images: owners delete"     on storage.objects;

  create policy "chat-images: guests upload own"
    on storage.objects for insert
    to authenticated
    with check (
      bucket_id = 'chat-images'
      and (storage.foldername(name))[1] = (select auth.uid())::text
      and name ~ '^[0-9a-f-]{36}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|webp|gif|webm|ogg|m4a)$'
      and (select public.gc_upload_allowed())
    );

  create policy "chat-images: read while live"
    on storage.objects for select
    to authenticated
    using (bucket_id = 'chat-images' and public.gc_image_visible(name));

  -- Lets the page remove an upload whose message failed to send.
  create policy "chat-images: owners delete"
    on storage.objects for delete
    to authenticated
    using (bucket_id = 'chat-images' and owner_id = (select auth.uid())::text);

  raise notice 'GlobalChat: storage bucket "chat-images" and policies ready.';
exception when others then
  raise notice 'GlobalChat: storage setup skipped (%). Image messages need Supabase Storage.', sqlerrm;
end;
$do$;


-- -----------------------------------------------------------------------------
-- 10. Community features
-- -----------------------------------------------------------------------------

-- Post a message as the room bot. Owner-only: used by triggers and cron.
create or replace function public.gc_bot_post(p_content text, p_reply_to uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.messages (username, content, is_bot, reply_to)
  values ('GlobalBot_0000', p_content, true, p_reply_to)
  returning id into v_id;
  return v_id;
end;
$$;

-- Today's question of the day (UTC day), rotating through the list.
create or replace function public.gc_daily_question_text()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select q.question
  from public.daily_questions q
  order by q.id
  offset (select (extract(doy from (now() at time zone 'utc'))::integer)
                 % greatest(1, (select count(*) from public.daily_questions)::integer))
  limit 1;
$$;

-- Cron: post the question of the day.
create or replace function public.gc_post_daily_question()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q text := public.gc_daily_question_text();
begin
  if v_q is not null then
    perform public.gc_bot_post('☀️ Question of the day: ' || v_q);
  end if;
end;
$$;

-- Cron (every 5 min): close expired trivia rounds and ask a new question at
-- most every `trivia_every_minutes`, only while people are actually posting.
create or replace function public.gc_trivia_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round  public.trivia_rounds%rowtype;
  v_q      public.trivia_questions%rowtype;
  v_answer text;
begin
  perform pg_advisory_xact_lock(hashtextextended('gc_trivia', 0));

  for v_round in
    select * from public.trivia_rounds r
    where r.closed_at is null and r.ends_at <= now()
  loop
    select q.answers[1] into v_answer from public.trivia_questions q where q.id = v_round.question_id;
    update public.trivia_rounds set closed_at = now() where id = v_round.id;
    perform public.gc_bot_post('⏰ Time''s up! The answer was: ' || initcap(v_answer));
  end loop;

  if exists (select 1 from public.trivia_rounds r where r.closed_at is null) then
    return;
  end if;
  if exists (select 1 from public.trivia_rounds r
             where r.asked_at > now() - make_interval(mins => public.gc_setting('trivia_every_minutes') - 1)) then
    return;
  end if;
  if not exists (select 1 from public.messages m
                 where not m.is_bot
                   and m.created_at > now() - make_interval(mins => public.gc_setting('trivia_quiet_minutes'))) then
    return;   -- nobody around: don't talk to an empty room
  end if;

  select * into v_q from public.trivia_questions q
  where not exists (select 1 from public.trivia_rounds r
                    where r.question_id = q.id and r.asked_at > now() - interval '1 day')
  order by random() limit 1;
  if not found then
    select * into v_q from public.trivia_questions q order by random() limit 1;
  end if;
  if not found then
    return;
  end if;

  insert into public.trivia_rounds (question_id, ends_at)
  values (v_q.id, now() + make_interval(mins => public.gc_setting('trivia_answer_minutes')));
  perform public.gc_bot_post('🧠 Trivia time! ' || v_q.question
    || ' First correct answer in the next ' || public.gc_setting('trivia_answer_minutes') || ' minutes wins.');
end;
$$;

-- After each guest message: room stats, and trivia answer checking.
create or replace function public.messages_after_insert_community()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day    date := (new.created_at at time zone 'utc')::date;
  v_round  public.trivia_rounds%rowtype;
  v_q      public.trivia_questions%rowtype;
  v_key    text;
begin
  if new.is_bot then
    return null;
  end if;

  insert into public.stats_hourly (day, hour, messages)
  values (v_day, extract(hour from (new.created_at at time zone 'utc'))::smallint, 1)
  on conflict (day, hour) do update set messages = public.stats_hourly.messages + 1;
  insert into public.stats_posters (day, user_id) values (v_day, new.user_id)
  on conflict do nothing;

  if new.kind = 'text' and new.command is null then
    select * into v_round from public.trivia_rounds r
    where r.closed_at is null and r.ends_at > now()
    order by r.asked_at desc limit 1
    for update skip locked;
    if found then
      select * into v_q from public.trivia_questions q where q.id = v_round.question_id;
      v_key := public.gc_answer_key(new.content);
      if exists (select 1 from unnest(v_q.answers) a where public.gc_answer_key(a) = v_key) then
        update public.trivia_rounds
          set solved_by = new.username, closed_at = now()
          where id = v_round.id;
        perform public.gc_bot_post('🎉 ' || new.username || ' got it! The answer was: '
                                   || initcap(v_q.answers[1]), new.id);
      end if;
    end if;
  end if;
  return null;
exception when others then
  -- Stats and trivia must never block a chat message.
  raise warning 'GlobalChat community trigger failed: %', sqlerrm;
  return null;
end;
$$;

drop trigger if exists messages_after_insert_community on public.messages;
create trigger messages_after_insert_community
  after insert on public.messages
  for each row execute function public.messages_after_insert_community();

-- Room stats for the sidebar.
create or replace function public.gc_room_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with today as (select (now() at time zone 'utc')::date as d)
  select jsonb_build_object(
    'today_messages', coalesce((select sum(h.messages) from public.stats_hourly h, today where h.day = today.d), 0),
    'today_people',   (select count(*) from public.stats_posters p, today where p.day = today.d),
    'week_messages',  coalesce((select sum(h.messages) from public.stats_hourly h, today where h.day > today.d - 7), 0),
    'busiest_hour_utc', (select h.hour from public.stats_hourly h, today
                         where h.day > today.d - 7
                         group by h.hour order by sum(h.messages) desc, h.hour limit 1)
  );
$$;

-- Everything the page needs about the room besides messages.
create or replace function public.gc_room_state()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'slow_mode_seconds', r.slow_mode_seconds,
    'pinned', (select jsonb_build_object(
                 'id', m.id, 'username', m.username, 'content', m.content, 'kind', m.kind,
                 'is_bot', m.is_bot, 'created_at', m.created_at, 'expires_at', m.expires_at)
               from public.messages m
               where m.id = r.pinned_message_id and m.expires_at > now() and not m.hidden),
    'daily_question', public.gc_daily_question_text(),
    'stats', public.gc_room_stats()
  )
  from public.room_state r where r.id = 1;
$$;

create or replace function public.gc_broadcast_room_state()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(public.gc_room_state(), 'room_state', 'room:global', true);
exception when others then
  raise warning 'GlobalChat broadcast failed: %', sqlerrm;
end;
$$;

-- Edit your own text message within `edit_window_seconds` of sending it.
create or replace function public.gc_edit_message(p_message_id uuid, p_content text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_msg  public.messages%rowtype;
  v_text text := public.gc_normalize_text(p_content);
  v_at   timestamptz := now();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if public.gc_is_banned(v_uid) then
    raise exception 'BANNED' using errcode = 'P0001';
  end if;
  select * into v_msg from public.messages m
  where m.id = p_message_id and m.user_id = v_uid and m.expires_at > now() and not m.hidden;
  if not found then
    raise exception 'MESSAGE_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_msg.kind <> 'text' or v_msg.command is not null then
    raise exception 'NOT_EDITABLE' using errcode = 'P0001',
      hint = 'Only text messages can be edited.';
  end if;
  if v_msg.created_at < now() - make_interval(secs => public.gc_setting('edit_window_seconds')) then
    raise exception 'EDIT_WINDOW_PASSED' using errcode = 'P0001',
      hint = 'Messages can be edited for 2 minutes after sending.';
  end if;
  if v_text = '' then
    raise exception 'EMPTY_MESSAGE' using errcode = 'P0001';
  end if;
  if char_length(v_text) > public.gc_setting('max_message_length') then
    raise exception 'MESSAGE_TOO_LONG' using errcode = 'P0001';
  end if;
  perform public.gc_rate_check(v_uid, 'edit');
  v_text := public.gc_mask_words(v_text);

  perform set_config('gc.trusted_update', 'on', true);
  update public.messages set content = v_text, edited_at = v_at where id = p_message_id;
  perform set_config('gc.trusted_update', 'off', true);

  begin
    perform realtime.send(jsonb_build_object('id', p_message_id, 'content', v_text, 'edited_at', v_at),
                          'message_edited', 'room:global', true);
  exception when others then
    raise warning 'GlobalChat broadcast failed: %', sqlerrm;
  end;
  return jsonb_build_object('content', v_text, 'edited_at', v_at);
end;
$$;

-- Choose your own nickname (Word_1234 format). Future messages use it;
-- messages already sent keep the old name.
create or replace function public.gc_rename(p_username text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_current public.guest_names%rowtype;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if p_username is null or p_username !~ '^[A-Za-z]{2,20}_[0-9]{4}$'
     or public.gc_name_is_blocked(p_username) then
    raise exception 'INVALID_USERNAME' using errcode = 'P0001',
      hint = 'Use 2–20 letters; we add 4 digits.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('gc_msg:' || v_uid::text, 0));
  select * into v_current from public.guest_names g where g.user_id = v_uid;
  if found then
    if v_current.username = p_username then
      return p_username;
    end if;
  end if;
  -- Cooldown counts renames only (claiming a name by posting doesn't).
  if exists (select 1 from public.rate_events e
             where e.user_id = v_uid and e.action = 'rename'
               and e.created_at > now() - make_interval(secs => public.gc_setting('rename_cooldown_seconds'))) then
    raise exception 'RATE_LIMITED' using errcode = 'P0001',
      hint = 'You changed your name a moment ago. Try again in a few seconds.';
  end if;
  insert into public.rate_events (user_id, action) values (v_uid, 'rename');
  begin
    insert into public.guest_names (user_id, username) values (v_uid, p_username)
    on conflict (user_id) do update
      set username = excluded.username, claimed_at = now(), last_used_at = now();
  exception when unique_violation then
    raise exception 'USERNAME_TAKEN' using errcode = 'P0001',
      hint = 'Someone is using that name. Try other digits.';
  end;
  return p_username;
end;
$$;

-- Hide a message once `auto_hide_reports` different guests have reported it
-- (open reports). Moderators can unhide it on the admin page.
create or replace function public.reports_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.message_id is null then
    return null;
  end if;
  if (select count(distinct r.reporter_id) from public.reports r
      where r.message_id = new.message_id and r.status = 'open')
     >= public.gc_setting('auto_hide_reports') then
    perform public.gc_set_hidden(new.message_id, true);
  end if;
  return null;
end;
$$;

-- Hide/unhide and tell clients (owner-only helper).
create or replace function public.gc_set_hidden(p_message_id uuid, p_hidden boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_msg public.messages%rowtype;
begin
  perform set_config('gc.trusted_update', 'on', true);
  update public.messages set hidden = p_hidden
  where id = p_message_id and hidden is distinct from p_hidden
  returning * into v_msg;
  perform set_config('gc.trusted_update', 'off', true);
  if not found then
    return;
  end if;
  begin
    if p_hidden then
      perform realtime.send(jsonb_build_object('id', p_message_id), 'message_deleted', 'room:global', true);
    elsif v_msg.expires_at > now() then
      perform realtime.send(jsonb_build_object(
        'id', v_msg.id, 'username', v_msg.username, 'content', v_msg.content,
        'created_at', v_msg.created_at, 'expires_at', v_msg.expires_at, 'kind', v_msg.kind,
        'reply_to', v_msg.reply_to, 'image_path', v_msg.image_path, 'poll_options', v_msg.poll_options,
        'is_bot', v_msg.is_bot, 'command', v_msg.command, 'sticker', v_msg.sticker,
        'country', v_msg.country, 'gender', v_msg.gender, 'edited_at', v_msg.edited_at),
        'message_created', 'room:global', true);
    end if;
  exception when others then
    raise warning 'GlobalChat broadcast failed: %', sqlerrm;
  end;
end;
$$;

drop trigger if exists reports_after_insert on public.reports;
create trigger reports_after_insert
  after insert on public.reports
  for each row execute function public.reports_after_insert();

-- Moderator actions (admin.html). Each checks is_moderator() itself.
create or replace function public.gc_require_moderator()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_moderator() then
    raise exception 'NOT_MODERATOR' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.gc_mod_pin(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.gc_require_moderator();
  update public.room_state set pinned_message_id = p_message_id, updated_at = now() where id = 1;
  perform public.gc_broadcast_room_state();
end;
$$;

create or replace function public.gc_mod_set_slow_mode(p_seconds integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.gc_require_moderator();
  update public.room_state
    set slow_mode_seconds = least(greatest(coalesce(p_seconds, 0), 0), public.gc_setting('max_slow_mode_seconds')),
        updated_at = now()
    where id = 1;
  perform public.gc_broadcast_room_state();
end;
$$;

create or replace function public.gc_mod_set_hidden(p_message_id uuid, p_hidden boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.gc_require_moderator();
  perform public.gc_set_hidden(p_message_id, p_hidden);
end;
$$;

-- Ban whoever wrote a message (moderators can't read user ids directly).
-- p_minutes null = permanent.
create or replace function public.gc_mod_ban_author(p_message_id uuid, p_minutes integer, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  perform public.gc_require_moderator();
  select coalesce(m.user_id, r.reported_user_id) into v_uid
  from (select p_message_id as id) x
  left join public.messages m on m.id = x.id
  left join public.reports r on r.message_id = x.id
  limit 1;
  if v_uid is null then
    raise exception 'NO_AUTHOR' using errcode = 'P0001',
      hint = 'That message has no guest author (bot) or is gone.';
  end if;
  insert into public.banned_users (user_id, reason, banned_until, created_by)
  values (v_uid, left(p_reason, 500),
          case when p_minutes is null then null else now() + make_interval(mins => p_minutes) end,
          auth.uid())
  on conflict (user_id) do update
    set reason = excluded.reason, banned_until = excluded.banned_until,
        created_at = now(), created_by = excluded.created_by;
end;
$$;

revoke all on function public.gc_bot_post(text, uuid)               from public, anon, authenticated;
revoke all on function public.gc_post_daily_question()              from public, anon, authenticated;
revoke all on function public.gc_trivia_tick()                      from public, anon, authenticated;
revoke all on function public.gc_set_hidden(uuid, boolean)          from public, anon, authenticated;
revoke all on function public.gc_broadcast_room_state()             from public, anon, authenticated;
revoke all on function public.gc_daily_question_text()              from public, anon, authenticated;
revoke all on function public.gc_room_stats()                       from public, anon, authenticated;
revoke all on function public.gc_room_state()                       from public, anon;
revoke all on function public.gc_edit_message(uuid, text)           from public, anon;
revoke all on function public.gc_rename(text)                       from public, anon;
revoke all on function public.gc_require_moderator()                from public, anon;
revoke all on function public.gc_mod_pin(uuid)                      from public, anon;
revoke all on function public.gc_mod_set_slow_mode(integer)         from public, anon;
revoke all on function public.gc_mod_set_hidden(uuid, boolean)      from public, anon;
revoke all on function public.gc_mod_ban_author(uuid, integer, text) from public, anon;
grant execute on function public.gc_room_state()                       to authenticated;
grant execute on function public.gc_edit_message(uuid, text)           to authenticated;
grant execute on function public.gc_rename(text)                       to authenticated;
grant execute on function public.gc_require_moderator()                to authenticated;
grant execute on function public.gc_mod_pin(uuid)                      to authenticated;
grant execute on function public.gc_mod_set_slow_mode(integer)         to authenticated;
grant execute on function public.gc_mod_set_hidden(uuid, boolean)      to authenticated;
grant execute on function public.gc_mod_ban_author(uuid, integer, text) to authenticated;


-- Removed feature: the new-user cooldown. If an earlier run of this file
-- created its helpers, drop them (the trigger and gc_edit_message above no
-- longer call them).
drop function if exists public.gc_new_user_wait(uuid);
drop function if exists public.gc_has_link(text);


-- -----------------------------------------------------------------------------
-- 11. Scheduled cleanup (pg_cron)
-- -----------------------------------------------------------------------------
-- Physically deletes expired messages (their reactions and votes go with them)
-- every 5 minutes and forgets display-name claims that have been idle for a day. If pg_cron is unavailable this block
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
  delete from public.rate_events where created_at < now() - interval '1 hour';
  delete from public.stats_posters where day < (now() at time zone 'utc')::date - 1;
  delete from public.stats_hourly  where day < (now() at time zone 'utc')::date - 35;
  delete from public.trivia_rounds where asked_at < now() - interval '7 days';

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
  perform cron.schedule('globalchat-trivia', '*/5 * * * *', 'select public.gc_trivia_tick();');
  perform cron.schedule('globalchat-daily-question', '3 12 * * *', 'select public.gc_post_daily_question();');
  raise notice 'GlobalChat: pg_cron job "globalchat-cleanup" scheduled every 5 minutes.';
  raise notice 'GlobalChat: room bot jobs scheduled (trivia every 5 min check, question of the day 12:03 UTC).';
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
