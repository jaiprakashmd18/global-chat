-- =============================================================================
-- GlobalChat — setup check
--
-- Paste into Supabase Dashboard → SQL Editor → Run. Read-only: it changes
-- nothing. Every row should say OK. Anything MISSING means schema.sql hasn't
-- been (re-)run successfully: run the whole of schema.sql again and look at
-- the first error it reports.
-- =============================================================================
select item,
       case when ok then 'OK' else 'MISSING' end as status
from (values
  -- Original chat
  ('messages table',                    to_regclass('public.messages') is not null),
  ('message policies',                  exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'messages' and policyname = 'messages: guests insert own')),

  -- Replies, images, polls (new columns + guest access to them)
  ('messages.kind column',              exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'messages' and column_name = 'kind')),
  ('messages.reply_to column',          exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'messages' and column_name = 'reply_to')),
  ('messages.image_path column',        exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'messages' and column_name = 'image_path')),
  ('messages.poll_options column',      exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'messages' and column_name = 'poll_options')),
  ('guests can read the new columns',   exists (select 1 from information_schema.column_privileges where table_schema = 'public' and table_name = 'messages' and column_name = 'poll_options' and grantee = 'authenticated' and privilege_type = 'SELECT')),

  -- Reactions, votes, delete-own
  ('reactions table',                   to_regclass('public.reactions') is not null),
  ('poll_votes table',                  to_regclass('public.poll_votes') is not null),
  ('gc_toggle_reaction()',              to_regprocedure('public.gc_toggle_reaction(uuid,text)') is not null),
  ('gc_vote()',                         to_regprocedure('public.gc_vote(uuid,integer)') is not null),
  ('gc_message_extras()',               to_regprocedure('public.gc_message_extras(uuid[])') is not null),
  ('gc_delete_my_message()',            to_regprocedure('public.gc_delete_my_message(uuid)') is not null),

  -- Images
  ('chat-images storage bucket',        exists (select 1 from storage.buckets where id = 'chat-images')),
  ('storage policy: upload',            exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'chat-images: guests upload own')),
  ('storage policy: view while live',   exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'chat-images: read while live')),
  ('gc_dead_images() for cleanup',      to_regprocedure('public.gc_dead_images()') is not null)
) as checks(item, ok);
