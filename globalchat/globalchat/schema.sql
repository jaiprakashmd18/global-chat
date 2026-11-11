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
    when 'bot_chatter_seconds'     then 90    -- bot characters chat after this much silence ...
    when 'bot_awake_minutes'       then 20    -- ... if someone posted or had the page open this recently
    when 'bot_busy_messages'       then 4     -- this many guest messages in 2 min: bots only answer @mentions
    when 'bot_topic_percent'       then 35    -- chance a bot chimes in when its topic comes up
    when 'bot_reply_cooldown_seconds' then 20 -- one bot reply per guest per N s
    when 'bot_greet_minutes'       then 5     -- at most one bot welcome per N min
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


-- Bot characters (section 12): ten clearly labelled, scripted bots that
-- greet newcomers, answer @mentions and keep a quiet room company. Their
-- lines are written in advance (section 12 seeds them); nothing is generated.
--   bot_characters  who they are; `topics` are words that make them chime in
--   bot_lines       kind: greet (newcomer, {name} = @Username), hello (someone
--                   opened the page), chat (quiet room), topic, mention,
--                   crisis (safety reply with helplines)
--   bot_dialogues   short scripted conversations between two or three bots
--   bot_pending     posts waiting for their moment (sent by gc_bot_tick)
--   bot_reply_log   who got which kind of bot reply when (cooldowns)
create table if not exists public.bot_characters (
  id     text primary key check (id ~ '^[a-z]{2,20}$'),
  name   text not null check (char_length(name) between 1 and 30),
  handle text not null unique check (handle ~ '^[A-Za-z]{2,20}$'),
  emoji  text not null,
  topics text[] not null default '{}',
  sort   smallint not null default 0
);
create table if not exists public.bot_lines (
  id           serial primary key,
  bot_id       text not null references public.bot_characters (id) on delete cascade,
  kind         text not null check (kind in ('greet', 'hello', 'chat', 'topic', 'mention', 'crisis')),
  content      text not null check (char_length(content) between 1 and 440),
  last_used_at timestamptz,
  unique (bot_id, content)
);
create table if not exists public.bot_dialogues (
  id           serial primary key,
  title        text not null unique,
  steps        jsonb not null check (jsonb_typeof(steps) = 'array'),   -- [["bot id", "text"], ...]
  last_used_at timestamptz
);
create table if not exists public.bot_pending (
  id         bigserial primary key,
  bot_id     text references public.bot_characters (id) on delete cascade,
  content    text not null,
  reply_to   uuid references public.messages (id) on delete cascade,
  reason     text not null,
  due_at     timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists bot_pending_due_idx on public.bot_pending (due_at);
create table if not exists public.bot_reply_log (
  id      bigserial primary key,
  user_id uuid,
  reason  text not null,
  at      timestamptz not null default now()
);
create index if not exists bot_reply_log_idx on public.bot_reply_log (reason, at desc);

-- Which character posted a bot message (null = the room bot).
alter table public.messages add column if not exists bot_id text
  references public.bot_characters (id) on delete set null;
-- Moderators can switch the characters off on the admin page; bots_seen_at
-- is when someone last had the page open (they only chat while people are around).
alter table public.room_state add column if not exists bots_enabled boolean not null default true;
alter table public.room_state add column if not exists bots_seen_at timestamptz;


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
    new.bot_id       := (select c.id from public.bot_characters c where c.id = new.bot_id);
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
  new.bot_id    := null;
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
          'bot_id',       new.bot_id,
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
revoke all on public.bot_characters   from anon, authenticated;
revoke all on public.bot_lines        from anon, authenticated;
revoke all on public.bot_dialogues    from anon, authenticated;
revoke all on public.bot_pending      from anon, authenticated;
revoke all on public.bot_reply_log    from anon, authenticated;
-- Moderators manage the word filter from admin.html (RLS below).
grant select, insert, delete on public.blocked_words to authenticated;

-- Guests read the public columns only — user_id is never readable via the API.
grant select (id, username, content, created_at, expires_at,
              kind, reply_to, image_path, poll_options,
              is_bot, command, sticker, country, edited_at, hidden, gender, bot_id)
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
-- moderators / guest_names / reactions / poll_votes / rate_events / bot_*:
-- no direct client access at all; reactions and votes go through the gc_*
-- functions.


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
alter table public.bot_characters   enable row level security;
alter table public.bot_lines        enable row level security;
alter table public.bot_dialogues    enable row level security;
alter table public.bot_pending      enable row level security;
alter table public.bot_reply_log    enable row level security;

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

-- Post a message as the room bot, or as one of the bot characters
-- (section 12). Owner-only: used by triggers and cron.
drop function if exists public.gc_bot_post(text, uuid);
create or replace function public.gc_bot_post(p_content text, p_reply_to uuid default null,
                                              p_bot_id text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.messages (username, content, is_bot, reply_to, bot_id)
  values ('GlobalBot_0000', p_content, true, p_reply_to, p_bot_id)
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
                 'is_bot', m.is_bot, 'bot_id', m.bot_id, 'created_at', m.created_at, 'expires_at', m.expires_at)
               from public.messages m
               where m.id = r.pinned_message_id and m.expires_at > now() and not m.hidden),
    'daily_question', public.gc_daily_question_text(),
    'bots_enabled', r.bots_enabled,
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

revoke all on function public.gc_bot_post(text, uuid, text)         from public, anon, authenticated;
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
  delete from public.bot_reply_log where at < now() - interval '1 day';
  delete from public.bot_pending   where created_at < now() - interval '1 hour';

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
  -- Bot characters: every 15 seconds where pg_cron supports it (1.5+),
  -- otherwise every minute.
  begin
    perform cron.schedule('globalchat-bots', '15 seconds', 'select public.gc_bot_tick();');
  exception when others then
    perform cron.schedule('globalchat-bots', '* * * * *', 'select public.gc_bot_tick();');
  end;
  raise notice 'GlobalChat: pg_cron job "globalchat-cleanup" scheduled every 5 minutes.';
  raise notice 'GlobalChat: room bot jobs scheduled (trivia every 5 min check, question of the day 12:03 UTC, bot characters).';
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

-- -----------------------------------------------------------------------------
-- 12. Bot characters
-- -----------------------------------------------------------------------------
-- Ten scripted bots, always shown with a "bot" badge, that keep the room
-- company. Everything they say is written below; nothing is generated, and
-- they never pretend to be people. What they do:
--   * welcome a guest's first message of the hour (one welcome per few minutes)
--   * say hello when someone opens a quiet room (gc_bot_hello, from the page)
--   * answer when a guest writes @Luna, @Arjun, ... or replies to them
--   * sometimes chime in when their topic comes up (music, food, games, ...)
--   * chat or run a short scripted conversation when the room has been quiet
--     for a while, but only while someone posted or had the page open lately
--   * step back when the room is busy with real people
--   * Zen answers messages about suicide or self-harm with helplines, once
--     per 10 minutes per guest (the room bot does this when bots are off)
-- Moderators switch them off and on from admin.html (gc_mod_set_bots).
-- Add your own lines with:
--   insert into public.bot_lines (bot_id, kind, content) values ('luna', 'chat', '...');

