\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-000000000001'),('bbbbbbbb-0000-0000-0000-000000000002'),('cccccccc-0000-0000-0000-000000000003');
insert into auth.users(id,is_anonymous) values ('dddddddd-0000-0000-0000-000000000004', false);
insert into public.moderators values ('dddddddd-0000-0000-0000-000000000004'), ('cccccccc-0000-0000-0000-000000000003');

\echo '--- T1 guest A sends; server sets timestamps, normalises text'
set role authenticated;
select set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Ghost_4821', E'  hello\r\n\n\n\nworld \u202Eevil  ') returning username, replace(content,E'\n','\\n'), (expires_at - created_at) as ttl;

\echo '--- T2 client cannot set expires_at / user_id (expect permission denied x2)'
insert into public.messages(username, content, expires_at) values ('Ghost_4821','x', now()+interval '9 days');
insert into public.messages(user_id, username, content) values ('bbbbbbbb-0000-0000-0000-000000000002','Ghost_4821','x');

\echo '--- T3 user_id not readable (expect permission denied), public columns readable'
select user_id from public.messages;
select count(*) as visible from (select id, username, content from public.messages) s;

\echo '--- T4 empty / whitespace-only / too long (expect 3 errors)'
insert into public.messages(username, content) values ('Ghost_4821', E'   \n  ');
insert into public.messages(username, content) values ('Ghost_4821', repeat('a',501));
insert into public.messages(username, content) values ('bad name!', 'hi');

\echo '--- T5 rate limit: 4 more ok (5 total in window), 6th RATE_LIMITED'
insert into public.messages(username, content) values ('Ghost_4821','m2');
insert into public.messages(username, content) values ('Ghost_4821','m3');
insert into public.messages(username, content) values ('Ghost_4821','m4');
insert into public.messages(username, content) values ('Ghost_4821','m5');
insert into public.messages(username, content) values ('Ghost_4821','m6');

\echo '--- T6 guest B: duplicate detection + username ownership'
select set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Ghost_4821','I am Ghost now');
insert into public.messages(username, content) values ('QuietFox_1937','<script>alert(1)</script>') returning username, content;
insert into public.messages(username, content) values ('QuietFox_1937','<SCRIPT>alert(1)</SCRIPT>');
\echo '--- T6b B tries to switch name: stored name wins'
insert into public.messages(username, content) values ('Cosmic_7251','switched?') returning username;

\echo '--- T7 B cannot update or delete A messages (expect error, then DELETE 0)'
update public.messages set content='hacked';
delete from public.messages;
select count(*) as still_there from public.messages;

\echo '--- T8 reports: B reports A; cannot read back; self-report and duplicate rejected'
insert into public.reports(message_id, reason, details) select id, 'harassment', E'  rude \u0007 ' from public.messages where username='Ghost_4821' and content='m2';
select count(*) as reports_visible_to_reporter from public.reports;
insert into public.reports(message_id, reason) select id, 'spam' from public.messages where username='QuietFox_1937' limit 1;
insert into public.reports(message_id, reason) select id, 'spam' from public.messages where username='Ghost_4821' and content='m2';
insert into public.reports(message_id, reason) select id, 'not-a-reason' from public.messages where username='Ghost_4821' and content='m3';
insert into public.reports(reason, details) values ('other', repeat('x',501));

\echo '--- T9 anonymous user listed as moderator is NOT a moderator'
select set_config('request.jwt.claims','{"sub":"cccccccc-0000-0000-0000-000000000003","role":"authenticated","is_anonymous":true}',false);
select public.is_moderator() as anon_is_mod;
select count(*) from public.reports;

\echo '--- T10 real moderator reads report snapshot, deletes message (broadcast)'
select set_config('request.jwt.claims','{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated","is_anonymous":false}',false);
select reporter_id is not null, reported_username, reported_content, details, status from public.reports;
delete from public.messages where content='m2';
insert into public.banned_users(user_id, reason) values ('bbbbbbbb-0000-0000-0000-000000000002','test');

\echo '--- T11 banned B cannot post'
select set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('QuietFox_1937','still here?');

\echo '--- T12 unauthenticated + anon role'
select set_config('request.jwt.claims','',false);
insert into public.messages(username, content) values ('Ghost_4821','no auth');
reset role; set role anon;
select count(*) from public.messages;
reset role;

\echo '--- T13 realtime.messages policies'
set role authenticated;
select set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated","is_anonymous":true}',false);
select set_config('realtime.topic','room:global',false);
insert into realtime.messages(topic, extension, payload) values ('room:global','presence','{}');
insert into realtime.messages(topic, extension, payload, event) values ('room:global','broadcast','{"content":"forged"}','message_created');
select set_config('realtime.topic','room:other',false);
insert into realtime.messages(topic, extension, payload) values ('room:other','presence','{}');
reset role;

\echo '--- T14 broadcasts emitted by DB (payload has no user_id)'
select event, payload ? 'user_id' as leaks_user_id, payload->>'username' from realtime.messages where extension='broadcast' order by id;

\echo '--- T15 expiry: age a message, it disappears for guests, cleanup deletes it'
set session_replication_role = replica;
update public.messages set created_at = now()-interval '2 hours', expires_at = now()-interval '1 hour' where content='m3';
set session_replication_role = default;
set role authenticated;
select set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated","is_anonymous":true}',false);
select count(*) as m3_visible from public.messages where content='m3';
reset role;
select count(*) as broadcasts_before from realtime.messages where event='message_deleted';
select public.gc_cleanup();
select count(*) as m3_rows_after_cleanup from public.messages where content='m3';
select count(*) as delete_broadcasts_after_should_be_1 from realtime.messages where event='message_deleted';
