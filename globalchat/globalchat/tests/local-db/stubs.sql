-- Minimal stand-ins for Supabase-managed objects
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema auth; create schema realtime;
grant usage on schema auth, realtime, public to anon, authenticated;
create table auth.users (id uuid primary key, is_anonymous boolean default true, created_at timestamptz default now());
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