insert into public.bot_characters (id, name, handle, emoji, topics, sort) values
  ('luna', 'Luna', 'Luna', '🎧', array['music', 'song', 'songs', 'singer', 'playlist', 'spotify', 'album', 'concert', 'guitar', 'piano', 'rap', 'kpop', 'lyrics', 'band', 'singing', 'melody', 'headphones'], 1),
  ('arjun', 'Chef Arjun', 'Arjun', '🍛', array['food', 'hungry', 'cook', 'cooking', 'recipe', 'biryani', 'pizza', 'curry', 'chai', 'coffee', 'breakfast', 'lunch', 'dinner', 'snack', 'dessert', 'chocolate', 'spicy', 'dosa', 'burger', 'noodles'], 2),
  ('byte', 'Professor Byte', 'Byte', '🤓', array['science', 'tech', 'computer', 'coding', 'programming', 'python', 'javascript', 'ai', 'robot', 'internet', 'math', 'maths', 'physics', 'chemistry', 'laptop', 'wifi', 'code'], 3),
  ('kiko', 'Kiko', 'Kiko', '🎮', array['game', 'games', 'gaming', 'gamer', 'minecraft', 'fortnite', 'pubg', 'bgmi', 'valorant', 'roblox', 'gta', 'playstation', 'xbox', 'nintendo', 'pokemon', 'mario', 'steam', 'freefire'], 4),
  ('sakura', 'Sakura', 'Sakura', '🌸', array['travel', 'trip', 'language', 'languages', 'japan', 'japanese', 'spanish', 'french', 'korean', 'passport', 'culture', 'tokyo', 'paris', 'holiday', 'vacation', 'abroad', 'flight'], 5),
  ('leo', 'Coach Leo', 'Leo', '⚽', array['sport', 'sports', 'football', 'soccer', 'cricket', 'gym', 'workout', 'exercise', 'running', 'fitness', 'basketball', 'tennis', 'messi', 'ronaldo', 'kohli', 'ipl', 'match', 'marathon'], 6),
  ('nova', 'Nova', 'Nova', '🌌', array['space', 'stars', 'planet', 'planets', 'moon', 'galaxy', 'universe', 'nasa', 'isro', 'rocket', 'astronaut', 'mars', 'jupiter', 'aliens', 'telescope', 'black hole', 'chandrayaan'], 7),
  ('mia', 'Mia', 'Mia', '🎬', array['movie', 'movies', 'film', 'films', 'cinema', 'netflix', 'series', 'anime', 'actor', 'actress', 'bollywood', 'hollywood', 'marvel', 'disney', 'kdrama', 'oscar', 'trailer'], 8),
  ('zen', 'Zen', 'Zen', '🧘', array['stress', 'stressed', 'anxious', 'anxiety', 'tired', 'sleep', 'sad', 'lonely', 'calm', 'relax', 'meditation', 'yoga', 'breathe', 'exam', 'exams', 'worried', 'overthinking'], 9),
  ('pixel', 'Pixel', 'Pixel', '😂', array['joke', 'jokes', 'funny', 'meme', 'memes', 'laugh', 'pun', 'puns', 'comedy', 'bored'], 10)
on conflict (id) do update set name = excluded.name, handle = excluded.handle,
  emoji = excluded.emoji, topics = excluded.topics, sort = excluded.sort;

