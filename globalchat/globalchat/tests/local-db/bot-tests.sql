-- Tests for the bot characters (schema.sql section 12).
-- Run after community-tests.sql (see run.sh).
\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users(id) values
  ('b0000000-0000-0000-0000-000000000001'),('b0000000-0000-0000-0000-000000000002'),
  ('b0000000-0000-0000-0000-000000000003'),('b0000000-0000-0000-0000-000000000004');
update public.room_state set slow_mode_seconds = 0, bots_enabled = true, bots_seen_at = null;
delete from public.bot_pending;
delete from public.bot_reply_log;
delete from public.messages;

\echo '--- B1 content: 10 characters, about 300 lines, 14 conversations, every kind for everyone (expect 10, t, 14, 0, 0, 0)'
select count(*) from public.bot_characters;
select count(*) >= 290 from public.bot_lines;
select count(*) from public.bot_dialogues;
select count(*) from public.bot_characters c, (values ('greet'), ('hello'), ('chat'), ('topic'), ('mention')) k(kind)
  where not exists (select 1 from public.bot_lines l where l.bot_id = c.id and l.kind = k.kind);
select count(*) from public.bot_dialogues d, jsonb_array_elements(d.steps) s
  where not exists (select 1 from public.bot_characters c where c.id = s ->> 0) or char_length(s ->> 1) > 440;
select count(*) from public.bot_lines where kind = 'greet' and content not like '%{name}%';

\echo '--- B2 guests: no bot_id, no bot tables, no bot internals (expect permission denied x5)'
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content, bot_id) values ('Bea_1001','fake luna', 'luna');
select count(*) from public.bot_lines;
select count(*) from public.bot_pending;
select public.gc_bot_tick();
select public.gc_bot_post('fake', null, 'luna');

\echo '--- B3 first message of the hour gets a welcome from a character (expect t, t, t), sent by the tick with bot_id (expect t, t)'
insert into public.messages(username, content) values ('Bea_1001','hello everyone') returning content;
reset role;
select reason = 'greet', content like '%@Bea_1001%', reply_to is not null from public.bot_pending;
update public.bot_pending set due_at = now();
select public.gc_bot_tick();
select bot_id is not null, username = 'GlobalBot_0000' from public.messages where is_bot;
select (payload ->> 'bot_id') is not null from realtime.messages
  where event = 'message_created' and (payload ->> 'is_bot')::boolean order by id desc limit 1;

\echo '--- B4 @mention gets that character; topic words pick a topic line; cooldown stops a second (expect luna reply t, then 0 pending)'
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Bea_1001','@luna what music do you like?') returning content;
reset role;
select p.bot_id, p.reason, p.content like '@Bea_1001 %',
       exists (select 1 from public.bot_lines l where l.bot_id = 'luna' and l.kind = 'topic' and p.content = '@Bea_1001 ' || l.content)
from public.bot_pending p;
delete from public.bot_pending;
set role authenticated;
insert into public.messages(username, content) values ('Bea_1001','@Luna again please') returning content;
reset role;
select count(*) from public.bot_pending;

\echo '--- B5 replying to a character''s message gets that character (expect the same bot id twice)'
delete from public.bot_reply_log where reason = 'reply';
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content, reply_to)
  values ('Bea_1001','thanks bot', (select id from public.messages where is_bot order by created_at desc limit 1))
  returning content;
reset role;
select (select bot_id from public.messages where is_bot order by created_at desc limit 1), (select bot_id from public.bot_pending);
delete from public.bot_pending;

\echo '--- B6 topic matching and crisis detection (expect t, f, t, t, f)'
select public.gc_bot_has_topic('nova', 'Did you see the black hole picture?');
select public.gc_bot_has_topic('nova', 'spacebar is broken');
select public.gc_bot_has_topic('arjun', 'I love BIRYANI!!');
select public.gc_bot_is_crisis('i want to end my life');
select public.gc_bot_is_crisis('this exam is killing me lol');

\echo '--- B7 crisis message: Zen answers at once with helplines, once per 10 min; with bots off the room bot answers (expect zen t t, 1, null t)'
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000002","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Cal_2002','i want to kill myself') returning content;
reset role;
select bot_id, content like '@Cal_2002 %', content like '%14416%' from public.messages where is_bot and content like '%14416%';
set role authenticated;
insert into public.messages(username, content) values ('Cal_2002','i still want to die') returning content;
reset role;
select count(*) from public.messages where is_bot and content like '%14416%';
update public.room_state set bots_enabled = false;
delete from public.bot_reply_log where reason = 'crisis';
set role authenticated;
insert into public.messages(username, content) values ('Cal_2002','thinking about suicide') returning content;
reset role;
select bot_id, content like '%findahelpline.com%' from public.messages
  where is_bot and content like '%14416%' order by created_at desc limit 1;
