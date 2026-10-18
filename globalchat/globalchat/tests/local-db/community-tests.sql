-- Tests for the community features (schema.sql section 10).
-- Run after security-tests.sql and feature-tests.sql (see run.sh).
\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users(id) values
  ('11111111-0000-0000-0000-00000000000a'),('22222222-0000-0000-0000-00000000000b'),
  ('33333333-0000-0000-0000-00000000000c'),('44444444-0000-0000-0000-00000000000d'),
  ('55555555-0000-0000-0000-00000000000e');
update public.room_state set slow_mode_seconds = 0, pinned_message_id = null;
set role authenticated;
select set_config('request.jwt.claims','{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","is_anonymous":true}',false);

\echo '--- G1 guests cannot set server-owned columns (expect permission denied x3)'
insert into public.messages(username, content, is_bot) values ('Gina_1000','fake bot', true);
insert into public.messages(username, content, command) values ('Gina_1000','fake roll', 'roll');
insert into public.messages(username, content, hidden) values ('Gina_1000','x', true);

\echo '--- G2 commands run on the server; repeats are not "duplicates" (expect roll 1-20, flip, 8ball with question, roll again ok)'
insert into public.messages(username, content) values ('Gina_1000','/roll d20') returning command, content ~ '^🎲 rolled ([1-9]|1[0-9]|20) \(1–20\)$';
insert into public.messages(username, content) values ('Gina_1000','/flip') returning command, content ~ '^🪙 flipped (heads|tails)$';
insert into public.messages(username, content) values ('Gina_1000','/8ball will it rain?') returning command, content like '🎱 will it rain? → %';
select set_config('request.jwt.claims','{"sub":"22222222-0000-0000-0000-00000000000b","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Hugo_2000','/roll 1') returning command, content;
insert into public.messages(username, content) values ('Hugo_2000','/roll 1') returning command, content;
insert into public.messages(username, content) values ('Hugo_2000','/unknown stays text') returning command is null, content;