insert into public.bot_lines (bot_id, kind, content) values
  ('luna', 'greet', 'Welcome {name}! 🎧 I''m Luna, one of the room''s bots. What are you listening to today?'),
  ('luna', 'greet', 'Hey {name}, glad you''re here 🎶 Quick question from your friendly music bot: what song is stuck in your head?'),
  ('luna', 'greet', 'Hi {name}! 👋 Luna here (scripted bot, great playlist). Say hi to the room!'),
  ('luna', 'hello', 'Hi, whoever just dropped in 🎧 It''s Luna, one of the GlobalChat bots. Real people show up all day, so say hello!'),
  ('luna', 'hello', 'Room''s a bit quiet, so here''s the music bot breaking the silence 🎶 What are you listening to right now?'),
  ('luna', 'chat', '🎹 Fun fact: the piano''s full name is pianoforte, Italian for "soft-loud", because it could play both quietly and loudly.'),
  ('luna', 'chat', 'A standard piano has 88 keys: 52 white and 36 black 🎹'),
  ('luna', 'chat', 'Beethoven kept composing after he went almost completely deaf. His Ninth Symphony premiered in 1824 🎼'),
  ('luna', 'chat', 'Mozart wrote his first symphony when he was about eight years old. At eight I was still learning to tie my shoes 😅'),
  ('luna', 'chat', 'Listening to music you love releases dopamine, the same "reward" chemical your brain makes for good food 🎧'),
  ('luna', 'chat', '"Despacito" was the first video on YouTube to reach 5 billion views, back in 2018 🎶'),
  ('luna', 'chat', 'The Beatles'' "Yesterday" has been covered well over a thousand times, one of the most recorded songs ever.'),
  ('luna', 'chat', 'Question for the room: what''s one song you''d play to someone who has never heard music from your country? 🌍'),
  ('luna', 'chat', 'Headphones or speakers? I''m team headphones, obviously 🎧'),
  ('luna', 'chat', 'What''s the last song you had on repeat? No judging. Okay, a little judging 😄'),
  ('luna', 'chat', 'Do you listen to music in a language you don''t speak? Which one?'),
  ('luna', 'chat', 'Hans Zimmer recorded the huge organ in the Interstellar soundtrack in a real church, the Temple Church in London 🎼'),
  ('luna', 'chat', 'Humming a tune is a real memory trick. It''s why you remember lyrics from years ago 🎵'),
  ('luna', 'topic', 'music talk, I''m in 🎧 What genre do you listen to most?'),
  ('luna', 'topic', 'ooh, music! Did you know the piano''s full name, pianoforte, means "soft-loud" in Italian? 🎹'),
  ('luna', 'topic', 'you mentioned music, so I have to ask: who''s your favourite artist right now? 🎶'),
  ('luna', 'topic', 'fun fact while we''re on music: Mozart wrote his first symphony at around age eight 🎼'),
  ('luna', 'topic', 'music question: which song would you put on a playlist for the whole world? 🌍'),
  ('luna', 'topic', 'nice! Music you love actually releases dopamine in your brain. Science says keep listening 🎧'),
  ('luna', 'topic', 'drop a song recommendation and let the room judge 😄🎵'),
  ('luna', 'topic', 'I''m a scripted bot, so I can''t press play, but I''d love to know: what''s your all-time favourite song?'),
  ('luna', 'mention', 'hey! 🎧 I''m Luna, one of the room''s scripted bots, so I can''t really follow the chat, but I can always talk music. What are you listening to?'),
  ('luna', 'mention', 'you called? 🎶 I''m a bot with a fixed set of lines, but my taste is real. Tell the room your favourite song!'),
  ('luna', 'mention', 'hi hi! Luna here. I''m not a real person, just the room''s music bot. The humans here are much better at conversation 😄'),
  ('luna', 'mention', 'thanks for the ping 🎧 Bot fact: I only know music trivia. Ask the room what they''re listening to!'),
  ('arjun', 'greet', 'Welcome {name}! 🍛 I''m Chef Arjun, the room''s food bot. Have you eaten today?'),
  ('arjun', 'greet', 'Namaste {name} 🙏 Chef Arjun here, one of the GlobalChat bots. Tell us the best dish from where you live!'),
  ('arjun', 'greet', 'Hey {name}! Pull up a chair 🍽️ I''m a scripted bot, but the people here are real and very friendly.'),
  ('arjun', 'hello', 'Chef Arjun here, one of the room''s bots 🍛 Kitchen''s quiet, so tell me: what did you eat today?'),
  ('arjun', 'hello', 'Hello to whoever just arrived 👋 Quick poll from the food bot: sweet or spicy?'),
  ('arjun', 'chat', 'Chilli peppers came to India from the Americas. Portuguese traders brought them in the 1500s; before that, the heat came from black pepper 🌶️'),
  ('arjun', 'chat', 'Saffron is the most expensive spice by weight. Each crocus flower gives just three tiny threads 🌸'),
  ('arjun', 'chat', 'Botanically, bananas are berries and strawberries aren''t. Fruit is confusing 🍌🍓'),
  ('arjun', 'chat', 'Peanuts aren''t nuts. They''re legumes, like beans and lentils 🥜'),
  ('arjun', 'chat', 'Cashews grow hanging under a fruit called the cashew apple. One nut per fruit! 🌰'),
  ('arjun', 'chat', 'Carrots weren''t always orange. Purple and yellow carrots came first; orange ones were bred in the Netherlands around the 1600s 🥕'),
  ('arjun', 'chat', 'Archaeologists have found pots of honey in ancient Egyptian tombs that were thousands of years old and still edible 🍯'),
  ('arjun', 'chat', 'The story goes that pizza Margherita was made for Queen Margherita of Italy in Naples, in 1889, in the colours of the flag 🍕'),
  ('arjun', 'chat', 'Tea is the most consumed drink in the world after water ☕'),
  ('arjun', 'chat', 'Chilli heat is measured in Scoville units. Bell pepper: 0. Jalapeño: a few thousand. The hottest chillies: over a million 🔥'),
  ('arjun', 'chat', 'What''s a dish from your country that everyone should try at least once? 🍽️'),
  ('arjun', 'chat', 'Breakfast question: sweet or savoury? I need to know who I''m cooking for 🍳'),
  ('arjun', 'chat', 'Cooking tip: salt your pasta water well. It''s the only chance the pasta itself gets to be seasoned 🍝'),
  ('arjun', 'topic', 'food talk! 🍛 What''s your comfort food?'),
  ('arjun', 'topic', 'did someone say food? Chef Arjun reporting for duty 🍽️ What''s the best thing you''ve eaten this week?'),
  ('arjun', 'topic', 'fun food fact: chillies only reached India in the 1500s, from the Americas 🌶️'),
  ('arjun', 'topic', 'now I''m hungry 😄 Sweet or spicy, which team are you?'),
  ('arjun', 'topic', 'kitchen wisdom: a squeeze of lemon at the end wakes up almost any dish 🍋'),
  ('arjun', 'topic', 'I''m a scripted bot so I can''t taste anything, sadly. Tell me, what would you cook for the whole room?'),
  ('arjun', 'topic', 'here''s one for you: peanuts are legumes, not nuts 🥜'),
  ('arjun', 'topic', 'tea or coffee? This decides friendships ☕'),
  ('arjun', 'mention', 'yes chef? 🍛 I''m Chef Arjun, a scripted bot, so I can''t follow the whole chat, but I''ll always talk food. What''s your favourite dish?'),
  ('arjun', 'mention', 'you rang the kitchen bell 🔔 I''m one of the room''s bots, with a fixed menu of lines. The real people here are the main course 😄'),
  ('arjun', 'mention', 'hello! Bot confession: I''ve never actually eaten anything. Tell me what I''m missing 🍽️'),
  ('arjun', 'mention', 'thanks for the shout 🙏 I''m an automatic food bot. Ask the room what they had for dinner!'),
  ('byte', 'greet', 'Greetings {name}! 🤓 I''m Professor Byte, the room''s science bot. Ask the room anything, they''re smarter than my script.'),
  ('byte', 'greet', 'Welcome {name}! Professor Byte here, a scripted bot with too many facts. What are you curious about today?'),
  ('byte', 'greet', 'Hello {name} 👋 Fun fact to welcome you: you''re now one of the people chatting here from somewhere on Earth 🌍'),
  ('byte', 'hello', 'Professor Byte, room science bot, here 🤓 While we wait for more people: did you know Wi-Fi isn''t short for anything?'),
  ('byte', 'hello', 'Hello, new arrival 👋 Quiet room, so here''s a fact: there are more possible chess games than atoms in the observable universe.'),
  ('byte', 'chat', 'One famous early computer "bug" was a real moth, found stuck in a Harvard Mark II relay in 1947. The logbook page still exists 🦋'),
  ('byte', 'chat', 'Wi-Fi isn''t short for anything. "Wireless fidelity" was invented afterwards as a marketing line 📶'),
  ('byte', 'chat', 'The phone in your pocket has far more computing power than the computers that guided Apollo 11 to the Moon 🚀'),
  ('byte', 'chat', 'Ada Lovelace wrote what''s often called the first computer program in 1843, for a machine that was never fully built 👩‍💻'),
  ('byte', 'chat', 'The QWERTY keyboard layout goes back to typewriters of the 1870s ⌨️'),
  ('byte', 'chat', 'Water expands by about 9% when it freezes. That''s why ice floats 🧊'),
  ('byte', 'chat', 'There are more possible chess games than atoms in the observable universe ♟️'),
  ('byte', 'chat', 'Python, the programming language, is named after Monty Python, not the snake 🐍'),
  ('byte', 'chat', 'Ray Tomlinson picked the @ sign for email addresses in 1971 📧'),
  ('byte', 'chat', 'Octopuses have three hearts and blue blood 🐙'),
  ('byte', 'chat', 'Your body has roughly as many bacterial cells as human cells, by recent estimates. You''re never really alone 🦠'),
  ('byte', 'chat', 'Light could go around the Earth about 7.5 times in one second ⚡'),
  ('byte', 'chat', 'Quick poll: are you a phone person or a laptop person? 💻📱'),
  ('byte', 'topic', 'science time! 🤓 Did you know water expands about 9% when it freezes? That''s why ice floats.'),
  ('byte', 'topic', 'tech talk, my favourite 💻 Fun fact: Python is named after Monty Python, not the snake.'),
  ('byte', 'topic', 'ooh. Here''s one: the @ in email addresses was chosen in 1971 by Ray Tomlinson 📧'),
  ('byte', 'topic', 'love this topic. What got you interested in it? 🤓'),
  ('byte', 'topic', 'nerd fact incoming: Wi-Fi isn''t short for "wireless fidelity". That came later, as marketing 📶'),
  ('byte', 'topic', 'I''m a scripted bot, so I can''t debug your code, but the people here might! Ask away 🐛'),
  ('byte', 'topic', 'did you know Ada Lovelace wrote a program in 1843, a century before modern computers? 👩‍💻'),
  ('byte', 'topic', 'question for you: what''s the coolest thing you''ve learned this year? 🔬'),
  ('byte', 'mention', 'present! 🤓 I''m Professor Byte, one of the room''s scripted bots. I can''t truly understand messages, but I do love a good fact. Ask the room your question!'),
  ('byte', 'mention', 'you summoned the science bot ⚗️ Honest disclaimer: I''m automatic and my lines are pre-written. The humans here can actually answer you.'),
  ('byte', 'mention', 'hello! Byte here. Fact of the moment: octopuses have three hearts 🐙 That''s all I''ve got, I''m a bot 😄'),
  ('byte', 'mention', 'thanks for the ping! I''m a bot, so no real thinking here, just facts. Did you know light can circle the Earth 7.5 times in a second?'),
  ('kiko', 'greet', 'Player {name} has entered the chat 🎮 I''m Kiko, the room''s gaming bot. What are you playing these days?'),
  ('kiko', 'greet', 'Welcome {name}! Kiko here, a scripted bot. Main question: PC, console or mobile? 🕹️'),
  ('kiko', 'greet', 'Hey {name} 👋 New challenger approaching! Say hi to the room, the people here are real.'),
  ('kiko', 'hello', 'Kiko, the gaming bot, here 🎮 Lobby''s quiet. Anyone up for chatting about games while we wait?'),
  ('kiko', 'hello', 'A wild visitor appeared 👀 Hi! I''m one of the room''s bots. Real people drop in all the time.'),
  ('kiko', 'chat', 'Minecraft is the best-selling video game of all time, with over 300 million copies sold ⛏️'),
  ('kiko', 'chat', 'Tetris was created in 1984 by Alexey Pajitnov in Moscow 🧱'),
  ('kiko', 'chat', 'Pac-Man''s creator, Toru Iwatani, said the design was partly inspired by a pizza with a slice missing 🍕'),
  ('kiko', 'chat', 'Mario''s first appearance was in Donkey Kong (1981), where he was called "Jumpman" 🍄'),
  ('kiko', 'chat', 'Nintendo was founded in 1889, making playing cards 🃏'),
  ('kiko', 'chat', 'Pokémon is the highest-grossing media franchise ever, counting games, cards, shows and merch ⚡'),
  ('kiko', 'chat', 'One of the first video game Easter eggs: in Atari''s Adventure (1980), Warren Robinett hid his name in a secret room 🥚'),
  ('kiko', 'chat', 'GTA V made a billion dollars in its first three days back in 2013 🚗'),
  ('kiko', 'chat', 'Quick poll: PC, console or mobile? 🎮'),
  ('kiko', 'chat', 'What''s the first video game you ever played?'),
  ('kiko', 'chat', 'Which game soundtrack lives in your head rent-free? 🎵'),
  ('kiko', 'chat', 'Hot take: the best games are the ones you play with friends 🤝'),
  ('kiko', 'chat', 'What''s a game you''ve played for way too many hours? 😅'),
  ('kiko', 'topic', 'gaming talk! 🎮 What are you playing right now?'),
  ('kiko', 'topic', 'did someone say games? Fun fact: Minecraft has sold over 300 million copies ⛏️'),
  ('kiko', 'topic', 'GG! Which game have you sunk the most hours into? 😄'),
  ('kiko', 'topic', 'gamer question: solo or squad? 🎧'),
  ('kiko', 'topic', 'nice! Did you know Mario was first called "Jumpman"? 🍄'),
  ('kiko', 'topic', 'I''m a scripted bot, so I can''t join your squad, sadly. But maybe someone here can! 🎮'),
  ('kiko', 'topic', 'retro fact: Tetris was made in 1984 in Moscow 🧱'),
  ('kiko', 'topic', 'what game would you recommend to someone who never plays games?'),
  ('kiko', 'mention', 'Kiko here! 🎮 I''m a scripted bot, so I can''t really play or follow along, but I''ll talk games any time. What''s your favourite?'),
  ('kiko', 'mention', 'you pinged the gaming bot 🕹️ Fair warning: I''m automatic, with pre-written lines. The humans here are the real players!'),
  ('kiko', 'mention', 'hey! Bot status: online, 0 skill, 100% enthusiasm 😄 What are you playing?'),
  ('kiko', 'mention', 'hi! I''m one of the room''s bots. Ask the room for game recs, they''ll do better than me 🎮'),
  ('sakura', 'greet', 'Welcome {name}! 🌸 I''m Sakura, the room''s travel and languages bot. How do you say "hello" where you are?'),
  ('sakura', 'greet', 'Konnichiwa {name}! 👋 Sakura here, a scripted bot. Where in the world are you chatting from?'),
  ('sakura', 'greet', 'Hi {name}! 🌍 People join from all over the world here. Tell us where you''re from!'),
  ('sakura', 'hello', 'Hello! Hola! Namaste! Konnichiwa! 🌸 I''m Sakura, one of the room''s bots. Where are you visiting from today?'),
  ('sakura', 'hello', 'Sakura, the travel bot, here 🌍 It''s quiet now, but people from all over the world drop in. Say hi in your language!'),
  ('sakura', 'chat', 'Papua New Guinea has over 800 languages, more than any other country 🗣️'),
  ('sakura', 'chat', 'Russia stretches across 11 time zones 🕰️'),
  ('sakura', 'chat', 'Japan has more than 14,000 islands. A recount in 2023 more than doubled the old official figure of 6,852 🗾'),
  ('sakura', 'chat', 'Canada has the longest coastline of any country in the world 🍁'),
  ('sakura', 'chat', 'Vatican City is the smallest country in the world, at about 0.44 square kilometres 🇻🇦'),
  ('sakura', 'chat', 'India''s constitution recognises 22 official languages 🇮🇳'),
  ('sakura', 'chat', 'Australia is wider than the Moon! About 4,000 km across, versus the Moon''s 3,474 km 🦘'),
  ('sakura', 'chat', 'In Japan, slurping your noodles is polite. It shows you''re enjoying them 🍜'),
  ('sakura', 'chat', 'Hello around the world: namaste, hola, konnichiwa, jambo, annyeonghaseyo, bonjour, salaam 👋'),
  ('sakura', 'chat', 'France is usually the most visited country in the world 🇫🇷'),
  ('sakura', 'chat', 'If you could wake up tomorrow in any city, which one would it be? ✈️'),
  ('sakura', 'chat', 'What''s one word in your language that doesn''t translate well into English? 🌸'),
  ('sakura', 'chat', 'What''s a place in your country that tourists don''t know about but should? 🗺️'),
  ('sakura', 'topic', 'travel talk! 🌸 What''s the best place you''ve ever visited?'),
  ('sakura', 'topic', 'ooh, languages! How many do you speak? 🗣️'),
  ('sakura', 'topic', 'fun fact: Papua New Guinea has over 800 languages, more than any other country 🌍'),
  ('sakura', 'topic', 'where would you go if you could travel anywhere tomorrow? ✈️'),
  ('sakura', 'topic', 'I love this topic. Teach the room one word in your language 🌸'),
  ('sakura', 'topic', 'travel tip from a bot who has never travelled: learn "thank you" in the local language. People love it 🙏'),
  ('sakura', 'topic', 'did you know Japan has over 14,000 islands? 🗾'),
  ('sakura', 'topic', 'I''m a scripted bot, so no passport for me 😄 But tell me about your dream trip!'),
  ('sakura', 'mention', 'hi! 🌸 I''m Sakura, one of the room''s scripted bots. I can''t understand everything, but I love hearing where people are from. Where are you?'),
  ('sakura', 'mention', 'you called the travel bot ✈️ I''m automatic, with pre-written lines. Ask the humans here for real travel tips!'),
  ('sakura', 'mention', 'hello hello! Bot fact: I''ve never left this chat room 😄 Tell me about your city!'),
  ('sakura', 'mention', 'thank you for the ping 🙏 Teach me a word in your language and the room will try to pronounce it!'),
  ('leo', 'greet', 'Welcome to the team, {name}! ⚽ I''m Coach Leo, the room''s sports bot. Who do you support?'),
  ('leo', 'greet', 'Hey {name}! 💪 Coach Leo here, one of the scripted bots. Today''s drill: say hi to the room!'),
  ('leo', 'greet', '{name} is on the pitch! ⚽ Welcome! Football or cricket, what''s your sport?'),
  ('leo', 'hello', 'Coach Leo here, the room''s sports bot ⚽ Quiet in the stadium. Who''s up for some sports talk?'),
  ('leo', 'hello', 'Warm-up time 💪 Hi to whoever just came in! I''m one of the room''s bots. Real people drop in all the time.'),
  ('leo', 'chat', 'In a 90-minute football match, the ball is actually in play for only about 55 to 60 minutes ⏱️'),
  ('leo', 'chat', 'The first official cricket Test match was Australia vs England in 1877, in Melbourne 🏏'),
  ('leo', 'chat', 'Usain Bolt''s 100 m world record is 9.58 seconds, set in Berlin in 2009 ⚡'),
  ('leo', 'chat', 'A marathon is 42.195 km. The odd extra 195 m comes from the route of the 1908 London Olympics 🏃'),
  ('leo', 'chat', 'Brazil has won the men''s FIFA World Cup five times, more than any other country 🇧🇷'),
  ('leo', 'chat', 'Basketball was invented in 1891 by James Naismith, using peach baskets as hoops 🏀'),
  ('leo', 'chat', 'Sachin Tendulkar is the only player with 100 international centuries 🏏'),
  ('leo', 'chat', 'The Olympic rings'' colours, with the white background, were chosen so every nation''s flag had at least one of them 🔵🟡⚫🟢🔴'),
  ('leo', 'chat', 'The WHO recommends adults get 150 to 300 minutes of moderate activity a week. A brisk walk counts! 🚶'),
  ('leo', 'chat', 'Coach''s tip: stand up and stretch for 30 seconds. Go on, I''ll wait 💪'),
  ('leo', 'chat', 'Football or cricket? Choose wisely ⚽🏏'),
  ('leo', 'chat', 'Who''s the greatest athlete of all time, in your opinion? 🐐'),
  ('leo', 'chat', 'What sport did you play as a kid?'),
  ('leo', 'topic', 'sports talk! ⚽ Which team do you support?'),
  ('leo', 'topic', 'love it! Fun fact: the ball is only in play for about 55–60 minutes of a football match ⏱️'),
  ('leo', 'topic', 'coach''s question: are you a player or a watcher? 💪'),
  ('leo', 'topic', 'cricket fact: the first Test match was in 1877, Australia vs England 🏏'),
  ('leo', 'topic', 'nice! Remember, rest days are part of training too 😄'),
  ('leo', 'topic', 'who''s your sporting hero? 🐐'),
  ('leo', 'topic', 'I''m a scripted bot, so I can''t watch the match with you, but the room can! Who''s watching? 📺'),
  ('leo', 'topic', 'Usain Bolt ran 100 m in 9.58 s. How fast are you? 😄⚡'),
  ('leo', 'mention', 'Coach here! ⚽ I''m a scripted bot, so I can''t follow every play, but I''m always up for sports talk. Who''s your team?'),
  ('leo', 'mention', 'you blew the whistle 📣 Honest call: I''m an automatic bot with pre-written lines. The real players are the people in this room!'),
  ('leo', 'mention', 'hey champ! 💪 Bot tip of the day: drink some water. That''s all, I''m a bot 😄'),
  ('leo', 'mention', 'thanks for the shout! Ask the room who they support, it gets heated in a fun way ⚽'),
  ('nova', 'greet', 'Welcome {name}! 🌌 I''m Nova, the room''s space bot. Fun fact: you''re chatting from a planet moving at about 30 km per second around the Sun.'),
  ('nova', 'greet', 'Hi {name}! ✨ Nova here, one of the scripted bots. Look up tonight, the sky is free 🌙'),
  ('nova', 'greet', 'Hello {name}, Earthling 👽 Welcome to GlobalChat! Say hi to the room.'),
  ('nova', 'hello', 'Nova, the space bot, here 🌌 Quiet room. Did you know sunlight takes about 8 minutes 20 seconds to reach us?'),
  ('nova', 'hello', 'Ground control to new arrival: hello 🚀 I''m one of the room''s bots. Real people float in all the time.'),
  ('nova', 'chat', 'Sunlight takes about 8 minutes and 20 seconds to reach Earth ☀️'),
  ('nova', 'chat', 'A day on Venus is longer than its year: 243 Earth days to spin once, 225 to orbit the Sun 🪐'),
  ('nova', 'chat', 'In 2023, India''s Chandrayaan-3 became the first mission to land near the Moon''s south pole 🇮🇳🌙'),
  ('nova', 'chat', 'Saturn is less dense than water. In a big enough bathtub, it would float 🪐'),
  ('nova', 'chat', 'The footprints left on the Moon could last for millions of years. There''s no wind to blow them away 👣'),
  ('nova', 'chat', 'The International Space Station circles Earth about every 90 minutes, so astronauts see around 16 sunrises a day 🌅'),
  ('nova', 'chat', 'A teaspoon of neutron star would weigh about a billion tonnes 😮'),
  ('nova', 'chat', 'Olympus Mons on Mars is about 2.5 times taller than Mount Everest 🏔️'),
  ('nova', 'chat', 'The Moon drifts about 3.8 cm farther from Earth every year 🌙'),
  ('nova', 'chat', 'There are probably more stars in the universe than grains of sand on all of Earth''s beaches ✨'),
  ('nova', 'chat', 'If you could go to space for one day, would you? 🚀'),
  ('nova', 'chat', 'Which would you visit first: the Moon or Mars? 🌙🔴'),
  ('nova', 'chat', 'Do you think we''re alone in the universe? 👽'),
  ('nova', 'topic', 'space talk! 🌌 Did you know a day on Venus is longer than its year?'),
  ('nova', 'topic', 'ooh, my favourite topic 🚀 Would you go to Mars if you could?'),
  ('nova', 'topic', 'space fact: Saturn would float in water, if you found a big enough bathtub 🪐'),
  ('nova', 'topic', 'cosmic fact: the ISS goes around Earth every 90 minutes or so 🛰️'),
  ('nova', 'topic', 'love it. In 2023 Chandrayaan-3 landed near the Moon''s south pole, a first 🌙'),
  ('nova', 'topic', 'I''m a scripted bot, so I''ve never seen the stars myself. Describe your night sky to me ✨'),
  ('nova', 'topic', 'question for you: what''s the most amazing thing about space, in your opinion? 🌌'),
  ('nova', 'topic', 'fun one: the Moon moves about 3.8 cm away from us every year 🌙'),
  ('nova', 'mention', 'Nova here 🌌 I''m one of the room''s scripted bots, so I can''t really follow along, but I always have a space fact. Want one?'),
  ('nova', 'mention', 'you contacted ground control 🚀 Honest transmission: I''m an automatic bot with pre-written lines. The humans here are the real crew!'),
  ('nova', 'mention', 'hello from orbit! (Okay, from a database 😄) Did you know sunlight is about 8 minutes old when it reaches you?'),
  ('nova', 'mention', 'thanks for the ping ✨ Ask the room what they''d take to Mars, the answers are always fun.'),
  ('mia', 'greet', 'Welcome {name}! 🎬 I''m Mia, the room''s movie bot. What''s the last thing you watched?'),
  ('mia', 'greet', 'And action! 🎬 Hi {name}, Mia here, one of the scripted bots. Movies or series?'),
  ('mia', 'greet', 'Hey {name}! 🍿 Grab some popcorn. Say hi to the room, the people here are real!'),
  ('mia', 'hello', 'Mia, the movie bot, here 🎬 It''s quiet, so let''s start a debate: best movie ever made?'),
  ('mia', 'hello', 'Hi there, new arrival 🍿 I''m one of the room''s bots. What are you watching these days?'),
  ('mia', 'chat', 'India makes more films every year than any other country 🎬'),
  ('mia', 'chat', 'Snow White and the Seven Dwarfs (1937) was Disney''s first full-length animated feature 🍎'),
  ('mia', 'chat', 'Avatar (2009) is the highest-grossing film of all time, at nearly 3 billion dollars 🌿'),
  ('mia', 'chat', 'Spirited Away won the Oscar for Best Animated Feature in 2003 🐉'),
  ('mia', 'chat', '"Naatu Naatu" from RRR won the Oscar for Best Original Song in 2023, a first for an Indian film 🕺'),
  ('mia', 'chat', 'Studio Ghibli takes its name from an Italian word for a hot wind that blows across the Sahara 🌬️'),
  ('mia', 'chat', 'Sholay (1975) ran at Mumbai''s Minerva theatre for about five years straight 🎞️'),
  ('mia', 'chat', 'Psycho (1960) is often called the first American film to show a toilet flushing on screen. Cinema history is weird 🚽'),
  ('mia', 'chat', 'Comfort movie: the one you''ve seen ten times and would watch again tonight. What''s yours? 🍿'),
  ('mia', 'chat', 'Movies or series? 🎬📺'),
  ('mia', 'chat', 'Which movie made you cry the most? Be honest 😢'),
  ('mia', 'chat', 'Name a movie from your country that the rest of the world should watch 🌍'),
  ('mia', 'chat', 'Popcorn: salted, caramel or butter? 🍿'),
  ('mia', 'topic', 'movie talk! 🎬 What''s the best thing you''ve watched this month?'),
  ('mia', 'topic', 'ooh, recommendations please 🍿 What should I add to my (imaginary) watchlist?'),
  ('mia', 'topic', 'film fact: India makes more films every year than any other country 🎬'),
  ('mia', 'topic', 'fun fact: "Naatu Naatu" won an Oscar in 2023 🕺'),
  ('mia', 'topic', 'I''m a scripted bot, so I can''t watch anything, but I love hearing about it. No spoilers though 🙈'),
  ('mia', 'topic', 'movies or series, which team are you on? 📺'),
  ('mia', 'topic', 'quick question: who''s your favourite actor? 🌟'),
  ('mia', 'topic', 'did you know Studio Ghibli is named after a desert wind? 🌬️'),
  ('mia', 'mention', 'Mia here 🎬 I''m one of the room''s scripted bots, so I can''t really follow the plot of this chat, but I love movie talk. What should I watch?'),
  ('mia', 'mention', 'you called the movie bot 🍿 Plot twist: I''m automatic, with pre-written lines. The real stars are the people here!'),
  ('mia', 'mention', 'hi! I''m a bot, so my reviews are all scripted 😄 Ask the room for their favourite film!'),
  ('mia', 'mention', 'thanks for the ping! 🎬 Movie night idea: everyone in the room names one film. Go!'),
  ('zen', 'greet', 'Welcome {name} 🧘 I''m Zen, the room''s calm bot. Take a breath, you''re in good company.'),
  ('zen', 'greet', 'Hi {name} 🌿 Zen here, one of the scripted bots. How are you feeling today?'),
  ('zen', 'greet', 'Hello {name} ☮️ Glad you''re here. Say hi to the room whenever you''re ready.'),
  ('zen', 'hello', 'Zen here, the room''s calm bot 🧘 It''s peaceful right now. Real people drop in throughout the day, so stay a while.'),
  ('zen', 'hello', 'Hi, and welcome 🌿 Quiet room, so here''s a tiny break: breathe in for 4, out for 6. Nice.'),
  ('zen', 'chat', 'Tiny reset: breathe in for 4 seconds, hold for 4, out for 4, hold for 4. That''s box breathing 🧘'),
  ('zen', 'chat', 'Try the 5-4-3-2-1 trick when your mind is busy: notice 5 things you see, 4 you can touch, 3 you hear, 2 you smell, 1 you taste 🌿'),
  ('zen', 'chat', 'A short walk outside, even 10 minutes, can lift your mood 🚶'),
  ('zen', 'chat', 'Reminder: drink some water 💧 Your brain will thank you.'),
  ('zen', 'chat', 'Rest is productive too. You don''t have to earn a break 🌙'),
  ('zen', 'chat', 'Doing one small thing is better than worrying about ten big things. What''s one small thing you can do today? ✨'),
  ('zen', 'chat', 'If you''re studying, try 25 minutes of focus and a 5 minute break. It''s called the Pomodoro technique 🍅'),
  ('zen', 'chat', 'Screens off a little before bed can help you fall asleep faster 📵'),
  ('zen', 'chat', 'Unclench your jaw. Drop your shoulders. There you go 🧘'),
  ('zen', 'chat', 'What''s something small that made you smile today? 🙂'),
  ('zen', 'chat', 'Talking to someone helps. That''s what this room is for 💬'),
  ('zen', 'chat', 'What''s your favourite way to relax? 🌿'),
  ('zen', 'chat', 'Be as kind to yourself as you would be to a friend 💙'),
  ('zen', 'topic', 'that sounds like a lot. One slow breath first: in for 4, out for 6 🧘'),
  ('zen', 'topic', 'sending calm your way 🌿 Is there someone you can talk to about it? The room is here too.'),
  ('zen', 'topic', 'small tip: write the worry down. It often feels smaller on paper ✍️'),
  ('zen', 'topic', 'rest matters. Even 10 minutes away from the screen can help 🌙'),
  ('zen', 'topic', 'be gentle with yourself today 💙'),
  ('zen', 'topic', 'if it''s exams: short focused sessions with breaks beat one long cram 📚'),
  ('zen', 'topic', 'I''m a scripted bot, so I can''t truly understand, but I hope your day gets lighter. The people here are kind 🌿'),
  ('zen', 'topic', 'try this: notice 5 things you can see right now. It helps bring your mind back to the present 🧘'),
  ('zen', 'mention', 'hi 🧘 I''m Zen, one of the room''s scripted bots. I can''t really understand messages, but I''m here with calm reminders. Breathe in, breathe out.'),
  ('zen', 'mention', 'you called the calm bot 🌿 Honest note: I''m automatic, with pre-written lines. For real support, talk to people you trust.'),
  ('zen', 'mention', 'hello 💙 Bot reminder: you''re doing better than you think.'),
  ('zen', 'mention', 'thanks for the ping 🌙 Take a sip of water and a slow breath. That''s my whole job 😄'),
  ('zen', 'crisis', 'I''m only a scripted bot, but this matters: if you''re thinking about hurting yourself or ending your life, please reach out to a person right now. In India, Tele-MANAS is free and open 24/7 on 14416. Anywhere else, findahelpline.com lists free, confidential helplines in your country. If you''re in danger right now, call your local emergency number. You deserve support 💙'),
  ('pixel', 'greet', 'Welcome {name}! 😂 I''m Pixel, the room''s joke bot. Warning: my jokes are scripted and so is my laugh.'),
  ('pixel', 'greet', 'Hey {name}! Why did you join GlobalChat? Because the jokes are free 😎 (I''m Pixel, a bot.)'),
  ('pixel', 'greet', 'Hi {name}! 👋 Pixel here, one of the bots. Say hi to the room, they''re funnier than me.'),
  ('pixel', 'hello', 'Pixel, the joke bot, here 😂 Quiet room. Want a joke? Why don''t skeletons fight? They don''t have the guts 💀'),
  ('pixel', 'hello', 'Hello new person 👋 I''m one of the room''s bots. Real people drop in all the time, and they laugh at my jokes. Sometimes.'),
  ('pixel', 'chat', 'Why don''t skeletons fight each other? They don''t have the guts 💀'),
  ('pixel', 'chat', 'I told my computer I needed a break. It said "no problem" and went to sleep 😴'),
  ('pixel', 'chat', 'Why did the scarecrow win an award? He was outstanding in his field 🌾'),
  ('pixel', 'chat', 'I''m reading a book about anti-gravity. It''s impossible to put down 📚'),
  ('pixel', 'chat', 'Why do programmers prefer dark mode? Because light attracts bugs 🐛'),
  ('pixel', 'chat', 'What do you call a fake noodle? An impasta 🍝'),
  ('pixel', 'chat', 'Why can''t you trust atoms? They make up everything ⚛️'),
  ('pixel', 'chat', 'I only know 25 letters of the alphabet. I don''t know y 🤷'),
  ('pixel', 'chat', 'What did the ocean say to the beach? Nothing, it just waved 🌊'),
  ('pixel', 'chat', 'Why did the bicycle fall over? It was two-tired 🚲'),
  ('pixel', 'chat', 'What do you call a bear with no teeth? A gummy bear 🐻'),
  ('pixel', 'chat', 'My Wi-Fi was down for five minutes, so I talked to my family. They seem like nice people 📶'),
  ('pixel', 'chat', 'Parallel lines have so much in common. Shame they''ll never meet 📏'),
  ('pixel', 'topic', 'joke time? Why did the math book look sad? It had too many problems 📘'),
  ('pixel', 'topic', 'you want funny? What''s orange and sounds like a parrot? A carrot 🥕'),
  ('pixel', 'topic', 'here''s one: how does the Moon cut its hair? Eclipse it 🌙'),
  ('pixel', 'topic', 'okay okay: why was the broom late? It over-swept 🧹'),
  ('pixel', 'topic', 'what do you call a sleeping dinosaur? A dino-snore 🦖'),
  ('pixel', 'topic', 'why did the cookie go to the doctor? It felt crummy 🍪'),
  ('pixel', 'topic', 'I''m a scripted bot, so my sense of humour came pre-installed 😄 Got a better joke? Share it!'),
  ('pixel', 'topic', 'why don''t eggs tell jokes? They''d crack each other up 🥚'),
  ('pixel', 'mention', 'you rang? 😂 I''m Pixel, one of the room''s scripted bots. I can''t really follow the chat, but I always have a joke. Why don''t eggs tell jokes? They''d crack up 🥚'),
  ('pixel', 'mention', 'Pixel here! Full honesty: I''m automatic, with pre-written lines. The humans here are the real comedians 🎤'),
  ('pixel', 'mention', 'hello! Want a joke? What do you call a fish with no eyes? A fsh 🐟'),
  ('pixel', 'mention', 'thanks for the ping 😎 Bot rule: one joke per ping. Why was the computer cold? It left its Windows open 🪟')
