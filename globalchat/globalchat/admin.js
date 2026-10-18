// =============================================================================
// GlobalChat — admin.js (moderation page)
//
// Moderators are real (non-anonymous) Supabase users listed in
// public.moderators. Every action here is checked again by the database
// (RLS policies and gc_mod_* functions), so this page only offers buttons:
// it grants nothing by itself.
//
// Safety rule, same as app.js: user text is only ever written with
// textContent. There is no innerHTML in this file.
// =============================================================================
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/+esm';
import { CONFIG } from './config.js';

const REFRESH_MS = 30_000;
const $ = (id) => document.getElementById(id);
const el = {
  who: $('admin-who'),
  actions: $('admin-actions'),
  refresh: $('refresh'),
  signOut: $('sign-out'),
  loginCard: $('login-card'),
  loginForm: $('login-form'),
  email: $('email'),
  password: $('password'),
  loginError: $('login-error'),
  loginSubmit: $('login-submit'),
  error: $('admin-error'),
  panels: $('admin-panels'),
  slowMode: $('slow-mode'),
  slowSave: $('slow-save'),
  pinCurrent: $('pin-current'),
  unpin: $('unpin'),
  roomStats: $('room-stats'),
  reports: $('reports'),
  reportsCount: $('reports-count'),
  reportsEmpty: $('reports-empty'),
  messages: $('messages'),
  messagesCount: $('messages-count'),
  wordForm: $('word-form'),
  wordInput: $('word-input'),
  words: $('words'),
  bans: $('bans'),
  bansEmpty: $('bans-empty'),
  toasts: $('toasts'),
};

const sb = createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY, {
  auth: {
    storage: window.localStorage,
    storageKey: 'globalchat.admin',   // separate from guest sessions
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
});

const fmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const time = (iso) => (iso ? fmt.format(new Date(iso)) : '');
let refreshTimer = 0;

// ---- small DOM helpers ------------------------------------------------------
function node(tag, { className, text, attrs } = {}, ...children) {
  const n = document.createElement(tag);
  if (className) n.className = className;
  if (text !== undefined) n.textContent = text;
  for (const [k, v] of Object.entries(attrs ?? {})) n.setAttribute(k, v);
  n.append(...children.filter(Boolean));
  return n;
}

function button(label, onClick, tone = 'quiet') {
  const b = node('button', { className: `button button-${tone} button-sm`, text: label, attrs: { type: 'button' } });
  b.addEventListener('click', async () => {
    b.disabled = true;
    try { await onClick(); } finally { b.disabled = false; }
  });
  return b;
}

function toast(text, tone) {
  const t = node('div', { className: 'toast', text });
  if (tone) t.dataset.tone = tone;
  el.toasts.append(t);
  setTimeout(() => t.remove(), 4500);
}

function showError(text) {
  el.error.textContent = text;
  el.error.hidden = !text;
}

// Run a database call; show a readable error if it fails.
async function run(promise, okText) {
  const { data, error } = await promise;
  if (error) {
    console.error('[GlobalChat admin]', error);
    const msg = String(error.message ?? '');
    toast(msg.includes('NOT_MODERATOR') || error.code === '42501'
      ? 'Not allowed: this account is not a moderator.'
      : msg.includes('NO_AUTHOR') ? 'That message has no guest author (it’s from the bot) or is gone.'
      : `Failed: ${msg || 'unknown error'}`, 'danger');
    return { ok: false };
  }
  if (okText) toast(okText);
  return { ok: true, data };
}

// ---- auth ---------------------------------------------------------------------
async function start() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session || session.user.is_anonymous) { showLogin(); return; }
  await enter(session);
}

function showLogin() {
  clearInterval(refreshTimer);
  el.loginCard.hidden = false;
  el.panels.hidden = true;
  el.actions.hidden = true;
  el.who.textContent = 'Moderators only.';
}

async function enter(session) {
  const { data: isMod, error } = await sb.rpc('is_moderator');
  if (error || !isMod) {
    await sb.auth.signOut();
    showLogin();
    el.loginError.textContent = error
      ? 'Couldn’t check moderator access. Has schema.sql been run?'
      : 'This account isn’t a moderator. Add it to public.moderators first (MODERATION.md).';
    el.loginError.hidden = false;
    return;
  }
  el.loginCard.hidden = true;
  el.panels.hidden = false;
  el.actions.hidden = false;
  el.who.textContent = `Signed in as ${session.user.email ?? 'moderator'}`;
  await refresh();
  clearInterval(refreshTimer);
  refreshTimer = setInterval(refresh, REFRESH_MS);
}