update public.room_state set bots_enabled = true;

\echo '--- B8 bots off: no greetings, no mention replies, tick sends nothing (expect 0, 0)'
update public.room_state set bots_enabled = false;
delete from public.bot_reply_log;
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000003","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Dot_3003','@pixel tell me a joke') returning content;
reset role;
select count(*) from public.bot_pending;
insert into public.bot_pending (bot_id, content, reason, due_at) values ('pixel', 'queued before switch-off', 'chat', now());
select public.gc_bot_tick();
select count(*) from public.messages where content = 'queued before switch-off';
update public.room_state set bots_enabled = true;

\echo '--- B9 page hello: marks someone around; quiet room gets one hello; repeat calls are no-ops (expect t, 1, 1)'
reset role;
alter table public.messages disable trigger messages_block_update;
update public.messages set created_at = now() - interval '10 minutes';
alter table public.messages enable trigger messages_block_update;
delete from public.bot_reply_log;
delete from public.bot_pending;
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":true}',false);
select public.gc_bot_hello(true);
select public.gc_bot_hello(true);
reset role;
select bots_seen_at > now() - interval '1 minute' from public.room_state;
select count(*) from public.bot_pending where reason = 'hello';
delete from public.rate_events where action = 'bot_hello';
set role authenticated;
select public.gc_bot_hello(true);
reset role;
select count(*) from public.bot_pending where reason = 'hello';

\echo '--- B10 quiet room with someone around: small talk and a scripted conversation (expect t, t)'
delete from public.bot_pending;
create temp table tick_log (chat integer, dialogue integer);
do $$
declare i integer;
begin
  for i in 1..60 loop
    alter table public.messages disable trigger messages_block_update;
    update public.messages set created_at = now() - interval '10 minutes';
    alter table public.messages enable trigger messages_block_update;
    delete from public.bot_pending;
    perform public.gc_bot_tick();
  end loop;
end $$;
select count(*) > 5 from public.messages where is_bot and bot_id is not null and reply_to is null;
select count(*) >= 1 from public.bot_dialogues where last_used_at is not null;

\echo '--- B11 nobody around for 20 minutes: no small talk (expect 0)'
update public.room_state set bots_seen_at = now() - interval '1 hour';
alter table public.messages disable trigger messages_block_update;
update public.messages set created_at = now() - interval '30 minutes';
alter table public.messages enable trigger messages_block_update;
create temp table before_count as select count(*) as n from public.messages;
do $$ begin for i in 1..20 loop perform public.gc_bot_tick(); end loop; end $$;
select (select count(*) from public.messages) - n from before_count;

\echo '--- B12 a busy room drops queued small talk (expect 0)'
insert into public.bot_pending (bot_id, content, reason, due_at) values ('mia', 'later chatter', 'dialogue', now() + interval '1 minute');
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Eve_4004','one'), ('Eve_4004','two'), ('Eve_4004','three') returning content;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000003","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Dot_3003','four') returning content;
reset role;
select count(*) from public.bot_pending where reason = 'dialogue';

\echo '--- B13 every line is used once before any repeats (expect t)'
update public.bot_lines set last_used_at = null where bot_id = 'pixel' and kind = 'chat';
select count(distinct x) = (select count(*) from public.bot_lines where bot_id = 'pixel' and kind = 'chat')
from (select public.gc_bot_line('pixel', 'chat') as x from generate_series(1, (select count(*)::integer from public.bot_lines where bot_id = 'pixel' and kind = 'chat'))) s;

\echo '--- B14 moderator switch: guests refused; moderator off/on is broadcast in room state (expect NOT_MODERATOR, false, true)'
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated","is_anonymous":true}',false);
select public.gc_mod_set_bots(false);
select set_config('request.jwt.claims','{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":false}',false);
select public.gc_mod_set_bots(false);
select public.gc_room_state() ->> 'bots_enabled';
select public.gc_mod_set_bots(true);
reset role;
select payload ->> 'bots_enabled' from realtime.messages where event = 'room_state' order by id desc limit 1;

\echo '--- B15 cleanup with bot data attached (expect no error)'
select public.gc_cleanup();
reset role;

\echo '--- D1 donation UPI ID: hidden from guests except via gc_donate_info; junk ignored (expect permission denied, null, ok@bank, null)'
set role authenticated;
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated","is_anonymous":true}',false);
select count(*) from public.site_settings;
select public.gc_donate_info() ->> 'upi';
reset role;
insert into public.site_settings (key, value) values ('donate_upi', 'ok@bank') on conflict (key) do update set value = excluded.value;
set role authenticated;
select public.gc_donate_info() ->> 'upi';
reset role;
update public.site_settings set value = 'not a upi id' where key = 'donate_upi';
select public.gc_donate_info() ->> 'upi';