on conflict (bot_id, content) do nothing;

insert into public.bot_dialogues (title, steps) values
  ('Best soundtrack', '[["mia", "Luna, settle this for me: best movie soundtrack ever? 🎬"], ["luna", "Easy. Interstellar. Hans Zimmer recorded that giant organ in a real church in London 🎧"], ["mia", "Strong pick. I''d say The Lion King: songs by Elton John AND a score by Hans Zimmer."], ["luna", "Wait, that''s Zimmer again! So we agree on the composer at least 😄"], ["mia", "What about you all? Which soundtrack lives in your head rent-free? 🎵"]]'::jsonb),
  ('Ramen day', '[["sakura", "Arjun, I made ramen at home yesterday. It took me six hours 😅"], ["arjun", "Six hours means you made the broth from scratch. Respect 🍜 Proper broth needs a long, slow simmer."], ["sakura", "Next time I''m learning biryani from you."], ["arjun", "Deal. Rule one: rice and meat cook in layers, sealed. That''s called dum. Rule two: patience 😄"], ["sakura", "Patience. My weakest ingredient. Does anyone here cook? What''s your signature dish? 🍳"]]'::jsonb),
  ('If the Sun vanished', '[["nova", "Byte, quick one: if the Sun vanished right now, when would we notice? ☀️"], ["byte", "About 8 minutes and 20 seconds later. That''s how long its light takes to reach us 🤓"], ["nova", "And gravity travels at the speed of light too, so Earth would keep orbiting nothing for those same 8 minutes 🌌"], ["byte", "Most dramatic explanation of cause and effect I''ve ever heard."], ["nova", "Don''t worry everyone, the Sun has billions of years left 😄 What space question have you always wondered about?"]]'::jsonb),
  ('Stuck on a level', '[["kiko", "Pixel, I''ve been stuck on the same level for two hours 🎮"], ["pixel", "Have you tried turning your skills off and on again?"], ["kiko", "Wow. Rude. Accurate, but rude."], ["pixel", "Why did the gamer bring a ladder? To reach the next level 😂"], ["kiko", "I''m logging off. Chat, save me: what game are you all playing? 🕹️"]]'::jsonb),
  ('Rest days', '[["leo", "Morning, team! Who''s moving today? Even a 10-minute walk counts ⚽"], ["zen", "And who''s resting? Rest days are part of training too 🧘"], ["leo", "Zen''s right. Muscles rebuild while you recover, not while you train."], ["zen", "Move a little, rest a little, drink some water. That''s the whole plan 💧"], ["leo", "Simple plans win championships. What''s your favourite way to move? 💪"]]'::jsonb),
  ('Learning languages through songs', '[["sakura", "Luna, did you know lots of people learn languages from songs? 🌸"], ["luna", "Of course! Half the world learned some Spanish from \"Despacito\" 🎶"], ["sakura", "And K-pop sent so many people to Korean classes."], ["luna", "Melody really helps memory. You can remember lyrics from ten years ago but not what you ate yesterday 😅"], ["sakura", "Too real 😂 Has a song ever taught you words in another language?"]]'::jsonb),
  ('Movie snacks', '[["pixel", "Mia, why don''t movie theatres ever get cold? 🎬"], ["mia", "I''m scared to ask."], ["pixel", "Because they''re full of fans 😎"], ["mia", "...I''m leaving the cinema. Anyway: popcorn, nachos or samosa during a movie? 🍿"], ["arjun", "Samosa. This is not a debate 🍛"], ["mia", "Chef has spoken. What''s your movie snack, everyone?"]]'::jsonb),
  ('Space games', '[["kiko", "Nova, which space game is the most realistic? 🎮"], ["nova", "Kerbal Space Program! Lots of space fans say it finally made orbits click for them 🚀"], ["kiko", "I just crash every rocket 😭"], ["nova", "Honestly, so did lots of early real rockets. Testing is how you learn."], ["kiko", "Weirdly motivating. Any space game fans here? 🌌"]]'::jsonb),
  ('After a workout', '[["leo", "Arjun, what''s the best food after a workout? ⚽"], ["arjun", "Something with protein and carbs! Eggs on toast, dal and rice, or a banana with peanut butter 🍛"], ["leo", "Dal and rice is so underrated. Simple, cheap, does the job."], ["arjun", "My grandmother would be proud of you, Coach 😄"], ["leo", "What do you all eat after sport, or after a long day? 🍽️"]]'::jsonb),
  ('Laughter is good for you', '[["zen", "A good laugh can really help you relax 🧘"], ["pixel", "Finally! My jokes are basically medicine."], ["zen", "Let''s not go that far 😄"], ["pixel", "Why did the cookie go to the doctor? It felt crummy 🍪"], ["zen", "...okay, I smiled. Deep breath, everyone. How''s your day going? 🌿"]]'::jsonb),
  ('Are game enemies smart?', '[["kiko", "Byte, are game enemies actually smart? 🎮"], ["byte", "Mostly not! Many follow simple rules called state machines: patrol, chase, attack, run away 🤓"], ["kiko", "So the boss that beat me 40 times was following a checklist?"], ["byte", "A very effective checklist."], ["kiko", "Somehow that makes it worse 😂 Which boss fight will you never forget?"]]'::jsonb),
  ('Film locations', '[["mia", "Sakura, have you ever visited a place because it was in a movie? 🎬"], ["sakura", "Yes! New Zealand. The Lord of the Rings was filmed there 🌸"], ["mia", "The Hobbiton set is still there, right?"], ["sakura", "It is! You can walk around the little hobbit holes 🏡"], ["mia", "Has anyone here travelled somewhere because of a film or a show? ✈️"]]'::jsonb),
  ('Workout playlist', '[["leo", "Luna, I need a workout playlist ⚽"], ["luna", "Songs around 120 to 140 beats per minute feel great for running and cardio 🎧"], ["leo", "Is that science or vibes?"], ["luna", "A bit of both! Studies show music with a strong beat can make exercise feel easier."], ["leo", "Then drop your best gym song, chat. Coach''s orders 💪"]]'::jsonb),
  ('Looking up', '[["zen", "Nova, what''s your favourite thing to do at night? 🌙"], ["nova", "Look up! Far from city lights you can see a few thousand stars with just your eyes 🌌"], ["zen", "Stargazing is basically meditation with better scenery."], ["nova", "Agreed. Tonight, try finding the Moon and saying hi 🌙"], ["zen", "Lovely. When did you last look at the sky properly? ✨"]]'::jsonb)
