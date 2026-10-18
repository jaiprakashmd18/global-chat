-- Tests for replies, images, polls, reactions and delete-own.
-- Run after security-tests.sql (see run.sh). Expectations are in each \echo.
\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users(id) values ('eeeeeeee-0000-0000-0000-000000000005'),('ffffffff-0000-0000-0000-000000000006');
set role authenticated;

\echo '--- F1 E sends a text message, F replies to it (expect reply_to set)'
select set_config('request.jwt.claims','{"sub":"eeeeeeee-0000-0000-0000-000000000005","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content) values ('Echo_1111','original') returning kind;
select set_config('request.jwt.claims','{"sub":"ffffffff-0000-0000-0000-000000000006","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content, reply_to)
  select 'Fern_2222', 'a reply', id from public.messages where content = 'original'
  returning (reply_to is not null) as has_reply;

\echo '--- F2 reply to a missing message (expect REPLY_NOT_FOUND)'
insert into public.messages(username, content, reply_to) values ('Fern_2222','x', gen_random_uuid());

\echo '--- F3 poll validation (expect INVALID_POLL x3, then one poll with trimmed options)'
insert into public.messages(username, content, kind, poll_options) values ('Fern_2222','Q?', 'poll', array['only one']);
insert into public.messages(username, content, kind, poll_options) values ('Fern_2222','Q?', 'poll', array['a','A']);
insert into public.messages(username, content, kind, poll_options) values ('Fern_2222','Q?', 'poll', array['a','b','c','d','e']);
insert into public.messages(username, content, kind, poll_options) values ('Fern_2222','Tea or coffee?', 'poll', array['  Tea ','Coffee'])
  returning kind, poll_options;

\echo '--- F4 text message cannot smuggle poll/image fields (expect nulls)'
insert into public.messages(username, content, kind, poll_options, image_path) values ('Fern_2222','plain', 'text', array['x','y'], 'zzz')
  returning kind, poll_options is null, image_path is null;

\echo '--- F5 image: path not uploaded / other users folder (expect INVALID_IMAGE x2)'
insert into public.messages(username, content, kind, image_path) values ('Fern_2222','', 'image', 'ffffffff-0000-0000-0000-000000000006/11111111-1111-1111-1111-111111111111.png');
insert into public.messages(username, content, kind, image_path) values ('Fern_2222','', 'image', 'eeeeeeee-0000-0000-0000-000000000005/11111111-1111-1111-1111-111111111111.png');

\echo '--- F6 storage: upload into own folder ok, other folder / bad name blocked (expect INSERT, then 2 RLS errors)'
insert into storage.objects(bucket_id, name) values ('chat-images','ffffffff-0000-0000-0000-000000000006/22222222-2222-2222-2222-222222222222.png');
insert into storage.objects(bucket_id, name) values ('chat-images','eeeeeeee-0000-0000-0000-000000000005/33333333-3333-3333-3333-333333333333.png');
insert into storage.objects(bucket_id, name) values ('chat-images','ffffffff-0000-0000-0000-000000000006/evil.html');

\echo '--- F7 file not readable before a message uses it (expect 0), image message ok with empty caption, then readable (expect 1)'
select count(*) from storage.objects where bucket_id = 'chat-images';
insert into public.messages(username, content, kind, image_path) values ('Fern_2222','', 'image', 'ffffffff-0000-0000-0000-000000000006/22222222-2222-2222-2222-222222222222.png') returning kind, content = '';
select count(*) from storage.objects where bucket_id = 'chat-images';

\echo '--- F8 the same file cannot be sent twice (expect unique violation)'
select set_config('request.jwt.claims','{"sub":"ffffffff-0000-0000-0000-000000000006","role":"authenticated","is_anonymous":true}',false);
insert into public.messages(username, content, kind, image_path) values ('Fern_2222','again', 'image', 'ffffffff-0000-0000-0000-000000000006/22222222-2222-2222-2222-222222222222.png');

\echo '--- F9 reactions: toggle on, toggle off, invalid emoji, tables not readable (expect {"❤️": 1}, {}, INVALID_REACTION, 2x permission denied)'
select public.gc_toggle_reaction((select id from public.messages where content='original'), '❤️') -> 'reactions';
select set_config('request.jwt.claims','{"sub":"eeeeeeee-0000-0000-0000-000000000005","role":"authenticated","is_anonymous":true}',false);
select public.gc_toggle_reaction((select id from public.messages where content='original'), '🔥') -> 'mine';
select public.gc_toggle_reaction((select id from public.messages where content='original'), '🔥') -> 'reactions';
select public.gc_toggle_reaction((select id from public.messages where content='original'), '💩');
select * from public.reactions;
select * from public.poll_votes;

\echo '--- F10 votes: E votes 1, F votes 0, E changes to 0, E repeats 0 = retract, bad option (expect [0,1] [1,1] [2,0] [1,0] then INVALID_OPTION)'
select public.gc_vote((select id from public.messages where kind='poll'), 1) -> 'counts';
select set_config('request.jwt.claims','{"sub":"ffffffff-0000-0000-0000-000000000006","role":"authenticated","is_anonymous":true}',false);
select public.gc_vote((select id from public.messages where kind='poll'), 0) -> 'counts';
select set_config('request.jwt.claims','{"sub":"eeeeeeee-0000-0000-0000-000000000005","role":"authenticated","is_anonymous":true}',false);
select public.gc_vote((select id from public.messages where kind='poll'), 0) -> 'counts';
select public.gc_vote((select id from public.messages where kind='poll'), 0);
select public.gc_vote((select id from public.messages where kind='poll'), 7);
select public.gc_vote((select id from public.messages where content='original'), 0);

\echo '--- F11 extras: counts + own choices, no user ids (expect reaction + poll entries)'
select jsonb_pretty(public.gc_message_extras(array(select id from public.messages)));

\echo '--- F12 reaction rate limit (expect RATE_LIMITED once the 30/min budget is spent)'
do $$ begin
  for i in 1..40 loop
    perform public.gc_toggle_reaction((select id from public.messages where content='original'), '👍');
  end loop;
end $$;

\echo '--- F13 delete own: F cannot delete E message (MESSAGE_NOT_FOUND); E can (broadcast message_deleted); reply survives with reply_to cleared'
select set_config('request.jwt.claims','{"sub":"ffffffff-0000-0000-0000-000000000006","role":"authenticated","is_anonymous":true}',false);
select public.gc_delete_my_message((select id from public.messages where content='original'));
select set_config('request.jwt.claims','{"sub":"eeeeeeee-0000-0000-0000-000000000005","role":"authenticated","is_anonymous":true}',false);
select public.gc_delete_my_message((select id from public.messages where content='original'));
select content, reply_to is null as reply_cleared from public.messages where content = 'a reply';

\echo '--- F14 anon role cannot call feature functions (expect permission denied x2)'
reset role;
set role anon;
select public.gc_toggle_reaction(gen_random_uuid(), '❤️');
select public.gc_delete_my_message(gen_random_uuid());
reset role;

\echo '--- F15 broadcasts carry new fields, never user ids (expect reactions/votes/deleted events, f for user_id)'
select event, payload ? 'user_id' as leaks_user_id, coalesce(payload->>'kind', '') from realtime.messages
where event in ('message_reactions','poll_votes','message_deleted') or payload->>'kind' in ('poll','image')
order by id;

\echo '--- F16 dead images: age the image, expire its message, cleanup function lists it (expect 1 name)'
update storage.objects set created_at = now() - interval '2 hours';
alter table public.messages disable trigger messages_block_update;
update public.messages set created_at = now() - interval '2 hours', expires_at = now() - interval '1 hour' where kind = 'image';
alter table public.messages enable trigger messages_block_update;
set role service_role;
select count(*) from public.gc_dead_images();
reset role;

\echo '--- F17 cleanup with replies/reactions/votes attached: expire everything, run gc_cleanup (expect 0 messages, 0 reactions, 0 votes, no error)'
alter table public.messages disable trigger messages_block_update;
update public.messages set created_at = now() - interval '2 hours', expires_at = now() - interval '1 hour';
alter table public.messages enable trigger messages_block_update;
select public.gc_cleanup();
select (select count(*) from public.messages), (select count(*) from public.reactions), (select count(*) from public.poll_votes);