el.loginForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  el.loginError.hidden = true;
  el.loginSubmit.disabled = true;
  const { data, error } = await sb.auth.signInWithPassword({ email: el.email.value.trim(), password: el.password.value });
  el.loginSubmit.disabled = false;
  if (error) {
    el.loginError.textContent = 'Sign-in failed. Check the email and password.';
    el.loginError.hidden = false;
    return;
  }
  el.password.value = '';
  await enter(data.session);
});

el.signOut.addEventListener('click', async () => { await sb.auth.signOut(); showLogin(); });
el.refresh.addEventListener('click', () => refresh());

// ---- data -----------------------------------------------------------------------
async function refresh() {
  showError('');
  const [room, reports, messages, words, bans] = await Promise.all([
    sb.rpc('gc_room_state'),
    sb.from('reports')
      .select('id, created_at, reason, details, message_id, reported_user_id, reported_username, reported_content, reported_image_path, reported_at')
      .eq('status', 'open').order('created_at', { ascending: true }).limit(200),
    sb.from('messages')
      .select('id, username, content, created_at, kind, is_bot, hidden, command, sticker, country, image_path, poll_options')
      .order('created_at', { ascending: false }).limit(150),
    sb.from('blocked_words').select('word').order('word'),
    sb.from('banned_users').select('user_id, reason, banned_until, created_at').order('created_at', { ascending: false }).limit(200),
  ]);
  const firstError = [room, reports, messages, words, bans].find((r) => r.error)?.error;
  if (firstError) {
    console.error('[GlobalChat admin]', firstError);
    showError(`Some data couldn’t be loaded (${firstError.message}). Is schema.sql up to date?`);
  }
  renderRoom(room.data);
  renderReports(reports.data ?? []);
  renderMessages(messages.data ?? []);
  renderWords(words.data ?? []);
  renderBans(bans.data ?? []);
}

function summary(m) {
  if (m.kind === 'image') return `📷 ${m.content || 'Photo'}`;
  if (m.kind === 'voice') return '🎤 Voice note';
  if (m.kind === 'sticker') return `🏷️ Sticker: ${m.sticker}`;
  if (m.kind === 'poll') return `📊 ${m.content} (${(m.poll_options ?? []).join(' / ')})`;
  return m.content;
}

function renderRoom(rs) {
  if (!rs) return;
  el.slowMode.value = String(rs.slow_mode_seconds ?? 0);
  if (![...el.slowMode.options].some((o) => o.value === el.slowMode.value)) {
    el.slowMode.append(node('option', { text: `${rs.slow_mode_seconds} s`, attrs: { value: String(rs.slow_mode_seconds) } }));
    el.slowMode.value = String(rs.slow_mode_seconds);
  }
  el.pinCurrent.textContent = rs.pinned
    ? `${rs.pinned.is_bot ? 'GlobalChat Bot' : rs.pinned.username}: ${summary(rs.pinned)}` : 'None';
  el.unpin.hidden = !rs.pinned;
  const s = rs.stats ?? {};
  el.roomStats.replaceChildren(
    node('dt', { text: 'Messages today' }), node('dd', { text: String(s.today_messages ?? 0) }),
    node('dt', { text: 'People today' }), node('dd', { text: String(s.today_people ?? 0) }),
    node('dt', { text: 'Messages this week' }), node('dd', { text: String(s.week_messages ?? 0) }),
  );
}

el.slowSave.addEventListener('click', async () => {
  await run(sb.rpc('gc_mod_set_slow_mode', { p_seconds: Number(el.slowMode.value) }),
    Number(el.slowMode.value) ? 'Slow mode on.' : 'Slow mode off.');
  refresh();
});
el.unpin.addEventListener('click', async () => {
  await run(sb.rpc('gc_mod_pin', { p_message_id: null }), 'Unpinned.');
  refresh();
});

const BAN_CHOICES = [['Ban 1 h', 60], ['Ban 24 h', 1440], ['Ban forever', null]];