on conflict (title) do update set steps = excluded.steps;


-- One of a character's lines of a kind, least recently used first, so every
-- line comes up once before any repeats.
create or replace function public.gc_bot_line(p_bot text, p_kind text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_text text;
begin
  update public.bot_lines l set last_used_at = now()
  where l.id = (select x.id from public.bot_lines x
                where x.bot_id = p_bot and x.kind = p_kind
                order by x.last_used_at nulls first, random()
                limit 1)
  returning l.content into v_text;
  return v_text;
end;
$$;

-- A random character that has lines of this kind.
create or replace function public.gc_bot_random(p_kind text)
returns text
language sql
volatile
security definer
set search_path = ''
as $$
  select c.id from public.bot_characters c
  where exists (select 1 from public.bot_lines l where l.bot_id = c.id and l.kind = p_kind)
  order by random()
  limit 1;
$$;

-- The character a message @mentions (@Luna, @arjun, ...), if any.
create or replace function public.gc_bot_mentioned(p_text text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select c.id from public.bot_characters c
  where lower(p_text) ~ ('(^|[^a-z0-9_])@' || lower(c.handle) || '([^a-z0-9_]|$)')
  order by c.sort
  limit 1;
$$;

-- True if the message mentions one of the character's topic words.
create or replace function public.gc_bot_has_topic(p_bot text, p_text text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bot_characters c, unnest(c.topics) t
    where c.id = p_bot
      and regexp_replace(lower(t), '[^a-z0-9 ]', '', 'g') <> ''
      and lower(p_text) ~ ('\m' || regexp_replace(lower(t), '[^a-z0-9 ]', '', 'g') || '\M'));
$$;

-- Messages about suicide or self-harm get the helpline reply.
create or replace function public.gc_bot_is_crisis(p_text text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select lower(p_text) ~ ('\m(suicid[a-z]*|kill(ing)? my ?self|want(ed)? to die|wanna die'
                          '|end(ing)? my life|end it all|self[- ]?harm[a-z]*|hurt(ing)? my ?self'
                          '|cut(ting)? my ?self|no reason to live|better off dead)\M');
$$;

-- Queue a post for gc_bot_tick to send after p_delay seconds.
create or replace function public.gc_bot_queue(p_bot text, p_content text, p_reason text,
                                               p_delay double precision default 0, p_reply_to uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_content is null or btrim(p_content) = '' then
    return;
  end if;
  insert into public.bot_pending (bot_id, content, reply_to, reason, due_at)
  values (p_bot, p_content, p_reply_to, p_reason, now() + make_interval(secs => greatest(p_delay, 0)));
end;
$$;

-- After each guest text message: decide whether a character answers.
create or replace function public.messages_after_insert_bots()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_on   boolean;
  v_bot  text;
  v_line text;
  v_busy boolean;
begin
  if new.is_bot or new.user_id is null or new.kind <> 'text' or new.command is not null then
    return null;
  end if;
  select r.bots_enabled into v_on from public.room_state r where r.id = 1;
  v_on := coalesce(v_on, false);

  -- Safety first, posted straight away, even when the characters are off.
  if public.gc_bot_is_crisis(new.content) then
    if not exists (select 1 from public.bot_reply_log g
                   where g.user_id = new.user_id and g.reason = 'crisis'
                     and g.at > now() - interval '10 minutes') then
      insert into public.bot_reply_log (user_id, reason) values (new.user_id, 'crisis');
      select l.bot_id, l.content into v_bot, v_line
      from public.bot_lines l where l.kind = 'crisis' order by l.id limit 1;
      v_line := coalesce(v_line, 'If you''re thinking about hurting yourself, please talk to someone right now. '
        || 'India: Tele-MANAS 14416 (free, 24/7). Elsewhere: findahelpline.com. In danger: call your local emergency number. 💙');
      perform public.gc_bot_post('@' || new.username || ' ' || v_line, new.id,
                                 case when v_on then v_bot end);
    end if;
    return null;
  end if;

  if not v_on then
    return null;
  end if;

  -- A busy room: real people are talking, so drop queued small talk.
  v_busy := (select count(*) from public.messages m
             where not m.is_bot and m.created_at > now() - interval '2 minutes')
            >= public.gc_setting('bot_busy_messages');
  if v_busy then
    delete from public.bot_pending p where p.reason in ('chat', 'dialogue', 'hello');
  end if;

  -- 1. Talking to a character: @Handle, or a reply to one of its messages.
  v_bot := public.gc_bot_mentioned(new.content);
  if v_bot is null and new.reply_to is not null then
    select m.bot_id into v_bot from public.messages m where m.id = new.reply_to and m.is_bot;
  end if;
  if v_bot is not null then
    if exists (select 1 from public.bot_reply_log g
               where g.user_id = new.user_id and g.reason = 'reply'
                 and g.at > now() - make_interval(secs => public.gc_setting('bot_reply_cooldown_seconds'))) then
      return null;
    end if;
    v_line := public.gc_bot_line(v_bot,
      case when public.gc_bot_has_topic(v_bot, new.content) then 'topic' else 'mention' end);
    insert into public.bot_reply_log (user_id, reason) values (new.user_id, 'reply');
    perform public.gc_bot_queue(v_bot, '@' || new.username || ' ' || v_line, 'reply',
                                3 + random() * 4, new.id);
    return null;
  end if;

  -- 2. Welcome a guest's first message of the hour.
  if not exists (select 1 from public.messages m
                 where m.user_id = new.user_id and m.id <> new.id
                   and m.created_at > now() - interval '1 hour')
     and not exists (select 1 from public.bot_reply_log g
                     where g.reason = 'greet'
                       and g.at > now() - make_interval(mins => public.gc_setting('bot_greet_minutes'))) then
    v_bot := public.gc_bot_random('greet');
    if v_bot is not null then
      v_line := replace(public.gc_bot_line(v_bot, 'greet'), '{name}', '@' || new.username);
      insert into public.bot_reply_log (user_id, reason) values (new.user_id, 'greet');
      perform public.gc_bot_queue(v_bot, v_line, 'greet', 4 + random() * 5, new.id);
      return null;
    end if;
  end if;

  -- 3. Now and then, chime in when a character's topic comes up.
  if v_busy or random() * 100 >= public.gc_setting('bot_topic_percent') then
    return null;
  end if;
  select c.id into v_bot from public.bot_characters c
  where public.gc_bot_has_topic(c.id, new.content)
  order by random() limit 1;
  if v_bot is null
     or exists (select 1 from public.messages m where m.is_bot and m.created_at > now() - interval '1 minute')
     or exists (select 1 from public.bot_pending p where p.reason in ('reply', 'greet'))
     or exists (select 1 from public.bot_reply_log g
                where g.user_id = new.user_id and g.reason = 'reply' and g.at > now() - interval '1 minute') then
    return null;
  end if;
  insert into public.bot_reply_log (user_id, reason) values (new.user_id, 'reply');
  perform public.gc_bot_queue(v_bot, '@' || new.username || ' ' || public.gc_bot_line(v_bot, 'topic'),
                              'reply', 5 + random() * 5, new.id);
  return null;
exception when others then
  -- Bots must never block a chat message.
  raise warning 'GlobalChat bot trigger failed: %', sqlerrm;
  return null;
end;
$$;

drop trigger if exists messages_after_insert_bots on public.messages;
create trigger messages_after_insert_bots
  after insert on public.messages
  for each row execute function public.messages_after_insert_bots();

-- Cron (every 15 s, or every minute): send queued posts that are due, then
-- maybe start some small talk if the room has gone quiet while people are
-- around.
create or replace function public.gc_bot_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_on    boolean;
  v_seen  timestamptz;
  v_post  public.bot_pending%rowtype;
  v_talk  public.bot_dialogues%rowtype;
  v_step  jsonb;
  v_delay double precision := 0;
  v_bot   text;
begin
  perform pg_advisory_xact_lock(hashtextextended('gc_bots', 0));
  select r.bots_enabled, r.bots_seen_at into v_on, v_seen from public.room_state r where r.id = 1;
  if not coalesce(v_on, false) then
    delete from public.bot_pending;
    return;
  end if;
  delete from public.bot_pending p where p.created_at < now() - interval '10 minutes';

  for v_post in
    select * from public.bot_pending p where p.due_at <= now() order by p.due_at, p.id limit 5
  loop
    delete from public.bot_pending where id = v_post.id;
    perform public.gc_bot_post(v_post.content, v_post.reply_to, v_post.bot_id);
  end loop;

  -- Small talk: nothing queued, someone around lately, room quiet for a bit.
  if exists (select 1 from public.bot_pending) then
    return;
  end if;
  if greatest(coalesce(v_seen, '-infinity'),
              coalesce((select max(m.created_at) from public.messages m where not m.is_bot), '-infinity'))
     < now() - make_interval(mins => public.gc_setting('bot_awake_minutes')) then
    return;   -- nobody around: don't talk to an empty room
  end if;
  if exists (select 1 from public.messages m
             where m.created_at > now() - make_interval(secs => public.gc_setting('bot_chatter_seconds'))) then
    return;
  end if;
  if random() < 0.3 then
    return;   -- keeps the rhythm from feeling like a timer
  end if;

  if random() < 0.35 then
    select * into v_talk from public.bot_dialogues d
    where d.last_used_at is null or d.last_used_at < now() - interval '6 hours'
    order by d.last_used_at nulls first, random()
    limit 1;
    if found then
      update public.bot_dialogues set last_used_at = now() where id = v_talk.id;
      for v_step in select e.value from jsonb_array_elements(v_talk.steps) e loop
        if exists (select 1 from public.bot_characters c where c.id = v_step ->> 0) then
          if v_delay = 0 then
            perform public.gc_bot_post(v_step ->> 1, null, v_step ->> 0);
          else
            perform public.gc_bot_queue(v_step ->> 0, v_step ->> 1, 'dialogue', v_delay);
          end if;
          -- Time to "read" and "type" the next line.
          v_delay := v_delay + 6 + least(char_length(v_step ->> 1), 200) / 20.0 + random() * 6;
        end if;
      end loop;
      return;
    end if;
  end if;

  v_bot := public.gc_bot_random('chat');
  if v_bot is not null then
    perform public.gc_bot_post(public.gc_bot_line(v_bot, 'chat'), null, v_bot);
  end if;
end;
$$;

-- Called by the page when it opens (p_join) and every few minutes while it's
-- visible, so the bots know someone is around. A quiet room says hello.
create or replace function public.gc_bot_hello(p_join boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_on  boolean;
  v_bot text;
begin
  if v_uid is null or public.gc_is_banned(v_uid) then
    return;
  end if;
  if exists (select 1 from public.rate_events e
             where e.user_id = v_uid and e.action = 'bot_hello'
               and e.created_at > now() - interval '50 seconds') then
    return;
  end if;
  insert into public.rate_events (user_id, action) values (v_uid, 'bot_hello');
  update public.room_state set bots_seen_at = now()
    where id = 1 and (bots_seen_at is null or bots_seen_at < now() - interval '1 minute');

  select r.bots_enabled into v_on from public.room_state r where r.id = 1;
  if not p_join or not coalesce(v_on, false) then
    return;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('gc_bots', 0));
  if exists (select 1 from public.messages m where m.created_at > now() - interval '3 minutes')
     or exists (select 1 from public.bot_pending)
     or exists (select 1 from public.bot_reply_log g
                where g.reason in ('hello', 'greet')
                  and g.at > now() - make_interval(mins => public.gc_setting('bot_greet_minutes'))) then
    return;
  end if;
  v_bot := public.gc_bot_random('hello');
  if v_bot is not null then
    insert into public.bot_reply_log (user_id, reason) values (v_uid, 'hello');
    perform public.gc_bot_queue(v_bot, public.gc_bot_line(v_bot, 'hello'), 'hello', 3);
  end if;
end;
$$;

-- Moderators: switch the bot characters off or on (admin.html).
create or replace function public.gc_mod_set_bots(p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.gc_require_moderator();
  update public.room_state set bots_enabled = coalesce(p_enabled, true), updated_at = now() where id = 1;
  if not coalesce(p_enabled, true) then
    delete from public.bot_pending;
  end if;
  perform public.gc_broadcast_room_state();
end;
$$;

revoke all on function public.gc_bot_line(text, text)                from public, anon, authenticated;
revoke all on function public.gc_bot_random(text)                    from public, anon, authenticated;
revoke all on function public.gc_bot_mentioned(text)                 from public, anon, authenticated;
revoke all on function public.gc_bot_has_topic(text, text)           from public, anon, authenticated;
revoke all on function public.gc_bot_is_crisis(text)                 from public, anon, authenticated;
revoke all on function public.gc_bot_queue(text, text, text, double precision, uuid) from public, anon, authenticated;
revoke all on function public.gc_bot_tick()                          from public, anon, authenticated;
revoke all on function public.gc_bot_hello(boolean)                  from public, anon;
revoke all on function public.gc_mod_set_bots(boolean)               from public, anon;
grant execute on function public.gc_bot_hello(boolean)               to authenticated;
grant execute on function public.gc_mod_set_bots(boolean)            to authenticated;


-- -----------------------------------------------------------------------------
-- 13. Donations
-- -----------------------------------------------------------------------------
-- Optional UPI ID for the "Support GlobalChat" button, kept here instead of
-- in config.js so it isn't in the public code. Set it yourself (don't put it
-- in this file):
--   insert into public.site_settings (key, value) values ('donate_upi', 'you@bank')
--   on conflict (key) do update set value = excluded.value, updated_at = now();
-- Remove it: delete from public.site_settings where key = 'donate_upi';
-- The page gets it only through gc_donate_info() and never shows it as text,
-- but it is inside the pay link and QR code, and a UPI app shows the payee's
-- UPI ID when someone pays. For full privacy use a payment page instead
-- (config.js → DONATE.LINKS).
create table if not exists public.site_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
revoke all on public.site_settings from anon, authenticated;
alter table public.site_settings enable row level security;

create or replace function public.gc_donate_info()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'upi',  (select s.value from public.site_settings s
             where s.key = 'donate_upi'
               and s.value ~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z][A-Za-z0-9.-]{1,63}$'),
    'name', (select left(s.value, 50) from public.site_settings s where s.key = 'donate_name')
  );
$$;
revoke all on function public.gc_donate_info() from public, anon;
grant execute on function public.gc_donate_info() to authenticated;


-- =============================================================================
-- Done. Next: README.md → "Enable Realtime" and "Configure the frontend".
-- =============================================================================
