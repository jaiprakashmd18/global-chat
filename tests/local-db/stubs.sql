-- Minimal stand-ins for Supabase-managed objects
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema auth; create schema realtime;
grant usage on schema auth, realtime, public to anon, authenticated;
create table auth.users (id uuid primary key, is_anonymous boolean default true, created_at timestamptz default now() - interval '1 day');  -- test guests are a day old unless a test says otherwise
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true),''),'{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt()->>'sub','')::uuid $$;
grant execute on all functions in schema auth to anon, authenticated;
create table realtime.messages (id bigserial primary key, topic text, extension text, payload jsonb, event text, private boolean, inserted_at timestamptz default now());
grant insert, select on realtime.messages to authenticated;
grant usage on sequence realtime.messages_id_seq to authenticated;
alter table realtime.messages enable row level security;
create function realtime.topic() returns text language sql stable as $$ select current_setting('realtime.topic', true) $$;
create function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void language sql as $$
  insert into realtime.messages(topic, extension, payload, event, private) values (topic,'broadcast',payload,event,private) $$;
-- Supabase-style default privileges
alter default privileges in schema public grant all on tables to anon, authenticated;
-- Storage stand-in (bucket table, objects table, foldername helper)
do $$ begin create role service_role nologin; exception when duplicate_object then null; end $$;
create schema storage;
grant usage on schema storage to anon, authenticated, service_role;
create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner_id text default auth.uid()::text, created_at timestamptz default now());
grant select, insert, delete on storage.objects to authenticated;
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
grant execute on all functions in schema storage to authenticated;