function renderReports(list) {
  // Group reports by message so 3 reports of one message are one card.
  const groups = new Map();
  for (const r of list) {
    const key = r.message_id ?? `report-${r.id}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }
  el.reportsCount.textContent = String(list.length);
  el.reportsEmpty.hidden = list.length > 0;
  el.reports.replaceChildren(...[...groups.values()].map((rs) => {
    const r = rs[0];
    const reasons = [...new Set(rs.map((x) => x.reason))].join(', ');
    const details = rs.map((x) => x.details).filter(Boolean);
    const li = node('li', { className: 'admin-item' },
      node('p', { className: 'admin-meta', text: `${rs.length} report${rs.length > 1 ? 's' : ''} · ${reasons} · first ${time(r.created_at)}` }),
      node('blockquote', { className: 'report-quote' },
        node('p', { className: 'report-quote-name', text: `${r.reported_username ?? 'unknown'} · sent ${time(r.reported_at)}` }),
        node('p', { className: 'report-quote-text', text: r.reported_content || (r.reported_image_path ? '(image, no caption)' : '(no text)') })),
      r.reported_image_path ? node('p', { className: 'side-note', text: `Image file: chat-images/${r.reported_image_path} (Dashboard → Storage)` }) : null,
      ...details.map((d) => node('p', { className: 'admin-detail', text: `“${d}”` })),
    );
    const actions = node('div', { className: 'admin-actions' });
    if (r.message_id) {
      actions.append(button('Delete message', async () => {
        if ((await run(sb.from('messages').delete().eq('id', r.message_id), 'Message deleted.')).ok) await resolve(rs, 'actioned');
      }, 'danger'));
    }
    if (r.reported_user_id) {
      for (const [label, minutes] of BAN_CHOICES) {
        actions.append(button(label, async () => {
          const until = minutes === null ? null : new Date(Date.now() + minutes * 60_000).toISOString();
          const res = await run(sb.from('banned_users').upsert({
            user_id: r.reported_user_id, reason: `Report: ${reasons}`, banned_until: until,
          }), `Banned ${r.reported_username ?? 'guest'}.`);
          if (res.ok) await resolve(rs, 'actioned');
        }));
      }
    }
    actions.append(button('Dismiss', () => resolve(rs, 'dismissed')));
    li.append(actions);
    return li;
  }));
}

async function resolve(reports, status) {
  const { data: { user } } = await sb.auth.getUser();
  await run(sb.from('reports')
    .update({ status, resolved_by: user?.id ?? null, resolved_at: new Date().toISOString() })
    .in('id', reports.map((r) => r.id)), status === 'dismissed' ? 'Report dismissed.' : 'Report closed.');
  refresh();
}

function renderMessages(list) {
  el.messagesCount.textContent = String(list.length);
  el.messages.replaceChildren(...list.map((m) => {
    const flags = [m.is_bot ? 'bot' : '', m.hidden ? 'HIDDEN after reports' : '', m.command ? `/${m.command}` : '', m.country ?? '']
      .filter(Boolean).join(' · ');
    const li = node('li', { className: `admin-item${m.hidden ? ' is-hidden' : ''}` },
      node('p', { className: 'admin-meta', text: `${m.is_bot ? 'GlobalChat Bot' : m.username} · ${time(m.created_at)}${flags ? ` · ${flags}` : ''}` }),
      node('p', { className: 'admin-text', text: summary(m) }));
    const actions = node('div', { className: 'admin-actions' },
      button('Pin', async () => { await run(sb.rpc('gc_mod_pin', { p_message_id: m.id }), 'Pinned.'); refresh(); }),
      button(m.hidden ? 'Unhide' : 'Hide', async () => {
        await run(sb.rpc('gc_mod_set_hidden', { p_message_id: m.id, p_hidden: !m.hidden }), m.hidden ? 'Visible again.' : 'Hidden.');
        refresh();
      }),
      button('Delete', async () => { await run(sb.from('messages').delete().eq('id', m.id), 'Deleted.'); refresh(); }, 'danger'));
    if (!m.is_bot) {
      for (const [label, minutes] of BAN_CHOICES) {
        actions.append(button(label, async () => {
          await run(sb.rpc('gc_mod_ban_author', { p_message_id: m.id, p_minutes: minutes, p_reason: 'From admin page' }), `Banned ${m.username}.`);
          refresh();
        }));
      }
    }
    li.append(actions);
    return li;
  }));
}

function renderWords(list) {
  el.words.replaceChildren(...list.map(({ word }) => node('li', {},
    node('span', { text: word }),
    button('×', async () => { await run(sb.from('blocked_words').delete().eq('word', word), `Removed “${word}”.`); refresh(); }))));
}

el.wordForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const word = el.wordInput.value.trim().toLowerCase();
  if (!/^[a-z]{2,30}$/.test(word)) { toast('Use 2–30 letters a–z.', 'danger'); return; }
  if ((await run(sb.from('blocked_words').insert({ word }), `Blocking “${word}”.`)).ok) el.wordInput.value = '';
  refresh();
});

function renderBans(list) {
  el.bansEmpty.hidden = list.length > 0;
  el.bans.replaceChildren(...list.map((b) => node('li', { className: 'admin-item' },
    node('p', { className: 'admin-meta', text: `${b.banned_until ? `until ${time(b.banned_until)}` : 'permanent'} · since ${time(b.created_at)}` }),
    node('p', { className: 'admin-text', text: b.reason || '(no reason)' }),
    node('div', { className: 'admin-actions' },
      button('Lift ban', async () => { await run(sb.from('banned_users').delete().eq('user_id', b.user_id), 'Ban lifted.'); refresh(); })))));
}

start().catch((err) => {
  console.error('[GlobalChat admin]', err);
  showError('The moderation page couldn’t start. Check config.js and your connection.');
});