\echo '--- G3 word filter: text, poll options; blocked or reserved nicknames rejected (expect masks, then INVALID_USERNAME x2)'
insert into public.messages(username, content) values ('Hugo_2000','what the FUCK, shitty? Shit!') returning content;
insert into public.messages(username, content, kind, poll_options) values ('Hugo_2000','Best word?','poll', array['shit','nice']) returning poll_options;
select set_config('request.jwt.claims','{"sub":"33333333-0000-0000-0000-00000000000c","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('BigShitFox_3000','hi');
insert into public.messages(username, content) values ('GlobalBot_0001','hi');

\echo '--- G4 stickers and voice notes (expect sticker ok, INVALID_STICKER, INVALID_VOICE, then voice ok)'
insert into public.messages(username, content, kind, sticker) values ('Ivy_3000','ignored','sticker','gg') returning kind, sticker, content = '';
insert into public.messages(username, content, kind, sticker) values ('Ivy_3000','','sticker','nope');
insert into public.messages(username, content, kind, image_path) values ('Ivy_3000','','voice','33333333-0000-0000-0000-00000000000c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.webm');
insert into storage.objects(bucket_id, name) values ('chat-images','33333333-0000-0000-0000-00000000000c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.webm');
insert into public.messages(username, content, kind, image_path) values ('Ivy_3000','','voice','33333333-0000-0000-0000-00000000000c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.webm') returning kind;

\echo '--- G5 country flag: normalised, junk dropped (expect IN, then null)'
select pg_sleep(0);
insert into public.messages(username, content, country) values ('Ivy_3000','from india', ' in ') returning country;
insert into public.messages(username, content, country) values ('Ivy_3000','junk country', 'XYZ') returning country is null;

\echo '--- G6 edit: own within 2 min ok + masked; others refused; not after window; not commands (expect content, MESSAGE_NOT_FOUND, EDIT_WINDOW_PASSED, NOT_EDITABLE)'
select public.gc_edit_message((select id from public.messages where content = 'from india'), 'from india, edited shit') ->> 'content';
select (select edited_at is not null from public.messages where content like 'from india, edited%');
select set_config('request.jwt.claims','{"sub":"22222222-0000-0000-0000-00000000000b","role":"authenticated","is_anonymous":true}',false);
select public.gc_edit_message((select id from public.messages where content like 'from india%'), 'hijack');
reset role;
alter table public.messages disable trigger messages_block_update;
update public.messages set created_at = now() - interval '5 minutes' where content like 'what the F%';
alter table public.messages enable trigger messages_block_update;
set role authenticated;
select public.gc_edit_message((select id from public.messages where content like 'what the F%'), 'too late');
select public.gc_edit_message((select id from public.messages where command = 'roll' and username = 'Hugo_2000' limit 1), 'rolled 6 honest');

\echo '--- G7 rename right after posting ok, used for next message; then cooldown, taken, blocked refused (expect Captain_4242 x2, RATE_LIMITED, USERNAME_TAKEN, INVALID_USERNAME, Juno_4000)'
select public.gc_rename('Captain_4242');
insert into public.messages(username, content) values ('Hugo_2000','after rename') returning username;
select public.gc_rename('Captain_4343');
select set_config('request.jwt.claims','{"sub":"44444444-0000-0000-0000-00000000000d","role":"authenticated","is_anonymous":true}',false);
select public.gc_rename('Captain_4242');
select public.gc_rename('Shitface_1111');
select public.gc_rename('Juno_4000');

\echo '--- G8 slow mode: guests cannot set it (NOT_MODERATOR); moderator sets 10 s; second message SLOW_MODE'
select public.gc_mod_set_slow_mode(10);
select set_config('request.jwt.claims','{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":false}',false);
select public.gc_mod_set_slow_mode(10);
select set_config('request.jwt.claims','{"sub":"44444444-0000-0000-0000-00000000000d","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Juno_4000','first') returning content;
insert into public.messages(username, content) values ('Juno_4000','second');
select (public.gc_room_state() ->> 'slow_mode_seconds');
select set_config('request.jwt.claims','{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":false}',false);
select public.gc_mod_set_slow_mode(0);

\echo '--- G9 pin + room state: pinned message, question of the day, stats (expect pinned content, a question, counts > 0)'
select public.gc_mod_pin((select id from public.messages where content = 'first'));
select set_config('request.jwt.claims','{"sub":"44444444-0000-0000-0000-00000000000d","role":"authenticated","is_anonymous":true}',false);
select public.gc_room_state() #>> '{pinned,content}', (public.gc_room_state() ->> 'daily_question') is not null,
       (public.gc_room_state() #>> '{stats,today_messages}')::int > 0, (public.gc_room_state() #>> '{stats,today_people}')::int >= 4;

\echo '--- G10 auto-hide after 3 reports: hidden for guests, visible to moderators, unhide restores (expect 1, 0, 1, 1)'
select set_config('request.jwt.claims','{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","is_anonymous":true}',false);
insert into public.reports(message_id, reason) select id, 'spam' from public.messages where content = 'after rename';
select set_config('request.jwt.claims','{"sub":"33333333-0000-0000-0000-00000000000c","role":"authenticated","is_anonymous":true}',false);
insert into public.reports(message_id, reason) select id, 'spam' from public.messages where content = 'after rename';
select count(*) from public.messages where content = 'after rename';
select set_config('request.jwt.claims','{"sub":"44444444-0000-0000-0000-00000000000d","role":"authenticated","is_anonymous":true}',false);
insert into public.reports(message_id, reason) select id, 'spam' from public.messages where content = 'after rename';
select count(*) from public.messages where content = 'after rename';
select set_config('request.jwt.claims','{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":false}',false);
select count(*) from public.messages where content = 'after rename' and hidden;
select public.gc_mod_set_hidden((select id from public.messages where content = 'after rename'), false);
select set_config('request.jwt.claims','{"sub":"44444444-0000-0000-0000-00000000000d","role":"authenticated","is_anonymous":true}',false);
select count(*) from public.messages where content = 'after rename';

\echo '--- G11 ban author by message (moderator only): banned guest cannot post (expect NOT_MODERATOR, then BANNED)'
select public.gc_mod_ban_author((select id from public.messages where content = 'first'), 60, 'test');
select set_config('request.jwt.claims','{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":false}',false);
select public.gc_mod_ban_author((select id from public.messages where content = 'first'), 60, 'test');
select set_config('request.jwt.claims','{"sub":"44444444-0000-0000-0000-00000000000d","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Juno_4000','am I banned');

\echo '--- G12 guests cannot run bot / cron functions (expect permission denied x3)'
select public.gc_bot_post('fake');
select public.gc_trivia_tick();
select public.gc_post_daily_question();
reset role;

\echo '--- G13 trivia: tick asks a question; wrong then right answer; winner announced as a reply (expect t, then Kai_5000 | t, then t | t | GlobalBot_0000)'
select public.gc_trivia_tick();
select content like '🧠 Trivia time!%' from public.messages where is_bot order by created_at desc limit 1;
select '  The ' || upper(q.answers[1]) || '!! ' as answer
  from public.trivia_rounds r join public.trivia_questions q on q.id = r.question_id
  where r.closed_at is null \gset
set role authenticated;
select set_config('request.jwt.claims','{"sub":"55555555-0000-0000-0000-00000000000e","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Kai_5000','no idea, banana?');
insert into public.messages(username, content) values ('Kai_5000', :'answer');
reset role;
select solved_by, closed_at is not null from public.trivia_rounds order by id desc limit 1;
select content like '🎉 Kai_5000 got it!%', reply_to is not null, username from public.messages where is_bot order by created_at desc limit 1;
\echo '--- G13b next tick within 15 min does not ask again; expired unsolved round is closed with the answer'
select public.gc_trivia_tick();
select count(*) from public.trivia_rounds;
update public.trivia_rounds set asked_at = now() - interval '20 minutes', ends_at = now() - interval '15 minutes', solved_by = null, closed_at = null;
select public.gc_trivia_tick();
select content like '⏰ Time''s up!%' from public.messages where is_bot and content like '⏰%' limit 1;

\echo '--- G14 question of the day posts as the bot; bot rows broadcast with is_bot (expect t, t)'
select public.gc_post_daily_question();
select content like '☀️ Question of the day:%' from public.messages where is_bot and content like '☀️%';
select bool_and((payload->>'is_bot')::boolean) from realtime.messages where event = 'message_created' and payload->>'username' = 'GlobalBot_0000';

\echo '--- G15 word list is moderator-only (guest: RLS error / 0 rows; moderator: insert ok)'
set role authenticated;
select set_config('request.jwt.claims','{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","is_anonymous":true}',false);
insert into public.blocked_words values ('heck');
select count(*) from public.blocked_words;
select set_config('request.jwt.claims','{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":false}',false);
insert into public.blocked_words (word) values ('heck');
reset role;

\echo '--- G16 cleanup with everything attached (expect no error, 0 messages)'
alter table public.messages disable trigger messages_block_update;
update public.messages set created_at = now() - interval '2 hours', expires_at = now() - interval '1 hour';
alter table public.messages enable trigger messages_block_update;
select public.gc_cleanup();
select count(*) from public.messages;

\echo '--- G18 gender label: optional, normalised, junk dropped, bots never have one (expect female, nonbinary, null, null)'
insert into auth.users(id) values ('88888888-0000-0000-0000-000000000010');
set role authenticated;
select set_config('request.jwt.claims','{"sub":"88888888-0000-0000-0000-000000000010","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content, gender) values ('Lia_8000','hi, gender label test', ' Female ') returning gender;
insert into public.messages(username, content, gender) values ('Lia_8000','second gender test', 'nonbinary') returning gender;
insert into public.messages(username, content, gender) values ('Lia_8000','third gender test', 'attack helicopter') returning gender is null;
insert into public.messages(username, content) values ('Lia_8000','fourth: no label') returning gender is null;
reset role;
