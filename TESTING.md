# GlobalChat test checklist

Run these against your real Supabase project, locally first and then on the deployed site. Use two separate browser windows (for example a normal and a private window) as "Guest A" and "Guest B".

Fill these in for the commands below:

```bash
export SB_URL="https://<project-ref>.supabase.co"
export SB_KEY="<anon-or-publishable-key>"
```

## What was verified before handoff

These were run while building the project, without a live Supabase project:

- `schema.sql` applied (twice, to confirm it's re-runnable) on PostgreSQL 16 with stand-ins for Supabase's `auth` and `realtime` schemas, and 15 groups of security tests passed: permissions, validation, rate limiting (including 20 parallel inserts from one guest → exactly 5 accepted), duplicate detection, name ownership, bans, reports, moderator checks, Realtime policies, expiry, and cleanup. Re-run them with `tests/local-db/run.sh`.
- The UI ran in headless Chromium against a mocked Supabase client, under the production CSP, at desktop and phone sizes: 31 checks passed, including XSS rendering, de-duplication, grouping, cooldown, jump-to-latest, expiry removal, reporting, and reconnection.

What those can't prove is the integration with a real Supabase project: actual anonymous sign-in, Realtime delivery and presence, pg_cron, and Turnstile. That's what this checklist is for.

## 1. First-time anonymous sign-in

- [ ] Open the site. Status goes from **Connecting** to **Live**, and a name like `QuietFox_1937` appears in the sidebar and under the message box. No form is shown.
- [ ] Supabase → **Authentication → Users** shows a new user marked anonymous.
- [ ] Reload the tab: same name (session lives in `sessionStorage`).
- [ ] Open a **new** tab: different name and a new anonymous user.
- [ ] Duplicate a tab (browser "Duplicate tab"): the copy gets its own new name.

## 2. Sending and receiving in two sessions

- [ ] Guest A sends "hello from A". It appears in A's window marked **you**, and in B's window within about a second, without a refresh.
- [ ] B replies; A sees it.
- [ ] Each message shows name, coloured initial, text, and local time. Hovering the time shows when it disappears.
- [ ] Neither window shows any message twice.
- [ ] Reload B: the last 100 unexpired messages load in order (oldest at top).
- [ ] Scroll up in B, send from A: B shows a **"1 new message"** button instead of jumping. Clicking it scrolls to the bottom.

## 3. Online presence

- [ ] With A and B open, both show **2 people online**.
- [ ] Close B: A drops to 1 within a few seconds.

## 4. Validation

- [ ] The send button is disabled for an empty or whitespace-only box.
- [ ] Type 501 characters: the counter turns red and sending is disabled.
- [ ] Shift+Enter adds a new line; Enter sends. Line breaks are preserved in the sent message.
- [ ] Emoji count as one character each.

## 5. Database rate limiting

- [ ] In the UI, send 6 messages quickly: after 5 the box shows a countdown and the button is disabled.
- [ ] Server side (bypassing the UI's cooldown), in the browser console on the site:

```js
// Paste in DevTools console on the GlobalChat page
const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/+esm');
const { CONFIG } = await import('/config.js');
const sb = createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
await sb.auth.signInAnonymously();
const results = await Promise.all([...Array(10)].map((_, i) =>
  sb.from('messages').insert({ username: 'Tester_1234', content: 'burst ' + i })));
console.log(results.map(r => r.error?.message ?? 'ok'));
// Expect: 5 × "ok", 5 × "RATE_LIMITED"
```

- [ ] Send the same text twice within a minute: second is rejected with "You just sent that."

## 6. Unauthorized database access

Without signing in (anon key only):

```bash
curl -s "$SB_URL/rest/v1/messages?select=id,content" \
  -H "apikey: $SB_KEY" -H "Authorization: Bearer $SB_KEY"
# Expect: permission denied (code 42501), not message data
```

Signed in as a guest (use the console client from step 5):

```js
await sb.from('messages').select('user_id');                       // permission denied
await sb.from('messages').select('*');                             // permission denied (user_id not granted)
await sb.from('messages').insert({ username: 'Tester_1234', content: 'x', expires_at: '2099-01-01' }); // permission denied
await sb.from('messages').update({ content: 'hacked' }).neq('id', '00000000-0000-0000-0000-000000000000'); // permission denied
const del = await sb.from('messages').delete().neq('id', '00000000-0000-0000-0000-000000000000').select('id');
console.log(del.data);                                             // [] — nothing deleted
await sb.from('reports').select('*');                              // [] — reports invisible to guests
await sb.from('guest_names').select('*');                          // permission denied
await sb.rpc('gc_cleanup');                                        // permission denied
```

- [ ] Try to forge a live chat event from the console:

```js
const ch = sb.channel('room:global', { config: { private: true } });
await sb.realtime.setAuth((await sb.auth.getSession()).data.session.access_token);
ch.subscribe(async (s) => { if (s === 'SUBSCRIBED') console.log(await ch.send({ type: 'broadcast', event: 'message_created', payload: { id: 'x', username: 'Admin_0001', content: 'fake', created_at: new Date().toISOString(), expires_at: new Date(Date.now()+3.6e6).toISOString() } })); });
// Expect: the fake message does NOT appear in other windows
```

- [ ] Supabase → **Database → Advisors → Security Advisor** shows no RLS warnings for GlobalChat tables.

## 7. Expiry and deletion

Messages are immutable, so to test without waiting an hour, temporarily disable the update guard in **SQL Editor**:

```sql
alter table public.messages disable trigger messages_block_update;
update public.messages
set created_at = now() - interval '61 minutes', expires_at = now() - interval '1 minute'
where id = (select id from public.messages order by created_at desc limit 1);
alter table public.messages enable trigger messages_block_update;
```

- [ ] Within about 15 seconds the message fades out of open windows; after a reload it's gone.
- [ ] It still exists in the table until cleanup: `select count(*) from public.messages where expires_at <= now();`
- [ ] Run `select public.gc_cleanup();` (or wait up to 5 minutes for pg_cron); the count drops to 0.
- [ ] `select * from cron.job_run_details order by start_time desc limit 3;` shows successful runs.
- [ ] Verify the server ignores client expiry: `select expires_at - created_at from public.messages limit 5;` is always `01:00:00`.

## 8. Reports

- [ ] As B, click **Report** on one of A's messages. Choose no reason and submit: "Choose what's wrong with the message."
- [ ] Choose **Spam or scam**, add details, submit: "Report sent."
- [ ] Report the same message again: "You've already reported this message."
- [ ] Your own messages have no Report button.
- [ ] In SQL Editor, `select * from public.reports order by created_at desc limit 1;` shows the snapshot fields filled in.
- [ ] Delete the reported message in SQL Editor: it disappears live in all windows.

## 9. Mobile

On a real phone (iOS Safari and Android Chrome if possible):

- [ ] Layout fits with no sideways scrolling. Header shows title, online count, and info button.
- [ ] Tapping the box opens the keyboard without hiding the box or the latest message.
- [ ] The info button opens the privacy dialog; it scrolls and closes.
- [ ] Report buttons are visible without hover.
- [ ] Bottom of the composer clears the home indicator.

## 10. Network interruption

- [ ] DevTools → Network → **Offline**: status shows **Offline** and a red banner. Typing still works; sending shows an offline message and keeps the text.
- [ ] Go back online: status returns to **Live**. Messages sent by others while you were offline appear.
- [ ] Put a laptop to sleep for a few minutes, wake it: the tab reconnects (switching away and back to the tab triggers a reconnect check).

## 11. Safe rendering

Send each of these and confirm they show as plain text and nothing executes:

```
<img src=x onerror=alert(1)>
<script>alert('xss')</script>
"><svg onload=alert(1)>
javascript:alert(1)
**bold?** [link](http://example.com)
‮reversed-text-attack
```

- [ ] No alert appears; the text is shown literally (the right-to-left override character in the last line is stripped by the server).
- [ ] A 500-character string with no spaces wraps instead of widening the page.

## 12. Turnstile (after enabling)

- [ ] A new tab shows "Quick check before you join" before the chat connects.
- [ ] Removing `TURNSTILE_SITE_KEY` from `config.js` while CAPTCHA is on in Supabase makes sign-in fail with a clear message (proves the check is enforced server-side). Restore it afterwards.

## Replies, reactions, polls, images and deleting

Use Guest A and Guest B as above, after re-running `schema.sql` and deploying the `cleanup-images` function.

- [ ] **Reply:** A hovers B's message → **Reply**, sends. A's message shows a quote of B's; clicking it scrolls to and flashes the original. B's copy of A's reply is highlighted as "for you".
- [ ] **Reactions:** B reacts ❤️ to A's message. A sees `❤️ 1` within a second. B clicks the chip again: it disappears for both. Spam-click reactions: after about 30 in a minute you get "Slow down".
- [ ] **Poll:** A → **+ → Poll**, 3 options, posts. B votes; A sees the percentages change live. B taps the same option again: the vote is removed. B taps another: the vote moves.
- [ ] **Image:** A → **+ → Photo or GIF** (also try paste and drag-and-drop). The preview shows above the box; send with and without a caption. B sees it within a second; clicking opens the full-size viewer.
- [ ] **Image privacy:** right-click the image → copy image address. It's a `…/object/sign/chat-images/…?token=…` link, not a public URL. After the message expires (or is deleted and you request a new link), Storage returns an error.
- [ ] **Image metadata:** send a phone photo with location data, download it from the chat and check its details: there's no GPS info.
- [ ] **Bad files:** a 6 MB GIF or a PDF is refused with a clear message.
- [ ] **Delete:** A deletes their own message (trash icon → Delete). It disappears for both. B has no delete button on A's messages. A reply to the deleted message now says "Original message is no longer available".
- [ ] **Cleanup:** an hour after sending an image, **Storage → chat-images** no longer has the file once `cleanup-images` has run (check its Logs).
- [ ] **Old database:** with the new page against a database that hasn't been upgraded, plain messages still send and the **+**, reply, react and delete buttons are hidden.

Run the database part locally with `tests/local-db/run.sh`; the `--- F` sections in `feature-tests.sql` cover these rules.

## Community features

After re-running `schema.sql` (and `check-setup.sql` shows all OK):

- [ ] **Name:** sidebar → Change name → "Jai" → you become `Jai_####`; your earlier messages still show as yours. A name with a swear word is refused.
- [ ] **Formatting:** send `*bold* _italic_ \`code\` ||spoiler||`; the spoiler reveals on tap. `snake_case` stays as typed.
- [ ] **Times:** new messages say "now", then "1m ago"…; a message in its last 10 minutes shows "⏳ Nm left".
- [ ] **Edit:** send a typo, use the pencil within 2 minutes, fix it: everyone sees "edited". After 2 minutes the pencil is gone.
- [ ] **Mute:** ⋯ → Mute on someone: their messages collapse ("Show" reveals one). Unmute in Appearance & alerts.
- [ ] **Sounds / drafts / themes:** turn on "Soft sound for every new message"; type, reload: the draft is back; try AMOLED, High contrast and Neon.
- [ ] **Confetti:** someone sends "happy birthday" → confetti (not with reduced motion turned on).
- [ ] **Install:** browser menu → Install / Add to Home Screen works on the deployed HTTPS site.
- [ ] **Flags:** choose a country in settings: your flag shows on new messages, in the online list and in "Where people are".
- [ ] **Stickers / voice:** + → Sticker sends a sticker. + → Voice note asks for the microphone, records up to 30 s, and plays for others.
- [ ] **Commands:** `/roll`, `/roll 20`, `/flip`, `/8ball Will it rain?` come back with a "/roll" (etc.) badge. Typing "🎲 rolled 6" by hand gets no badge.
- [ ] **Word filter:** a message with a listed word arrives masked (`f***`).
- [ ] **Auto-hide:** three different guests report one message → it disappears for guests and appears as HIDDEN on the admin page.
- [ ] **Admin page:** sign in at `/admin.html` with a moderator account; pin a message (📌 bar appears for everyone), turn on slow mode (🐢 banner, second message is refused), unhide, delete, ban, add/remove a filter word.
- [ ] **Room bot:** while people are chatting, a 🧠 trivia question appears within 15 minutes; the first right answer gets a 🎉 reply. The ☀️ question of the day posts at 12:03 UTC and shows in the sidebar.
- [ ] **Stats / word of the day:** the sidebar shows today's messages and people, and a word of the day.
- [ ] **Share:** the share button opens the share sheet (phone) or copies the link (desktop). Pasting the link in WhatsApp shows the preview card once `og:image` has your full URL.
- [ ] **Translate:** ⋯ → Translate translates in place (Chrome with the built-in translator) or opens Google Translate.

`tests/local-db/community-tests.sql` (run by `tests/local-db/run.sh`) covers the database side: commands, word filter, stickers, voice, flags, editing, renaming, slow mode, pin, auto-hide, bans, trivia, question of the day and cleanup.
