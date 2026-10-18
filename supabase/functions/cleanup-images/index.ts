// =============================================================================
// GlobalChat — cleanup-images Edge Function
//
// Deletes image files that no live message uses any more: images whose
// message expired or was deleted, and uploads that were never sent. Files
// that are evidence for an open report are kept (see gc_dead_images() in
// schema.sql).
//
// Supabase doesn't allow deleting Storage files with SQL, so the pg_cron
// job can't do this part. Schedule this function every 10 minutes instead:
// README → "Image cleanup".
//
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically to
// Edge Functions; nothing to configure.
// =============================================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';

const BUCKET = 'chat-images';
const BATCH = 100;

Deno.serve(async () => {
  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  const { data, error } = await sb.rpc('gc_dead_images');
  if (error) {
    console.error('gc_dead_images failed', error);
    return Response.json({ error: error.message }, { status: 500 });
  }

  const names: string[] = (data ?? []).map((row: unknown) =>
    typeof row === 'string' ? row : (row as { gc_dead_images: string }).gc_dead_images);

  let removed = 0;
  for (let i = 0; i < names.length; i += BATCH) {
    const { data: gone, error: removeError } = await sb.storage.from(BUCKET).remove(names.slice(i, i + BATCH));
    if (removeError) {
      console.error('remove failed', removeError);
      return Response.json({ removed, error: removeError.message }, { status: 500 });
    }
    removed += gone?.length ?? 0;
  }

  return Response.json({ removed });
});
