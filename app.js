// =============================================================================
// GlobalChat — app.js
//
// Flow:
//   boot()
//     → createClient (session stored in sessionStorage = one identity per tab)
//     → ensureSession()   anonymous sign-in (optionally behind Turnstile)
//     → joinRoom()        subscribe to private Realtime channel "room:global",
//                         then load the latest 100 unexpired messages
//   live events arrive as database broadcasts (see schema.sql §4)
//
// Safety rule for this file: user-generated text is ONLY ever written with
// textContent / text nodes. There is no innerHTML anywhere in this file.
// =============================================================================

// Pinned version: loaded as an ES module from jsDelivr.
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/+esm';
import { CONFIG } from './config.js';

// ---- Constants (keep in sync with schema.sql gc_setting) --------------------
const ROOM_TOPIC = 'room:global';
const MAX_LEN = 500;
const HISTORY_LIMIT = 100;
const MAX_RENDERED = 400;           // DOM cap so long sessions stay fast
const BURST_LIMIT = 5;
const BURST_WINDOW_MS = 10_000;
const EXPIRY_SWEEP_MS = 15_000;
const GROUP_WINDOW_MS = 3 * 60_000; // consecutive messages from one person merge
const NEAR_BOTTOM_PX = 140;
const AUTH_STORAGE_KEY = 'globalchat.auth';
const NOTICE_KEY = 'globalchat.noticeDismissed';
const TAB_ID = crypto.randomUUID();
const TYPING_IDLE_MS = 4000;        // typing hint clears after this much quiet
const FADE_BEFORE_MS = 5 * 60_000;  // messages fade in their last five minutes
const PEOPLE_SHOWN = 60;            // longer online lists collapse to "+N more"
const BASE_TITLE = document.title;

const EMOJI = ['😀', '😂', '🥹', '😊', '😍', '🤩', '😎', '🤔', '😅', '😭', '😮', '😴', '🙃', '😬', '🥳', '🤯',
  '👍', '👎', '👏', '🙌', '🙏', '👋', '🤝', '💪', '❤️', '🔥', '✨', '🎉', '💯', '✅', '👀', '🌍',
  '☕', '🍕', '🎵', '🎮', '🌙', '☀️', '🌈', '🚀'];
// Room bot: welcome replies when you post into an empty room. Shown only in
// your own tab, never stored or sent to anyone, and always labelled.
const BOT_NAME = 'GlobalChat Bot';
const BOT_MAX_PER_TAB = 3;
const BOT_DELAY_MS = 1100;
const JOIN_NOTE_AFTER_MS = 5000;    // ignore presence flicker right after joining

const STARTERS = ['Hello from somewhere 👋', 'What time is it where you are?', 'What are you listening to right now?'];

// Links, @mentions and formatting inside message text. Groups:
//   1 link  2 @mention  3 `code`  4 ||spoiler||  5 *bold*  6 _italic_
// Usernames follow the server rule. Bold/italic need non-word characters
// around them, so snake_case and 2*3*4 stay as typed.
const RICH_TOKEN = /(https?:\/\/[^\s<>"']+)|@([A-Za-z]{2,20}_[0-9]{4})\b|`([^`\n]+)`|\|\|([^|\n]+?)\|\||(?<![\w*])\*([^*\n]+?)\*(?![\w*])|(?<![\w_])_([^_\n]+?)_(?![\w_])/g;

// Columns by database version, newest first. The page detects which one the
// database has and switches off what it can't support (see setTier()).
const TIER_COLUMNS = {
  3: 'id, username, content, created_at, expires_at, kind, reply_to, image_path, poll_options, is_bot, command, sticker, country, edited_at',
  2: 'id, username, content, created_at, expires_at, kind, reply_to, image_path, poll_options',
  1: 'id, username, content, created_at, expires_at',
};

const STICKERS = [
  ['hi', 'Hi!'], ['gg', 'GG'], ['lol', 'LOL'], ['love', 'Love'],
  ['gn', 'Good night'], ['brb', 'Be right back'], ['wow', 'Wow'], ['thanks', 'Thanks'],
];  // keep in sync with gc_sticker_ids() in schema.sql and /stickers/*.svg
const VOICE_MAX_MS = 30_000;
const VOICE_TYPES = [
  ['audio/webm;codecs=opus', 'audio/webm', 'webm'],
  ['audio/ogg;codecs=opus', 'audio/ogg', 'ogg'],
  ['audio/mp4', 'audio/mp4', 'm4a'],
];
const EDIT_WINDOW_MS = 120_000;     // keep in sync with edit_window_seconds
const ROOM_STATE_REFRESH_MS = 5 * 60_000;
const DRAFT_KEY = 'globalchat.draft';
const CONFETTI_WORDS = /\b(happy\s+birthday|hbd|congrats|congratulations|congratz)\b|🎉|🥳|🎂/i;
const SHARE_TEXT = 'Come chat with the world on GlobalChat: no sign-up, messages vanish after an hour.';

// ISO 3166 country codes for the optional flag (names come from the browser).
const COUNTRY_CODES = ('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS '
  + 'BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI '
  + 'FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR '
  + 'IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM '
  + 'MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT '
  + 'PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM '
  + 'TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW').split(' ');

// Word of the day: one per day, same for everyone (by UTC date).
const WORDS = [
  ['Saudade', 'Portuguese', 'A deep, bittersweet longing for someone or something you love that is far away.'],
  ['Hygge', 'Danish', 'A cosy feeling of warmth, comfort and contentment, often with good company.'],
  ['Ubuntu', 'Zulu / Xhosa', '“I am because we are”: the idea that we are human through our kindness to others.'],
  ['Wabi-sabi', 'Japanese', 'Finding beauty in things that are imperfect, simple and impermanent.'],
  ['Fernweh', 'German', 'An ache to be somewhere far away; the opposite of homesickness.'],
  ['Sobremesa', 'Spanish', 'The time spent chatting at the table after a meal is finished.'],
  ['Jugaad', 'Hindi', 'A clever, improvised fix that gets the job done with whatever is at hand.'],
  ['Komorebi', 'Japanese', 'Sunlight filtering through the leaves of trees.'],
  ['Lagom', 'Swedish', 'Just the right amount: not too much, not too little.'],
  ['Hiraeth', 'Welsh', 'Homesickness for a home you can’t return to, or that maybe never was.'],
  ['Gezellig', 'Dutch', 'Cosy, friendly and pleasant, especially when spending time with others.'],
  ['Tsundoku', 'Japanese', 'Buying books and letting them pile up without reading them.'],
  ['Meraki', 'Greek', 'Putting your soul, creativity and love into what you do.'],
  ['Sisu', 'Finnish', 'Extraordinary determination and courage when things get hard.'],
  ['Ikigai', 'Japanese', 'Your reason for being: the thing that makes getting up worthwhile.'],
  ['Hakuna matata', 'Swahili', 'No worries.'],
  ['Dolce far niente', 'Italian', 'The sweetness of doing nothing.'],
  ['Joie de vivre', 'French', 'A cheerful enjoyment of life.'],
  ['Wanderlust', 'German', 'A strong desire to travel and explore the world.'],
  ['Petrichor', 'English', 'The earthy smell in the air after rain falls on dry ground.'],
  ['Serendipity', 'English', 'Finding something good by happy accident.'],
  ['Kilig', 'Tagalog', 'The butterflies-in-your-stomach rush of romantic excitement.'],
  ['Gigil', 'Tagalog', 'The urge to squeeze something that is unbearably cute.'],
  ['Jayus', 'Indonesian', 'A joke told so badly that you can’t help laughing.'],
  ['Pochemuchka', 'Russian', 'A person who asks a lot of questions.'],
  ['Cafuné', 'Brazilian Portuguese', 'Tenderly running your fingers through someone’s hair.'],
  ['Friluftsliv', 'Norwegian', '“Open-air life”: spending time outdoors for your wellbeing.'],
  ['Shemomedjamo', 'Georgian', 'Eating past being full because the food is just that good.'],
  ['Waldeinsamkeit', 'German', 'The peaceful feeling of being alone in the woods.'],
  ['Mångata', 'Swedish', 'The road-like reflection of the moon on water.'],
  ['Sankofa', 'Akan (Twi)', '“Go back and get it”: learning from the past to build the future.'],
  ['Dépaysement', 'French', 'The feeling of being somewhere new and unfamiliar.'],
  ['Nunchi', 'Korean', 'The quiet art of sensing how others feel.'],
  ['Jeong', 'Korean', 'A deep bond of affection that grows over time.'],
  ['Ailyak', 'Bulgarian', 'Doing things slowly and calmly, enjoying the moment.'],
  ['Hanami', 'Japanese', 'Gathering to enjoy the cherry blossoms.'],
  ['Kaapi', 'Tamil', 'South Indian filter coffee, frothy and strong.'],
  ['Pura vida', 'Spanish (Costa Rica)', '“Pure life”: a way of saying hello, goodbye, and that life is good.'],
  ['Sawubona', 'Zulu', 'A greeting meaning “I see you”: I value you and your presence.'],
  ['Ohana', 'Hawaiian', 'Family, including the friends you choose as family.'],
];

const REACTIONS = ['❤️', '👍', '😂', '😮', '😢', '🔥'];   // keep in sync with schema.sql
const IMAGE_BUCKET = 'chat-images';
const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/webp', 'image/gif'];
const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;
const MAX_IMAGE_DIM = 1600;         // photos are scaled down to this before upload

// ---- DOM references -------------------------------------------------------
const $ = (id) => document.getElementById(id);
const el = {
  app: $('app'),
  feed: $('feed'),
  list: $('message-list'),
  feedState: $('feed-state'),
  jump: $('jump'),
  jumpText: $('jump-text'),
  statusText: $('status-text'),
  onlineCount: $('online-count'),
  sideOnline: $('side-online'),
  sideUsername: $('side-username'),
  sideAvatar: $('side-avatar'),
  banner: $('conn-banner'),
  brandMark: $('brand-mark'),
  composer: $('composer'),
  input: $('composer-input'),
  send: $('send-button'),
  counter: $('counter'),
  composerUsername: $('composer-username'),
  composerError: $('composer-error'),
  notice: $('privacy-notice'),
  dismissNotice: $('dismiss-notice'),
  reportDialog: $('report-dialog'),
  reportForm: $('report-form'),
  reportQuoteName: $('report-quote-name'),
  reportQuoteText: $('report-quote-text'),
  reportDetails: $('report-details'),
  reportCounter: $('report-counter'),
  reportError: $('report-error'),
  reportSubmit: $('report-submit'),
  reportCancel: $('report-cancel'),
  aboutDialog: $('about-dialog'),
  settingsDialog: $('settings-dialog'),
  settingsForm: $('settings-form'),
  notifyNote: $('notify-note'),
  peopleDialog: $('people-dialog'),
  peopleDialogSub: $('people-dialog-sub'),
  sideOnlineCount: $('side-online-count'),
  sidePeople: $('side-people'),
  dialogPeople: $('dialog-people'),
  typing: $('typing'),
  emojiToggle: $('emoji-toggle'),
  emojiPanel: $('emoji-panel'),
  searchToggle: $('search-toggle'),
  searchBar: $('search-bar'),
  searchInput: $('search-input'),
  searchCount: $('search-count'),
  searchClose: $('search-close'),
  feedWrap: $('feed-wrap'),
  dropHint: $('drop-hint'),
  replyBar: $('reply-bar'),
  replyName: $('reply-name'),
  replyText: $('reply-text'),
  replyCancel: $('reply-cancel'),
  imageBar: $('image-bar'),
  imageThumb: $('image-thumb'),
  imageName: $('image-name'),
  imageMeta: $('image-meta'),
  imageCancel: $('image-cancel'),
  imageInput: $('image-input'),
  attachToggle: $('attach-toggle'),
  attachMenu: $('attach-menu'),
  attachImage: $('attach-image'),
  attachPoll: $('attach-poll'),
  reactionPicker: $('reaction-picker'),
  pollDialog: $('poll-dialog'),
  pollForm: $('poll-form'),
  pollQuestion: $('poll-question'),
  pollOptions: $('poll-options'),
  pollAdd: $('poll-add'),
  pollError: $('poll-error'),
  pollSubmit: $('poll-submit'),
  deleteDialog: $('delete-dialog'),
  deleteConfirm: $('delete-confirm'),
  lightbox: $('lightbox'),
  lightboxImg: $('lightbox-img'),
  lightboxCaption: $('lightbox-caption'),
  sideFlag: $('side-flag'),
  shareButton: $('share-button'),
  pinBar: $('pin-bar'),
  pinName: $('pin-name'),
  pinContent: $('pin-content'),
  slowBar: $('slow-bar'),
  slowSeconds: $('slow-seconds'),
  editBar: $('edit-bar'),
  editText: $('edit-text'),
  editCancel: $('edit-cancel'),
  voiceBar: $('voice-bar'),
  voiceLabel: $('voice-label'),
  voiceTime: $('voice-time'),
  voicePreview: $('voice-preview'),
  voiceStop: $('voice-stop'),
  voiceSend: $('voice-send'),
  voiceCancel: $('voice-cancel'),
  commandHint: $('command-hint'),
  attachSticker: $('attach-sticker'),
  attachVoice: $('attach-voice'),
  stickerPanel: $('sticker-panel'),
  moreMenu: $('more-menu'),
  renameDialog: $('rename-dialog'),
  renameForm: $('rename-form'),
  renameInput: $('rename-input'),
  renameDigits: $('rename-digits'),
  renameError: $('rename-error'),
  renameSubmit: $('rename-submit'),
  countrySelect: $('country-select'),
  mutedList: $('muted-list'),
  mutedEmpty: $('muted-empty'),
  confetti: $('confetti'),
  toasts: $('toasts'),
  captcha: $('captcha'),
  template: $('message-template'),
};

// ---- State ----------------------------------------------------------------
const state = {
  sb: null,
  session: null,
  username: null,
  channel: null,
  connection: 'connecting',     // connecting | live | reconnecting | offline | error
  everSubscribed: false,
  reconnectAttempts: 0,
  reconnectTimer: null,
  authResetting: false,
  historyLoaded: false,
  pendingLive: [],               // live events that arrive before history loads
  liveQueue: [],                 // batched per animation frame
  liveFrame: 0,
  messages: new Map(),           // id -> { data, node }
  sending: false,
  sendTimes: [],
  cooldownUntil: 0,
  cooldownTimer: null,
  unseen: 0,
  reportTarget: null,
  reportSending: false,
  presenceKey: null,
  people: [],                    // [{ key, name, typing }] from presence
  typing: false,
  typingTimer: null,
  filter: '',
  titleUnread: 0,
  titleMention: false,
  prefs: window.GlobalChatPrefs?.load()
    ?? { theme: 'dark', accent: 'violet', density: 'comfortable', sound: false, notify: false, soundAll: false, country: '', muted: [] },
  audio: null,
  legacy: false,                 // database not yet upgraded: hide new features
  tier: 3,                       // database version detected (3 = everything)
  myNames: new Map(),            // names this tab used -> ms they stopped being ours (null = current)
  roomState: null,               // pin, slow mode, question of the day, stats
  editing: null,                 // id of the message being edited
  recorder: null,                // { rec, stream, chunks, timer, startedAt, blob, url, type, ext, path }
  confettiAt: 0,
  audioTick: 0,
  replyTo: null,                 // id of the message being replied to
  pendingImage: null,            // { blob, type, ext, url, path? } waiting to send
  signedUrls: new Map(),         // image path -> { url, until }
  gone: new Set(),               // ids deleted or expired while on screen
  pickerFor: null,               // message id the reaction picker is open for
  deleteTarget: null,
  pollSending: false,
  atBottom: true,
  aloneSince: null,              // when this tab became the only one online
  botRepliedWhileAlone: false,
  botReplies: 0,
  timeFormat: new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }),
  fullFormat: new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }),
};

// =============================================================================
// Text helpers — mirror the server's normalisation so the counter matches.
// =============================================================================
const CONTROL_CHARS = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069\uFEFF]/g;

function normalizeText(raw) {
  return String(raw ?? '')
    .replace(/\r\n/g, '\n')
    .replace(CONTROL_CHARS, '')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/[ \t]+\n/g, '\n')
    .trim();
}

// Postgres char_length counts code points, so do the same (emoji = 1).
const charCount = (s) => [...s].length;

// =============================================================================
// Guest identity
// =============================================================================
const ADJECTIVES = ['Quiet', 'Cosmic', 'Neon', 'Velvet', 'Lunar', 'Silver', 'Hidden', 'Swift', 'Gentle',
  'Electric', 'Midnight', 'Amber', 'Wandering', 'Solar', 'Misty', 'Brave', 'Polar', 'Copper', 'Wild', 'Sleepy'];
const NOUNS = ['Fox', 'Owl', 'Comet', 'Otter', 'Raven', 'Moth', 'Lynx', 'Heron', 'Nova', 'Panda', 'Wolf',
  'Koi', 'Finch', 'Badger', 'Orbit', 'Pixel', 'Echo', 'Fern', 'Tiger', 'Whale'];
const SOLO = ['Ghost', 'Cosmic', 'Nomad', 'Drifter', 'Stranger', 'Signal', 'Static', 'Voyager'];

function randomInt(max) {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return buf[0] % max;
}

// Matches server rule: ^[A-Za-z]{2,20}_[0-9]{4}$
function generateUsername() {
  const word = randomInt(4) === 0
    ? SOLO[randomInt(SOLO.length)]
    : ADJECTIVES[randomInt(ADJECTIVES.length)] + NOUNS[randomInt(NOUNS.length)];
  return `${word.slice(0, 20)}_${1000 + randomInt(9000)}`;
}

const usernameKey = (userId) => `globalchat.username.${userId}`;

function loadOrCreateUsername(userId) {
  const key = usernameKey(userId);
  const stored = sessionStorage.getItem(key);
  if (stored && /^[A-Za-z]{2,20}_[0-9]{4}$/.test(stored)) return stored;
  const fresh = generateUsername();
  sessionStorage.setItem(key, fresh);
  return fresh;
}

// Messages are "mine" if they use a name this tab has used, from before it
// stopped being ours (a released name could later be claimed by someone else).
function isMine(m) {
  if (!m || m.is_bot) return false;
  if (!state.myNames.has(m.username)) return false;
  const until = state.myNames.get(m.username);
  return until === null || createdMs(m) <= until;
}

function setUsername(name) {
  if (state.username && state.username !== name) state.myNames.set(state.username, Date.now() + 5000);
  state.myNames.set(name, null);
  state.username = name;
  if (state.session) sessionStorage.setItem(usernameKey(state.session.user.id), name);
  el.sideUsername.textContent = name;
  el.composerUsername.textContent = name;
  paintAvatar(el.sideAvatar, name);
  // Re-mark own messages (e.g. after the server confirmed a different name).
  for (const { data, node } of state.messages.values()) {
    applyMine(node, isMine(data), data);
    node.classList.toggle('is-mention', isForMe(data));
  }
  trackPresence();
}

function hueFor(name) {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.codePointAt(0)) >>> 0;
  return h % 360;
}

function paintAvatar(node, name) {
  node.textContent = (name.match(/[A-Za-z]/)?.[0] ?? '?').toUpperCase();
  node.style.setProperty('--hue', String(hueFor(name)));
}

// =============================================================================
// Boot
// =============================================================================
function isConfigured() {
  return typeof CONFIG?.SUPABASE_URL === 'string'
    && /^https:\/\/.+/.test(CONFIG.SUPABASE_URL)
    && !CONFIG.SUPABASE_URL.includes('YOUR-PROJECT-REF')
    && typeof CONFIG.SUPABASE_ANON_KEY === 'string'
    && CONFIG.SUPABASE_ANON_KEY.length > 20
    && !CONFIG.SUPABASE_ANON_KEY.startsWith('YOUR-');
}

async function boot() {
  wireUI();
  // Installable app + offline shell (sw.js). Never caches chat data.
  if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
    navigator.serviceWorker.register('sw.js').catch((err) => console.info('[GlobalChat] no service worker', err));
  }

  if (!isConfigured()) {
    setConnection('error', 'Not configured');
    showFeedState('setup');
    return;
  }

  showFeedState('loading');
  await dropSessionIfDuplicatedTab();

  state.sb = createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY, {
    auth: {
      storage: window.sessionStorage,   // identity is scoped to this tab
      storageKey: AUTH_STORAGE_KEY,
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  });

  state.sb.auth.onAuthStateChange(onAuthChange);

  try {
    await ensureSession();
    await joinRoom();
  } catch (err) {
    console.error('[GlobalChat] startup failed', err);
    setConnection('error', 'Can’t connect');
    showFeedState('error', describeStartupError(err));
  }

  startExpirySweep();
}

// Browsers copy sessionStorage when a tab is duplicated. Two tabs sharing one
// session would fight over refresh tokens, so the copy starts fresh instead.
async function dropSessionIfDuplicatedTab() {
  if (!('BroadcastChannel' in window)) return;
  const bc = new BroadcastChannel('globalchat-tabs');
  state.tabChannel = bc;
  let userId = null;
  try { userId = JSON.parse(sessionStorage.getItem(AUTH_STORAGE_KEY) || 'null')?.user?.id ?? null; } catch { /* ignore */ }

  bc.onmessage = (e) => {
    const msg = e.data;
    if (msg?.type === 'whois' && msg.tabId !== TAB_ID && msg.userId && msg.userId === state.session?.user?.id) {
      bc.postMessage({ type: 'taken', tabId: msg.tabId });
    }
  };

  if (!userId) return;
  const duplicate = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 200);
    bc.addEventListener('message', (e) => {
      if (e.data?.type === 'taken' && e.data.tabId === TAB_ID) { clearTimeout(timer); resolve(true); }
    });
    bc.postMessage({ type: 'whois', tabId: TAB_ID, userId });
  });
  if (duplicate) {
    sessionStorage.removeItem(AUTH_STORAGE_KEY);
    sessionStorage.removeItem(usernameKey(userId));
  }
}

// =============================================================================
// Authentication
// =============================================================================
async function ensureSession() {
  setConnection('connecting');
  const sb = state.sb;

  let { data: { session } } = await sb.auth.getSession();

  // A stored session may belong to a user that was deleted/expired server-side.
  if (session) {
    const { error } = await sb.auth.getUser();
    const rejected = error && error.status >= 400 && error.status < 500;
    if (rejected) {
      state.authResetting = true;
      await sb.auth.signOut({ scope: 'local' }).catch(() => {});
      sessionStorage.removeItem(AUTH_STORAGE_KEY);
      state.authResetting = false;
      session = null;
    }
  }

  if (!session) {
    const captchaToken = CONFIG.TURNSTILE_SITE_KEY ? await getTurnstileToken() : undefined;
    const { data, error } = await sb.auth.signInAnonymously(
      captchaToken ? { options: { captchaToken } } : undefined,
    );
    if (error) throw error;
    session = data.session;
  }

  state.session = session;
  sb.realtime.setAuth(session.access_token);
  setUsername(loadOrCreateUsername(session.user.id));
  enableComposer(true);
}

function onAuthChange(event, session) {
  // Keep Realtime authorised with the newest token (private channel needs it).
  if (session?.access_token) {
    state.session = session;
    state.sb?.realtime.setAuth(session.access_token);
  }
  if (event === 'SIGNED_OUT' && !state.authResetting) {
    // Session revoked or refresh failed: start a fresh guest session.
    // Deferred so we don't call Supabase from inside its own callback.
    setTimeout(recoverSession, 0);
  }
}

async function recoverSession() {
  if (state.authResetting) return;
  state.authResetting = true;
  enableComposer(false);
  try {
    teardownChannel();
    state.session = null;
    await ensureSession();
    await joinRoom();
    toast(`Your guest session ended, so you've rejoined as ${state.username}.`);
  } catch (err) {
    console.error('[GlobalChat] session recovery failed', err);
    setConnection('error', 'Can’t connect');
    showFeedState('error', describeStartupError(err));
  } finally {
    state.authResetting = false;
  }
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.async = true;
    s.onload = resolve;
    s.onerror = () => reject(new Error('CAPTCHA_LOAD_FAILED'));
    document.head.append(s);
  });
}

async function getTurnstileToken() {
  if (!window.turnstile) {
    await loadScript('https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit');
  }
  el.captcha.hidden = false;
  return new Promise((resolve, reject) => {
    window.turnstile.render('#captcha-widget', {
      sitekey: CONFIG.TURNSTILE_SITE_KEY,
      theme: 'dark',
      callback: (token) => { el.captcha.hidden = true; resolve(token); },
      'error-callback': () => { el.captcha.hidden = true; reject(new Error('CAPTCHA_FAILED')); },
    });
  });
}

// =============================================================================
// Room: realtime channel + history
// =============================================================================
async function joinRoom() {
  state.historyLoaded = false;
  state.pendingLive = [];
  subscribeChannel();   // subscribe first so nothing sent during the load is missed
  await loadHistory();
}

function teardownChannel() {
  clearTimeout(state.reconnectTimer);
  const old = state.channel;
  state.channel = null;          // callbacks from `old` are now ignored
  if (old) state.sb.removeChannel(old).catch(() => {});
}

function subscribeChannel() {
  teardownChannel();
  const sb = state.sb;
  if (state.session) sb.realtime.setAuth(state.session.access_token);

  state.presenceKey = crypto.randomUUID();  // random per connection, no user id
  const channel = sb.channel(ROOM_TOPIC, {
    config: {
      private: true,                          // RLS on realtime.messages applies
      presence: { key: state.presenceKey },
    },
  });
  state.channel = channel;

  channel
    .on('broadcast', { event: 'message_created' }, (msg) => {
      const data = msg?.payload?.record ?? msg?.payload;
      if (!state.historyLoaded) state.pendingLive.push(data);
      else queueLive(data);
    })
    .on('broadcast', { event: 'message_deleted' }, (msg) => {
      const id = msg?.payload?.id;
      if (typeof id === 'string') removeMessage(id);
    })
    .on('broadcast', { event: 'message_reactions' }, (msg) => {
      const p = msg?.payload;
      if (typeof p?.id === 'string' && p.reactions && typeof p.reactions === 'object') applyReactions(p.id, p.reactions);
    })
    .on('broadcast', { event: 'poll_votes' }, (msg) => {
      const p = msg?.payload;
      if (typeof p?.id === 'string' && Array.isArray(p.counts)) applyPoll(p.id, p.counts);
    })
    .on('broadcast', { event: 'message_edited' }, (msg) => {
      const p = msg?.payload;
      if (typeof p?.id === 'string' && typeof p.content === 'string') applyEdit(p.id, p.content, p.edited_at);
    })
    .on('broadcast', { event: 'room_state' }, (msg) => applyRoomState(msg?.payload))
    .on('presence', { event: 'sync' }, () => {
      if (channel !== state.channel) return;
      syncPeople(channel.presenceState());
    })
    .subscribe(async (status, err) => {
      if (channel !== state.channel) return; // stale channel
      if (status === 'SUBSCRIBED') {
        const isReconnect = state.everSubscribed;
        state.everSubscribed = true;
        state.reconnectAttempts = 0;
        setConnection('live');
        await trackPresence();
        if (isReconnect) loadHistory({ backfill: true }); // fill any gap
      } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
        if (err) console.warn('[GlobalChat] realtime', status, err?.message ?? err);
        scheduleReconnect();
      }
    });
}

function scheduleReconnect() {
  clearTimeout(state.reconnectTimer);
  if (!navigator.onLine) { setConnection('offline'); return; } // 'online' event resumes
  setConnection('reconnecting');
  const attempt = state.reconnectAttempts++;
  const delay = Math.min(30_000, 1000 * 2 ** attempt) + randomInt(800);
  state.reconnectTimer = setTimeout(reconnectNow, delay);
}

async function reconnectNow() {
  clearTimeout(state.reconnectTimer);
  if (!state.sb || !state.session) return;
  try {
    // getSession refreshes an expired access token if needed.
    const { data: { session } } = await state.sb.auth.getSession();
    if (!session) { recoverSession(); return; }
    state.session = session;
  } catch { /* fall through and try the socket anyway */ }
  subscribeChannel();
}

async function loadHistory({ backfill = false } = {}) {
  if (!backfill) showFeedState('loading');
  const { data, error } = await state.sb
    .from('messages')
    .select(columns())
    .order('created_at', { ascending: false })
    .limit(HISTORY_LIMIT);

  if (error && state.tier > 1 && isMissingColumn(error)) {
    setTier(state.tier - 1);
    return loadHistory({ backfill });
  }
  if (error) {
    console.error('[GlobalChat] history', error);
    if (backfill) return;          // keep what we already show
    if (isAuthError(error)) { recoverSession(); return; }
    showFeedState('error', 'Messages couldn’t be loaded. Check your connection and try again.');
    return;
  }

  const initial = !state.historyLoaded;
  state.historyLoaded = true;
  const batch = [...data.reverse(), ...state.pendingLive];
  state.pendingLive = [];
  upsertMessages(batch, { initial });
  updateFeedState();
  loadExtras([...state.messages.keys()]);
  if (!backfill) loadRoomState();
}

const columns = () => TIER_COLUMNS[state.tier];

function isMissingColumn(error) {
  return error?.code === '42703' || /column .* does not exist/i.test(error?.message ?? '');
}

// The page is newer than the database: keep what works and hide the rest
// until schema.sql is re-run. Tier 1 = original chat only, 2 = replies,
// photos, polls, reactions, delete; 3 = everything.
function setTier(tier) {
  state.tier = tier;
  state.legacy = tier === 1;
  document.documentElement.dataset.features = tier === 1 ? 'legacy' : tier === 2 ? 'v2' : '';
  document.getElementById('setup-notice').hidden = tier === 3;
  document.getElementById('setup-notice-title').textContent = tier === 1
    ? 'Photos, polls, replies and reactions are switched off'
    : 'Stickers, voice notes, editing, flags, trivia and room stats are switched off';
  console.warn(`[GlobalChat] Database features: tier ${tier} of 3. Re-run schema.sql to enable everything.`);
  renderIdentityFlag();
  renderCountries();
}

function queueLive(data) {
  state.liveQueue.push(data);
  if (!state.liveFrame) {
    state.liveFrame = requestAnimationFrame(() => {
      state.liveFrame = 0;
      const batch = state.liveQueue;
      state.liveQueue = [];
      upsertMessages(batch, { initial: false });
    });
  }
}

// =============================================================================
// Rendering messages
// =============================================================================
function isValidMessage(m) {
  const base = m && typeof m.id === 'string'
    && typeof m.username === 'string'
    && typeof m.content === 'string'
    && !Number.isNaN(Date.parse(m.created_at))
    && !Number.isNaN(Date.parse(m.expires_at));
  if (!base) return false;
  m.kind ??= 'text';
  if (typeof m.reply_to !== 'string') m.reply_to = null;
  m.is_bot = m.is_bot === true;
  if (typeof m.country !== 'string' || !/^[A-Z]{2}$/.test(m.country)) m.country = null;
  if (!['roll', 'flip', '8ball'].includes(m.command)) m.command = null;
  if (m.kind === 'image' || m.kind === 'voice') return typeof m.image_path === 'string';
  if (m.kind === 'sticker') return STICKERS.some(([id]) => id === m.sticker);
  if (m.kind === 'poll') {
    return Array.isArray(m.poll_options) && m.poll_options.length >= 2
      && m.poll_options.every((o) => typeof o === 'string');
  }
  return m.kind === 'text';
}

const isExpired = (m) => Date.parse(m.expires_at) <= Date.now();
const isFading = (m) => Date.parse(m.expires_at) - Date.now() < FADE_BEFORE_MS;
const createdMs = (m) => Date.parse(m.created_at);

function upsertMessages(list, { initial }) {
  const fresh = [];
  const seen = new Set();
  for (const m of list) {
    if (!isValidMessage(m) || isExpired(m) || state.messages.has(m.id) || seen.has(m.id)) continue;
    seen.add(m.id);
    fresh.push(m);
  }
  if (!fresh.length) return;
  fresh.sort((a, b) => createdMs(a) - createdMs(b));

  const stick = initial || isNearBottom();
  const includesMine = fresh.some(isMine);

  for (const m of fresh) insertMessage(m);
  if (stick || includesMine) trimOverflow();
  updateFeedState();

  const mentions = initial ? [] : fresh.filter(isForMe);
  if (initial || stick || includesMine) {
    scrollToBottom();
  } else {
    state.unseen += fresh.length;
    showJump(mentions.length > 0);
  }
  if (!initial) {
    pulseBrand();
    const others = fresh.filter((m) => !isMine(m) && !isMutedMsg(m));
    noteUnread(others.length, mentions);
    if (others.length && state.prefs.soundAll && !(mentions.length && state.prefs.sound)) playTick();
    maybeConfetti(fresh);
  }
  if (state.filter) applyFilter();
}

const displayName = (m) => (m.is_bot ? BOT_NAME : m.username);

function buildNode(m) {
  const node = el.template.content.firstElementChild.cloneNode(true);

  node.dataset.id = m.id;
  node.dataset.time = String(createdMs(m));
  const hue = String(hueFor(m.username));
  const avatar = node.querySelector('.avatar');
  const name = node.querySelector('.msg-name');
  name.textContent = displayName(m);
  if (m.is_bot) {
    avatar.textContent = '🤖';
    avatar.classList.add('avatar-bot');
    node.classList.add('is-server-bot');
    name.title = 'Automatic messages from GlobalChat';
    name.disabled = true;
  } else {
    paintAvatar(avatar, m.username);
    name.style.setProperty('--hue', hue);
    name.title = `Mention ${m.username}`;
    name.addEventListener('click', () => insertMention(m.username));
  }
  const flag = node.querySelector('.msg-flag');
  if (m.country) {
    flag.hidden = false;
    flag.textContent = flagEmoji(m.country);
    flag.title = countryName(m.country);
  }
  const badge = node.querySelector('.msg-badge');
  if (m.is_bot || m.command) {
    badge.hidden = false;
    badge.textContent = m.is_bot ? 'bot' : `/${m.command}`;
    badge.title = m.is_bot ? 'Automatic message' : 'Result picked by the server, so it can’t be faked';
  }
  node.classList.toggle('is-command', Boolean(m.command));
  renderRichText(node.querySelector('.msg-text'), m.content);  // safe: text nodes only
  renderTime(node, m);
  renderEdited(node, m);

  node.querySelector('.msg-reply').addEventListener('click', () => startReply(m.id));
  node.querySelector('.msg-react').addEventListener('click', (e) => openReactionPicker(m.id, e.currentTarget));
  node.querySelector('.msg-edit').addEventListener('click', () => startEdit(m.id));
  node.querySelector('.msg-more').addEventListener('click', (e) => openMoreMenu(m.id, e.currentTarget));
  node.querySelector('.msg-quote').addEventListener('click', () => scrollToMessage(m.reply_to));
  node.querySelector('.msg-unmute-once').addEventListener('click', () => node.classList.add('is-unmuted'));

  if (m.kind === 'image') renderImage(node, m);
  if (m.kind === 'sticker') renderSticker(node, m);
  if (m.kind === 'voice') renderVoice(node, m);
  if (m.kind === 'poll') {
    const pollBadge = document.createElement('span');
    pollBadge.className = 'poll-badge';
    pollBadge.textContent = '📊 Poll';
    node.querySelector('.msg-text').before(pollBadge);
    renderPoll(node, m);
  }
  renderQuote(node, m);
  renderReactions(node, m);

  applyMine(node, isMine(m), m);
  node.classList.toggle('is-muted', isMutedMsg(m));
  node.classList.toggle('is-mention', isForMe(m));
  node.classList.toggle('is-fading', isFading(m));
  return node;
}

function applyMine(node, mine, m) {
  node.classList.toggle('is-mine', mine);
  node.querySelector('.msg-you').hidden = !mine;
  node.querySelector('.msg-edit').hidden = !(mine && isEditable(m));
}

const isEditable = (m) => state.tier >= 3 && m.kind === 'text' && !m.command && !m.is_bot
  && Date.now() - createdMs(m) < EDIT_WINDOW_MS - 3000;

// "now" / "5m ago", plus a countdown in a message's last 10 minutes.
function renderTime(node, m) {
  const created = createdMs(m);
  const expires = Date.parse(m.expires_at);
  const time = node.querySelector('.msg-time');
  const ago = Math.max(0, Date.now() - created);
  time.dateTime = new Date(created).toISOString();
  time.textContent = ago < 45_000 ? 'now' : ago < 3_600_000 ? `${Math.round(ago / 60_000)}m ago` : state.timeFormat.format(created);
  time.title = `${state.fullFormat.format(created)}. Disappears at ${state.timeFormat.format(expires)}.`;
  const left = node.querySelector('.msg-left');
  const leftMs = expires - Date.now();
  left.hidden = leftMs > 10 * 60_000;
  if (!left.hidden) left.textContent = `⏳ ${Math.max(1, Math.ceil(leftMs / 60_000))}m left`;
}

function renderEdited(node, m) {
  const edited = node.querySelector('.msg-edited');
  edited.hidden = !m.edited_at;
  if (m.edited_at) edited.title = `Edited ${state.fullFormat.format(new Date(m.edited_at))}`;
}

function insertMessage(m) {
  const node = buildNode(m);
  // Most messages are newest: walk back from the end to find the slot.
  // (Uses each element's stored time, so local bot notes and messages that
  // are fading out after removal sort correctly too.)
  let after = el.list.lastElementChild;
  while (after && Number(after.dataset.time) > createdMs(m)) {
    after = after.previousElementSibling;
  }
  if (after) after.after(node); else el.list.prepend(node);
  state.messages.set(m.id, { data: m, node });
  regroup(node);
  regroup(node.nextElementSibling);
  refreshRepliesTo(m.id);   // replies that arrived before their original
}

function refreshRepliesTo(id) {
  for (const entry of state.messages.values()) {
    if (entry.data.reply_to === id) {
      renderQuote(entry.node, entry.data);
      entry.node.classList.toggle('is-mention', isForMe(entry.data));
    }
  }
}

// Hide name/avatar when the previous message is from the same person, recently.
function regroup(node) {
  if (!node) return;
  const prev = node.previousElementSibling;
  const cur = state.messages.get(node.dataset.id)?.data;
  const before = prev ? state.messages.get(prev.dataset.id)?.data : null;
  const continued = Boolean(cur && before
    && before.username === cur.username
    && createdMs(cur) - createdMs(before) < GROUP_WINDOW_MS);
  node.classList.toggle('is-continued', continued);
}

function removeMessage(id, { animate = true, gone = true } = {}) {
  const entry = state.messages.get(id);
  if (!entry) return;
  state.messages.delete(id);
  if (gone) state.gone.add(id);
  refreshRepliesTo(id);
  if (state.replyTo === id) {
    cancelReply();
    toast('The message you were replying to is gone.');
  }
  if (state.pickerFor === id) closeReactionPicker();
  if (state.deleteTarget === id && el.deleteDialog.open) el.deleteDialog.close();
  const { node } = entry;
  const finish = () => {
    const next = node.nextElementSibling;
    node.remove();
    regroup(next);
    updateFeedState();
  };
  if (animate && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    node.classList.add('is-expiring');
    setTimeout(finish, 420);
  } else {
    finish();
  }
  if (state.reportTarget === id && el.reportDialog.open) {
    el.reportDialog.close();
    toast('That message has expired or was removed.');
  }
}

function trimOverflow() {
  while (state.messages.size > MAX_RENDERED) {
    const first = el.list.firstElementChild;
    if (!first) break;
    if (!state.messages.has(first.dataset.id)) { first.remove(); continue; }  // bot note / fading node
    removeMessage(first.dataset.id, { animate: false, gone: false });
  }
}

function startExpirySweep() {
  const sweep = () => {
    for (const [id, { data, node }] of state.messages) {
      if (isExpired(data)) { removeMessage(id); continue; }
      node.classList.toggle('is-fading', isFading(data));
      renderTime(node, data);
      applyMine(node, isMine(data), data);
    }
  };
  setInterval(sweep, EXPIRY_SWEEP_MS);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    clearUnread();
    sweep();
    if (state.sb && state.session && state.connection !== 'live') reconnectNow();
  });
}

// =============================================================================
// Scroll + "new messages" pill
// =============================================================================
function isNearBottom() {
  const f = el.feed;
  return f.scrollHeight - f.scrollTop - f.clientHeight < NEAR_BOTTOM_PX;
}

function scrollToBottom() {
  el.feed.scrollTop = el.feed.scrollHeight;
  state.unseen = 0;
  el.jump.hidden = true;
}

function showJump(mention = false) {
  el.jumpText.textContent = state.unseen === 1 ? '1 new message' : `${state.unseen} new messages`;
  if (el.jump.hidden) el.jump.classList.remove('has-mention');
  if (mention) el.jump.classList.add('has-mention');
  el.jump.hidden = false;
}

function pulseBrand() {
  const mark = el.brandMark;
  if (!mark || mark.classList.contains('is-pulsing')) return;
  mark.classList.add('is-pulsing');
  setTimeout(() => mark.classList.remove('is-pulsing'), 720);
}

// =============================================================================
// Status, presence, feed states
// =============================================================================
const STATUS_LABELS = {
  connecting: 'Connecting',
  live: 'Live',
  reconnecting: 'Reconnecting',
  offline: 'Offline',
  error: 'Disconnected',
};

function setConnection(conn, label) {
  state.connection = conn;
  el.app.dataset.connection = conn;
  el.statusText.textContent = label ?? STATUS_LABELS[conn];

  if (conn === 'reconnecting' && state.everSubscribed) {
    showBanner('Connection lost. Reconnecting… You can still send; new messages will appear once you’re back.');
  } else if (conn === 'offline') {
    showBanner('You’re offline. GlobalChat will reconnect when your connection returns.', 'danger');
  } else {
    el.banner.hidden = true;
  }
  if (conn !== 'live') renderOnline(null);
}

function showBanner(text, tone) {
  el.banner.textContent = text;
  if (tone) el.banner.dataset.tone = tone; else delete el.banner.dataset.tone;
  el.banner.hidden = false;
}

function renderOnline(n) {
  if (n == null) {
    el.onlineCount.textContent = '–';
    el.sideOnlineCount.textContent = '–';
    el.sideOnline.textContent = 'Counting people online…';
    el.peopleDialogSub.textContent = 'Counting people online…';
    state.people = [];
    renderPeople();
    renderCountries();
    renderTyping();
    return;
  }
  const label = n === 1 ? 'Just you online right now' : `${n.toLocaleString()} people online`;
  el.onlineCount.textContent = n.toLocaleString();
  el.sideOnlineCount.textContent = n.toLocaleString();
  el.sideOnline.textContent = label;
  el.peopleDialogSub.textContent = label;
}

function showFeedState(kind, detail) {
  const box = el.feedState;
  box.replaceChildren();
  const title = document.createElement('p');
  title.className = 'feed-state-title';
  const text = document.createElement('p');
  text.className = 'feed-state-text';

  if (kind === 'loading') {
    const sk = document.createElement('div');
    sk.className = 'skeleton';
    sk.setAttribute('aria-hidden', 'true');
    for (let i = 0; i < 4; i++) {
      const row = document.createElement('div');
      row.className = 'skeleton-row';
      row.append(document.createElement('span'), document.createElement('span'));
      sk.append(row);
    }
    const sr = document.createElement('p');
    sr.className = 'visually-hidden';
    sr.textContent = 'Loading messages';
    box.append(sk, sr);
    return;
  }

  if (kind === 'empty') {
    title.textContent = 'The room is quiet.';
    text.textContent = 'Nothing has been said in the last hour. Say hello and start the conversation.';
    const starters = document.createElement('div');
    starters.className = 'starters';
    for (const line of STARTERS) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'starter';
      b.textContent = line;
      b.addEventListener('click', () => {
        if (el.input.disabled) return;
        el.input.value = line;
        autosize();
        updateComposer();
        el.input.focus();
      });
      starters.append(b);
    }
    box.append(emptyArt(), title, text, starters);
    return;
  }

  if (kind === 'no-results') {
    title.textContent = 'No matches';
    text.textContent = 'Nothing in the last hour matches your search.';
    box.append(title, text);
    return;
  }

  if (kind === 'setup') {
    title.textContent = 'Connect GlobalChat to Supabase';
    text.append('Add your project URL and anon key to ');
    const code = document.createElement('code');
    code.textContent = 'config.js';
    text.append(code, ', then reload. README.md walks through every step.');
    box.append(title, text);
    return;
  }

  // error
  title.textContent = 'Can’t reach the room';
  text.textContent = detail || 'Something went wrong while connecting.';
  const retry = document.createElement('button');
  retry.type = 'button';
  retry.className = 'button button-primary';
  retry.textContent = 'Try again';
  retry.addEventListener('click', () => location.reload());
  box.append(title, text, retry);
}

function updateFeedState() {
  if (!state.historyLoaded) return;
  if (state.messages.size === 0) showFeedState('empty');
  else if (state.filter && !el.list.querySelector('.msg:not([hidden]):not([data-local])')) showFeedState('no-results');
  else el.feedState.replaceChildren();
}

// The brand mark, drawn larger for the empty room.
function emptyArt() {
  const mark = document.getElementById('brand-mark') ?? document.querySelector('.brand-mark');
  const art = mark.cloneNode(true);
  art.removeAttribute('id');
  art.classList.add('feed-state-art');
  return art;
}

function describeStartupError(err) {
  const msg = String(err?.message || err || '');
  if (/anonymous sign-ins are disabled/i.test(msg)) {
    return 'Anonymous sign-in is turned off for this Supabase project. Enable it under Authentication → Sign In / Providers.';
  }
  if (/captcha/i.test(msg)) return 'The bot check didn’t complete. Reload the page to try again.';
  if (/rate limit|too many/i.test(msg)) return 'Too many new sessions from your network. Wait a few minutes, then reload.';
  if (!navigator.onLine || /fetch|network/i.test(msg)) return 'You appear to be offline. Check your connection, then try again.';
  return 'GlobalChat couldn’t start a guest session. Try again in a moment.';
}

function isAuthError(error) {
  return error?.status === 401 || error?.code === 'PGRST301' || /jwt/i.test(error?.message ?? '');
}

// =============================================================================
// Composer
// =============================================================================
function enableComposer(on) {
  el.input.disabled = !on;
  updateComposer();
}

function updateComposer() {
  const text = normalizeText(el.input.value);
  const n = charCount(text);
  const over = n > MAX_LEN;
  el.counter.textContent = `${n} / ${MAX_LEN}`;
  el.counter.classList.toggle('is-near', n > MAX_LEN - 50 && !over);
  el.counter.classList.toggle('is-over', over);
  el.composer.classList.toggle('is-over', over);

  const cooling = Date.now() < state.cooldownUntil;
  el.send.disabled = el.input.disabled || state.sending || cooling || over || (n === 0 && !state.pendingImage);
  el.send.classList.toggle('is-busy', state.sending);
  el.send.setAttribute('aria-busy', String(state.sending));
}

function autosize() {
  el.input.style.height = 'auto';
  el.input.style.height = `${el.input.scrollHeight}px`;
}

function showComposerError(text) {
  el.composerError.textContent = text;
  el.composerError.hidden = !text;
}

// Client-side cooldown mirrors the server's 5-per-10s rule for nicer UX.
// The database still enforces the real limit.
function clientCooldownCheck() {
  const now = Date.now();
  state.sendTimes = state.sendTimes.filter((t) => now - t < BURST_WINDOW_MS);
  if (state.sendTimes.length >= BURST_LIMIT) {
    startCooldown(state.sendTimes[0] + BURST_WINDOW_MS);
    return false;
  }
  return true;
}

function startCooldown(until, label = (left) => `You're sending fast. You can send again in ${left}s.`) {
  state.cooldownUntil = Math.max(state.cooldownUntil, until);
  clearInterval(state.cooldownTimer);
  const tick = () => {
    const left = Math.ceil((state.cooldownUntil - Date.now()) / 1000);
    if (left <= 0) {
      clearInterval(state.cooldownTimer);
      showComposerError('');
      updateComposer();
      return;
    }
    showComposerError(label(left));
    updateComposer();
  };
  tick();
  state.cooldownTimer = setInterval(tick, 250);
}

async function sendMessage({ retried = false } = {}) {
  if (state.sending || el.input.disabled) return;
  if (state.editing) { await saveEdit(); return; }
  const raw = el.input.value;
  const text = normalizeText(raw);
  const n = charCount(text);
  const image = state.pendingImage;

  if (n === 0 && !image) { showComposerError('Type a message first.'); return; }
  if (n > MAX_LEN) { showComposerError(`Messages can be up to ${MAX_LEN} characters. Shorten it by ${n - MAX_LEN}.`); return; }
  if (!retried && !clientCooldownCheck()) return;
  if (!navigator.onLine) { showComposerError('You’re offline. Your message is still here; send it when you reconnect.'); return; }

  state.sending = true;
  showComposerError('');
  updateComposer();

  try {
    // Only send the new columns when used, so plain messages keep working
    // against a database that hasn't been upgraded yet.
    const row = baseRow(text);
    if (image) {
      row.kind = 'image';
      row.image_path = await uploadImage(image);
    }
    const data = await postRow(row);

    state.sendTimes.push(Date.now());
    // Only clear if the user didn't keep typing while we were sending.
    if (el.input.value === raw) { el.input.value = ''; saveDraft(); }
    autosize();
    setTyping(false);
    cancelReply();
    if (image) clearPendingImage({ sent: true });
    afterPosted(data);
  } catch (err) {
    await handleSendError(err, retried);
  } finally {
    state.sending = false;
    updateComposer();
    if (!el.input.disabled) el.input.focus({ preventScroll: true });
  }
}

// Columns every new message carries (only those this database version has).
function baseRow(content) {
  const row = { username: state.username, content };
  if (state.replyTo && state.tier >= 2) row.reply_to = state.replyTo;
  if (state.prefs.country && state.tier >= 3) row.country = state.prefs.country;
  return row;
}

async function postRow(row) {
  const { data, error } = await state.sb.from('messages').insert(row).select(columns()).single();
  if (error) throw error;
  return data;
}

function afterPosted(data) {
  if (data.username !== state.username && !data.is_bot) setUsername(data.username);
  upsertMessages([data], { initial: false });
  scrollToBottom();
  maybeBotReply();
  const slow = state.roomState?.slow_mode_seconds ?? 0;
  if (slow > 0) startCooldown(Date.now() + slow * 1000, slowLabel);
}

const slowLabel = (left) => `🐢 Slow mode: you can send again in ${left}s.`;

async function handleSendError(err, retried) {
  const msg = String(err?.message ?? '');
  console.warn('[GlobalChat] send failed', err);

  if (msg.includes('USERNAME_TAKEN') && !retried) {
    // Someone else holds this name: pick a new one and retry once.
    setUsername(generateUsername());
    state.sending = false;
    await sendMessage({ retried: true });
    return;
  }
  if (isAuthError(err) && !retried) {
    const { error } = await state.sb.auth.refreshSession();
    state.sending = false;
    if (!error) { await sendMessage({ retried: true }); return; }
  }

  const map = [
    ['RATE_LIMITED', () => { startCooldown(Date.now() + BURST_WINDOW_MS); return null; }],
    ['HOURLY_LIMIT', 'You’ve reached the hourly message limit for this session. Take a break and come back later.'],
    ['DUPLICATE_MESSAGE', 'You just sent that. Try saying something new.'],
    ['BANNED', 'This guest session can’t post because of a moderation action.'],
    ['EMPTY_MESSAGE', 'Type a message first.'],
    ['MESSAGE_TOO_LONG', `Messages can be up to ${MAX_LEN} characters.`],
    ['INVALID_USERNAME', 'Your guest name was rejected. Reload the page to get a new one.'],
    ['NOT_AUTHENTICATED', 'Your guest session expired. Reload the page to rejoin.'],
    ['REPLY_NOT_FOUND', () => {
      cancelReply();
      return 'The message you replied to is gone. Your message is still here; send it again.';
    }],
    ['INVALID_IMAGE', () => { clearPendingImage(); return 'That image couldn’t be sent. Try attaching it again.'; }],
    ['SLOW_MODE', () => {
      const secs = Number(/(\d+) seconds/.exec(err?.hint ?? '')?.[1]) || state.roomState?.slow_mode_seconds || 10;
      startCooldown(Date.now() + secs * 1000, slowLabel);
      loadRoomState();
      return null;
    }],
    ['UPLOAD_FAILED', () => uploadErrorText(msg)],
  ];
  for (const [code, out] of map) {
    if (msg.includes(code)) {
      const text = typeof out === 'function' ? out() : out;
      if (text) showComposerError(text);
      return;
    }
  }
  if (!navigator.onLine || /fetch|network/i.test(msg)) {
    showComposerError('Couldn’t send: you appear to be offline. Your message is still here.');
  } else {
    showComposerError('Couldn’t send your message. It’s still here; try again in a moment.');
  }
}

// =============================================================================
// Reporting
// =============================================================================
function openReport(messageId) {
  const entry = state.messages.get(messageId);
  if (!entry) return;
  state.reportTarget = messageId;
  el.reportForm.reset();
  el.reportQuoteName.textContent = entry.data.username;
  el.reportQuoteText.textContent = entry.data.content;   // safe: text only
  el.reportError.hidden = true;
  updateReportCounter();
  el.reportDialog.showModal();
}

function updateReportCounter() {
  const n = charCount(normalizeText(el.reportDetails.value));
  el.reportCounter.textContent = `${n} / 500`;
  el.reportCounter.classList.toggle('is-over', n > 500);
  return n;
}

async function submitReport(event) {
  event.preventDefault();
  if (state.reportSending) return;
  const reason = new FormData(el.reportForm).get('reason');
  const details = normalizeText(el.reportDetails.value);
  const fail = (text) => { el.reportError.textContent = text; el.reportError.hidden = false; };

  if (!reason) return fail('Choose what’s wrong with the message.');
  if (charCount(details) > 500) return fail('Details can be up to 500 characters.');

  state.reportSending = true;
  el.reportSubmit.disabled = true;
  el.reportSubmit.textContent = 'Sending…';
  try {
    // No .select(): reporters are not allowed to read reports back.
    const { error } = await state.sb.from('reports').insert({
      message_id: state.reportTarget,
      reason,
      details: details || null,
    });
    if (error) throw error;
    el.reportDialog.close();
    toast('Report sent. Moderators will review it.');
  } catch (err) {
    const msg = String(err?.message ?? '');
    if (err?.code === '23505') fail('You’ve already reported this message.');
    else if (msg.includes('REPORT_RATE_LIMITED')) fail('You’ve sent a lot of reports. Try again in a few minutes.');
    else if (msg.includes('MESSAGE_NOT_FOUND')) fail('That message has expired or was removed.');
    else if (msg.includes('CANNOT_REPORT_SELF')) fail('You can’t report your own message.');
    else fail('The report couldn’t be sent. Try again in a moment.');
  } finally {
    state.reportSending = false;
    el.reportSubmit.disabled = false;
    el.reportSubmit.textContent = 'Send report';
  }
}

// =============================================================================
// Rich text: links + @mentions, built from text nodes and elements only.
// =============================================================================
function renderRichText(target, text) {
  target.replaceChildren();
  let last = 0;
  for (const match of text.matchAll(RICH_TOKEN)) {
    const [whole, rawUrl, mention, code, spoiler, bold, italic] = match;
    let token = whole;
    if (rawUrl) {
      // Leave trailing punctuation ("see https://x.com.") outside the link.
      token = rawUrl.replace(/[.,!?;:'")\]]+$/, '');
      if (!token) continue;
    }
    if (match.index > last) target.append(text.slice(last, match.index));
    if (rawUrl) target.append(linkNode(token));
    else if (mention) {
      const span = document.createElement('span');
      span.className = 'mention';
      span.classList.toggle('is-me', state.myNames.get(mention) === null);
      span.textContent = token;
      target.append(span);
    } else if (code !== undefined) {
      const c = document.createElement('code');
      c.textContent = code;
      target.append(c);
    } else if (spoiler !== undefined) {
      const sp = document.createElement('span');
      sp.className = 'spoiler';
      sp.textContent = spoiler;
      sp.tabIndex = 0;
      sp.setAttribute('role', 'button');
      sp.setAttribute('aria-label', 'Spoiler: activate to reveal');
      const reveal = () => {
        sp.classList.add('is-revealed');
        sp.removeAttribute('role');
        sp.removeAttribute('tabindex');
        sp.removeAttribute('aria-label');
      };
      sp.addEventListener('click', reveal);
      sp.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); reveal(); } });
      target.append(sp);
    } else {
      const em = document.createElement(bold !== undefined ? 'strong' : 'em');
      em.textContent = bold ?? italic;
      target.append(em);
    }
    last = match.index + token.length;
  }
  if (last < text.length) target.append(text.slice(last));
}

function linkNode(raw) {
  let url;
  try { url = new URL(raw); } catch { return document.createTextNode(raw); }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return document.createTextNode(raw);
  const a = document.createElement('a');
  a.href = url.href;
  a.textContent = raw;
  a.target = '_blank';
  a.rel = 'noopener noreferrer nofollow ugc';
  return a;
}

function mentionsMe(text) {
  if (!state.username) return false;
  for (const match of text.matchAll(RICH_TOKEN)) {
    if (match[2] === state.username) return true;
  }
  return false;
}

// Is this someone else's message that mentions me or replies to me?
function isForMe(m) {
  if (!state.username || isMine(m) || isMutedMsg(m)) return false;
  return mentionsMe(m.content) || isMine(state.messages.get(m.reply_to)?.data);
}

// One-line summary of a message for reply quotes and notifications.
function previewText(m) {
  const text = m.kind === 'image' ? `📷 ${m.content || 'Photo'}`
    : m.kind === 'poll' ? `📊 ${m.content}`
    : m.content;
  const flat = text.replace(/\s+/g, ' ');
  return flat.length > 120 ? `${flat.slice(0, 119)}…` : flat;
}

function insertMention(name) {
  if (el.input.disabled || name === state.username) return;
  const tag = `@${name} `;
  const { value, selectionStart, selectionEnd } = el.input;
  const before = value.slice(0, selectionStart);
  const pad = before && !/\s$/.test(before) ? ' ' : '';
  el.input.value = before + pad + tag + value.slice(selectionEnd);
  const caret = before.length + pad.length + tag.length;
  el.input.setSelectionRange(caret, caret);
  autosize();
  updateComposer();
  el.input.focus();
}

async function copyMessage(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast('Message copied.');
  } catch {
    toast('Couldn’t copy. Select the text and copy it instead.', 'danger');
  }
}

// =============================================================================
// Presence: who's online + typing hints
// =============================================================================
async function trackPresence() {
  const channel = state.channel;
  if (!channel || state.connection !== 'live' || !state.username) return;
  try {
    await channel.track({
      name: state.username,
      typing: state.typing,
      country: state.tier >= 3 && state.prefs.country ? state.prefs.country : undefined,
      at: new Date().toISOString(),
    });
  } catch { /* presence is best-effort */ }
}

function syncPeople(presence) {
  const people = [];
  for (const [key, metas] of Object.entries(presence)) {
    const meta = metas?.[metas.length - 1] ?? {};
    const name = typeof meta.name === 'string' && /^[A-Za-z]{2,20}_[0-9]{4}$/.test(meta.name) ? meta.name : null;
    const country = typeof meta.country === 'string' && /^[A-Z]{2}$/.test(meta.country) ? meta.country : null;
    people.push({ key, name, country, typing: Boolean(meta.typing) && Boolean(name) });
  }
  // You first, then alphabetical; guests on older versions (no name) last.
  people.sort((a, b) => (b.key === state.presenceKey) - (a.key === state.presenceKey)
    || (a.name === null) - (b.name === null)
    || (a.name ?? '').localeCompare(b.name ?? ''));
  state.people = people;
  renderOnline(people.length);
  renderPeople();
  renderCountries();
  renderTyping();
  noteJoinsWhileAlone(people);
}

function renderPeople() {
  for (const list of [el.sidePeople, el.dialogPeople]) {
    list.replaceChildren();
    for (const p of state.people.slice(0, PEOPLE_SHOWN)) {
      const li = document.createElement('li');
      li.className = 'person';
      li.classList.toggle('is-typing', p.typing);
      const avatar = document.createElement('span');
      avatar.className = 'avatar';
      avatar.setAttribute('aria-hidden', 'true');
      paintAvatar(avatar, p.name ?? 'Guest');
      const name = document.createElement('span');
      name.className = 'person-name';
      name.textContent = p.name ?? 'Guest';
      if (p.country) name.append(` ${flagEmoji(p.country)}`);
      li.append(avatar, name);
      const isMe = p.key === state.presenceKey;
      if (isMe || p.typing) {
        const tag = document.createElement('span');
        tag.className = 'person-tag';
        tag.textContent = isMe ? 'you' : 'typing…';
        li.append(tag);
      }
      list.append(li);
    }
    const extra = state.people.length - PEOPLE_SHOWN;
    if (extra > 0) {
      const li = document.createElement('li');
      li.className = 'person-more';
      li.textContent = `+${extra.toLocaleString()} more`;
      list.append(li);
    }
  }
}

function renderTyping() {
  const names = state.people.filter((p) => p.typing && p.key !== state.presenceKey).map((p) => p.name);
  el.typing.replaceChildren();
  if (!names.length) return;
  const dots = document.createElement('span');
  dots.className = 'typing-dots';
  dots.setAttribute('aria-hidden', 'true');
  dots.append(document.createElement('i'), document.createElement('i'), document.createElement('i'));
  const text = names.length === 1 ? `${names[0]} is typing…`
    : names.length === 2 ? `${names[0]} and ${names[1]} are typing…`
    : `${names.length} people are typing…`;
  el.typing.append(dots, text);
}

function setTyping(on) {
  clearTimeout(state.typingTimer);
  if (on) state.typingTimer = setTimeout(() => setTyping(false), TYPING_IDLE_MS);
  if (state.typing === on) return;
  state.typing = on;
  trackPresence();
}

// =============================================================================
// Unread counter in the tab title + mention alerts
// =============================================================================
function noteUnread(count, mentions) {
  const away = document.visibilityState !== 'visible';
  if (away && count > 0) {
    state.titleUnread += count;
    if (mentions.length) state.titleMention = true;
    document.title = `${state.titleMention ? '@ ' : ''}(${state.titleUnread}) ${BASE_TITLE}`;
  }
  if (!mentions.length) return;
  if (state.prefs.sound) playPing();
  if (state.prefs.notify && away && 'Notification' in window && Notification.permission === 'granted') {
    const m = mentions[mentions.length - 1];
    try {
      const replied = !mentionsMe(m.content);
      const n = new Notification(`${m.username} ${replied ? 'replied to you' : 'mentioned you'}`, { body: previewText(m), tag: 'globalchat-mention', silent: state.prefs.sound });
      n.onclick = () => { window.focus(); n.close(); };
    } catch { /* some browsers only allow notifications from a service worker */ }
  }
}

function clearUnread() {
  state.titleUnread = 0;
  state.titleMention = false;
  document.title = BASE_TITLE;
}

// A short two-note chime, synthesised so there's no audio file to load.
function playPing() {
  try {
    state.audio ??= new AudioContext();
    const ctx = state.audio;
    if (ctx.state === 'suspended') ctx.resume();
    const t = ctx.currentTime;
    for (const [i, freq] of [[0, 880], [1, 1320]]) {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.value = freq;
      const start = t + i * 0.11;
      gain.gain.setValueAtTime(0.0001, start);
      gain.gain.exponentialRampToValueAtTime(0.15, start + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.25);
      osc.connect(gain).connect(ctx.destination);
      osc.start(start);
      osc.stop(start + 0.3);
    }
  } catch { /* audio is optional */ }
}

// =============================================================================
// Search (filters what's on screen; everything here is at most an hour old)
// =============================================================================
function applyFilter() {
  const q = state.filter.toLocaleLowerCase();
  let shown = 0;
  for (const { data, node } of state.messages.values()) {
    const haystack = [data.content, data.username, ...(data.poll_options ?? [])].join('\n').toLocaleLowerCase();
    const match = !q || haystack.includes(q);
    node.hidden = !match;
    if (match) shown++;
  }
  el.list.classList.toggle('is-filtering', Boolean(q));
  el.searchCount.textContent = q ? (shown === 1 ? '1 match' : `${shown} matches`) : '';
  updateFeedState();
}

function setSearchOpen(open) {
  el.searchBar.hidden = !open;
  el.searchToggle.setAttribute('aria-expanded', String(open));
  if (open) {
    el.searchInput.focus();
  } else {
    el.searchInput.value = '';
    state.filter = '';
    applyFilter();
    scrollToBottom();
  }
}

// =============================================================================
// Emoji picker
// =============================================================================
function buildEmojiPanel() {
  for (const emoji of EMOJI) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = emoji;
    b.setAttribute('aria-label', `Insert ${emoji}`);
    b.addEventListener('click', () => insertAtCursor(emoji));
    el.emojiPanel.append(b);
  }
}

function setEmojiOpen(open) {
  if (open) setAttachOpen(false);
  el.emojiPanel.hidden = !open;
  el.emojiToggle.setAttribute('aria-expanded', String(open));
}

function setAttachOpen(open) {
  if (open) setEmojiOpen(false);
  el.attachMenu.hidden = !open;
  el.attachToggle.setAttribute('aria-expanded', String(open));
  if (open) el.attachMenu.querySelector('button').focus();
}

function insertAtCursor(text) {
  if (el.input.disabled) return;
  const { value, selectionStart, selectionEnd } = el.input;
  el.input.value = value.slice(0, selectionStart) + text + value.slice(selectionEnd);
  const caret = selectionStart + text.length;
  el.input.setSelectionRange(caret, caret);
  autosize();
  updateComposer();
  el.input.focus({ preventScroll: true });
}

// =============================================================================
// Settings: theme, accent, density, mention alerts
// =============================================================================
function fillSettingsForm() {
  const f = el.settingsForm.elements;
  for (const key of ['theme', 'accent', 'density']) {
    for (const input of f[key]) input.checked = input.value === state.prefs[key];
  }
  f.sound.checked = state.prefs.sound;
  f.notify.checked = state.prefs.notify;
  f.soundAll.checked = state.prefs.soundAll;
  el.countrySelect.value = state.prefs.country;
  renderMutedList();
  showNotifyNote();
}

function showNotifyNote(text) {
  if (!text && state.prefs.notify && 'Notification' in window && Notification.permission === 'denied') {
    text = 'Notifications are blocked for this site in your browser settings.';
  }
  el.notifyNote.textContent = text ?? '';
  el.notifyNote.hidden = !text;
}

async function onSettingsChange(e) {
  const input = e.target;
  const prefs = { ...state.prefs };
  if (input.type === 'checkbox') prefs[input.name] = input.checked;
  else prefs[input.name] = input.value;

  let note;
  if (input.name === 'notify' && input.checked) {
    let permission = 'Notification' in window ? Notification.permission : 'unsupported';
    if (permission === 'default') permission = await Notification.requestPermission().catch(() => 'denied');
    if (permission !== 'granted') {
      input.checked = false;
      prefs.notify = false;
      note = permission === 'unsupported'
        ? 'This browser doesn’t support notifications.'
        : 'Notifications are blocked for this site in your browser settings.';
    }
  }
  if (input.name === 'sound' && input.checked) playPing();   // preview + unlock audio
  if (input.name === 'soundAll' && input.checked) playTick();

  state.prefs = prefs;
  window.GlobalChatPrefs?.save(prefs);
  showNotifyNote(note);
  if (input.name === 'country') { renderIdentityFlag(); trackPresence(); }
}

// =============================================================================
// Replies
// =============================================================================
function renderQuote(node, m) {
  const quote = node.querySelector('.msg-quote');
  quote.hidden = !m.reply_to;
  if (!m.reply_to) return;
  const target = state.messages.get(m.reply_to)?.data;
  quote.classList.toggle('is-gone', !target);
  quote.disabled = !target;
  quote.querySelector('.msg-quote-name').textContent = target ? target.username : 'Reply';
  quote.querySelector('.msg-quote-text').textContent = target ? previewText(target)
    : state.gone.has(m.reply_to) ? 'Original message is no longer available' : 'Earlier message';
  quote.setAttribute('aria-label', target ? `Replying to ${target.username}: ${previewText(target)}. Show message.` : 'Reply to a message that is no longer shown');
}

function startReply(id) {
  const entry = state.messages.get(id);
  if (!entry || el.input.disabled || state.legacy) return;
  state.replyTo = id;
  el.replyName.textContent = isMine(entry.data) ? 'yourself' : displayName(entry.data);
  el.replyText.textContent = previewText(entry.data);
  el.replyBar.hidden = false;
  el.input.focus();
}

function cancelReply() {
  state.replyTo = null;
  el.replyBar.hidden = true;
}

function scrollToMessage(id) {
  const entry = state.messages.get(id);
  if (!entry) return;
  if (entry.node.hidden) setSearchOpen(false);
  const smooth = !matchMedia('(prefers-reduced-motion: reduce)').matches;
  entry.node.scrollIntoView({ block: 'center', behavior: smooth ? 'smooth' : 'auto' });
  entry.node.classList.remove('is-flash');
  void entry.node.offsetWidth;   // restart the animation
  entry.node.classList.add('is-flash');
}

// =============================================================================
// Reactions
// =============================================================================
function renderReactions(node, m) {
  const box = node.querySelector('.msg-reactions');
  box.replaceChildren();
  const shown = REACTIONS.filter((e) => (m.reactions?.[e] ?? 0) > 0);
  box.hidden = shown.length === 0;
  for (const emoji of shown) {
    const n = m.reactions[emoji];
    const mine = m.mine?.has(emoji) ?? false;
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'reaction-chip';
    chip.dataset.emoji = emoji;
    chip.classList.toggle('is-mine', mine);
    chip.setAttribute('aria-pressed', String(mine));
    chip.setAttribute('aria-label', `${emoji} ${n} ${n === 1 ? 'reaction' : 'reactions'}${mine ? ', including yours' : ''}`);
    chip.textContent = `${emoji} ${n.toLocaleString()}`;
    chip.addEventListener('click', () => toggleReaction(m.id, emoji));
    box.append(chip);
  }
}

function applyReactions(id, counts, mine, bumped) {
  const entry = state.messages.get(id);
  if (!entry) return;
  entry.data.reactions = counts ?? {};
  if (mine) entry.data.mine = new Set(mine);
  renderReactions(entry.node, entry.data);
  if (bumped) entry.node.querySelector(`.reaction-chip[data-emoji="${bumped}"]`)?.classList.add('is-bump');
}

async function toggleReaction(id, emoji) {
  closeReactionPicker();
  if (!state.messages.has(id)) return;
  const { data, error } = await state.sb.rpc('gc_toggle_reaction', { p_message_id: id, p_emoji: emoji });
  if (error) { featureError(error, id); return; }
  applyReactions(id, data?.reactions, data?.mine, emoji);
}

function openReactionPicker(id, anchor) {
  const picker = el.reactionPicker;
  if (!picker.hidden && state.pickerFor === id) { closeReactionPicker(); return; }
  state.pickerFor = id;
  const mine = state.messages.get(id)?.data.mine ?? new Set();
  picker.replaceChildren();
  for (const emoji of REACTIONS) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = emoji;
    b.classList.toggle('is-mine', mine.has(emoji));
    b.setAttribute('aria-pressed', String(mine.has(emoji)));
    b.setAttribute('aria-label', `React with ${emoji}`);
    b.addEventListener('click', () => toggleReaction(id, emoji));
    picker.append(b);
  }
  picker.hidden = false;
  const r = anchor.getBoundingClientRect();
  const w = picker.offsetWidth;
  const h = picker.offsetHeight;
  const left = Math.min(Math.max(8, r.left + r.width / 2 - w / 2), window.innerWidth - w - 8);
  const top = r.top - h - 8 < 8 ? r.bottom + 8 : r.top - h - 8;
  picker.style.left = `${left}px`;
  picker.style.top = `${top}px`;
  picker.firstElementChild.focus({ preventScroll: true });
}

function closeReactionPicker() {
  if (el.reactionPicker.hidden) return;
  el.reactionPicker.hidden = true;
  state.pickerFor = null;
}

// =============================================================================
// Polls
// =============================================================================
function renderPoll(node, m) {
  const box = node.querySelector('.poll');
  box.hidden = false;
  box.replaceChildren();
  const counts = m.poll ?? m.poll_options.map(() => 0);
  const total = counts.reduce((a, b) => a + (Number(b) || 0), 0);
  m.poll_options.forEach((label, i) => {
    const n = Number(counts[i]) || 0;
    const pct = total ? Math.round((n * 100) / total) : 0;
    const mine = m.myVote === i;
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'poll-option';
    b.classList.toggle('is-mine', mine);
    b.style.setProperty('--pct', `${pct}%`);
    b.setAttribute('aria-pressed', String(mine));
    const name = document.createElement('span');
    name.className = 'poll-label';
    name.textContent = label;
    const stat = document.createElement('span');
    stat.className = 'poll-pct';
    stat.textContent = `${pct}%`;
    stat.title = n === 1 ? '1 vote' : `${n} votes`;
    b.append(name, stat);
    b.addEventListener('click', () => vote(m.id, i));
    box.append(b);
  });
  const foot = document.createElement('p');
  foot.className = 'poll-total';
  foot.textContent = `${total === 1 ? '1 vote' : `${total.toLocaleString()} votes`}${m.myVote != null ? ' · tap your choice again to undo' : ''}`;
  box.append(foot);
}

function applyPoll(id, counts, myVote) {
  const entry = state.messages.get(id);
  if (!entry || entry.data.kind !== 'poll') return;
  entry.data.poll = counts;
  if (myVote !== undefined) entry.data.myVote = myVote;
  renderPoll(entry.node, entry.data);
}

async function vote(id, option) {
  const { data, error } = await state.sb.rpc('gc_vote', { p_message_id: id, p_option: option });
  if (error) { featureError(error, id); return; }
  applyPoll(id, data?.counts ?? [], data?.my_vote ?? null);
}

function openPollDialog() {
  setAttachOpen(false);
  if (el.input.disabled || state.legacy) return;
  el.pollForm.reset();
  el.pollOptions.replaceChildren();
  addPollOption();
  addPollOption();
  el.pollError.hidden = true;
  el.pollDialog.showModal();
  el.pollQuestion.focus();
}

function addPollOption() {
  const rows = el.pollOptions.children;
  if (rows.length >= 4) return;
  const row = document.createElement('div');
  row.className = 'poll-option-row';
  const input = document.createElement('input');
  input.className = 'field field-line';
  input.maxLength = 80;
  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'icon-button icon-button-sm';
  remove.append(closeIcon());
  remove.addEventListener('click', () => { row.remove(); renumberPollOptions(); });
  row.append(input, remove);
  el.pollOptions.append(row);
  renumberPollOptions();
  if (rows.length > 2) input.focus();
}

function closeIcon() {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(ns, 'path');
  path.setAttribute('d', 'M6 6l12 12M18 6L6 18');
  svg.append(path);
  return svg;
}

function renumberPollOptions() {
  const rows = [...el.pollOptions.children];
  rows.forEach((row, i) => {
    const input = row.querySelector('input');
    input.placeholder = `Option ${i + 1}`;
    input.setAttribute('aria-label', `Option ${i + 1}`);
    const remove = row.querySelector('button');
    remove.hidden = rows.length <= 2;
    remove.setAttribute('aria-label', `Remove option ${i + 1}`);
  });
  el.pollAdd.hidden = rows.length >= 4;
}

async function submitPoll(event) {
  event.preventDefault();
  if (state.pollSending) return;
  const fail = (text) => { el.pollError.textContent = text; el.pollError.hidden = !text; };
  const question = normalizeText(el.pollQuestion.value).replace(/\n+/g, ' ');
  const options = [...el.pollOptions.querySelectorAll('input')]
    .map((i) => normalizeText(i.value).replace(/\n+/g, ' '))
    .filter(Boolean);

  if (!question) return fail('Write a question.');
  if (charCount(question) > 200) return fail('Questions can be up to 200 characters.');
  if (options.length < 2) return fail('Add at least two options.');
  if (new Set(options.map((o) => o.toLocaleLowerCase())).size !== options.length) return fail('Each option must be different.');
  if (Date.now() < state.cooldownUntil || !clientCooldownCheck()) return fail('You’re sending fast. Wait a few seconds.');

  state.pollSending = true;
  el.pollSubmit.disabled = true;
  fail('');
  try {
    const data = await postRow({ username: state.username, content: question, kind: 'poll', poll_options: options });
    state.sendTimes.push(Date.now());
    el.pollDialog.close();
    afterPosted(data);
  } catch (err) {
    const msg = String(err?.message ?? '');
    console.warn('[GlobalChat] poll failed', err);
    if (msg.includes('USERNAME_TAKEN')) {
      setUsername(generateUsername());
      fail('Your guest name was taken, so you have a new one. Post the poll again.');
    } else if (msg.includes('RATE_LIMITED')) fail('You’re sending fast. Wait a few seconds.');
    else if (msg.includes('HOURLY_LIMIT')) fail('You’ve reached the hourly message limit for this session.');
    else if (msg.includes('BANNED')) fail('This guest session can’t post because of a moderation action.');
    else if (msg.includes('INVALID_POLL')) fail('Polls need a question and 2 to 4 different options of up to 80 characters.');
    else fail('The poll couldn’t be posted. Try again in a moment.');
  } finally {
    state.pollSending = false;
    el.pollSubmit.disabled = false;
  }
}

// =============================================================================
// Images: prepare, upload, display
// =============================================================================
const toBlob = (canvas, type, quality) => new Promise((resolve) => canvas.toBlob(resolve, type, quality));

// Stills are redrawn on a canvas: big photos shrink, and hidden metadata such
// as GPS location is dropped. GIFs are kept as-is so they stay animated.
async function prepareImage(file) {
  if (!IMAGE_TYPES.includes(file.type)) throw new Error('Only PNG, JPG, WebP and GIF images can be shared.');
  if (file.type === 'image/gif') {
    if (file.size > MAX_UPLOAD_BYTES) throw new Error('GIFs can be up to 5 MB.');
    return { blob: file, type: 'image/gif', ext: 'gif' };
  }
  let bitmap;
  try { bitmap = await createImageBitmap(file); } catch { throw new Error('That image couldn’t be opened.'); }
  const scale = Math.min(1, MAX_IMAGE_DIM / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(bitmap.width * scale));
  canvas.height = Math.max(1, Math.round(bitmap.height * scale));
  const ctx = canvas.getContext('2d');
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close?.();

  let blob = await toBlob(canvas, 'image/webp', 0.85);
  if (!blob || blob.type !== 'image/webp') {
    // No WebP encoder (older Safari): JPEG on white, since JPEG has no alpha.
    ctx.globalCompositeOperation = 'destination-over';
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    blob = await toBlob(canvas, 'image/jpeg', 0.85);
  }
  if (!blob) throw new Error('That image couldn’t be prepared.');
  if (blob.size > MAX_UPLOAD_BYTES) throw new Error('That image is too big, even after resizing.');
  return { blob, type: blob.type, ext: blob.type === 'image/webp' ? 'webp' : 'jpg' };
}

async function attachImage(file) {
  setAttachOpen(false);
  if (!file || state.legacy || el.input.disabled) return;
  try {
    const img = await prepareImage(file);
    clearPendingImage();
    img.url = URL.createObjectURL(img.blob);
    state.pendingImage = img;
    el.imageThumb.src = img.url;
    el.imageName.textContent = img.type === 'image/gif' ? 'GIF ready to send' : 'Photo ready to send';
    el.imageMeta.textContent = `${formatBytes(img.blob.size)} · add a caption or just send`;
    el.imageBar.hidden = false;
    el.input.placeholder = 'Add a caption (optional)…';
    showComposerError('');
    updateComposer();
    el.input.focus();
  } catch (err) {
    showComposerError(err.message);
  }
}

// `sent`: the upload now belongs to a message, so keep the file.
function clearPendingImage({ sent = false } = {}) {
  const img = state.pendingImage;
  if (!img) return;
  state.pendingImage = null;
  URL.revokeObjectURL(img.url);
  if (img.path && !sent) state.sb?.storage.from(IMAGE_BUCKET).remove([img.path]).catch(() => {});
  el.imageBar.hidden = true;
  el.imageThumb.removeAttribute('src');
  el.input.placeholder = matchMedia('(max-width: 379px)').matches ? 'Message…' : 'Message everyone…';
  updateComposer();
}

async function uploadImage(image) {
  if (image.path) return image.path;   // already uploaded on an earlier attempt
  const path = `${state.session.user.id}/${crypto.randomUUID()}.${image.ext}`;
  const { error } = await state.sb.storage.from(IMAGE_BUCKET)
    .upload(path, image.blob, { contentType: image.type, upsert: false, cacheControl: '3600' });
  if (error) throw new Error(`UPLOAD_FAILED ${error.statusCode ?? ''} ${error.message ?? ''}`);
  image.path = path;
  return path;
}

function uploadErrorText(msg) {
  if (/row-level security|unauthori[sz]ed|403/i.test(msg)) return 'You’ve shared a lot of images. Try again in a few minutes.';
  if (/size|413|too large/i.test(msg)) return 'That image is too big. The limit is 5 MB.';
  if (/mime|content type|415/i.test(msg)) return 'That file type isn’t supported.';
  if (/bucket not found/i.test(msg)) return 'Image sharing isn’t set up on this server yet.';
  return 'The image couldn’t be uploaded. Try again in a moment.';
}

function formatBytes(n) {
  return n < 1024 * 1024 ? `${Math.max(1, Math.round(n / 1024))} KB` : `${(n / 1024 / 1024).toFixed(1)} MB`;
}

function renderImage(node, m) {
  const wrap = node.querySelector('.msg-image');
  const img = wrap.querySelector('img');
  wrap.hidden = false;
  wrap.classList.add('is-loading');
  img.alt = m.content ? `Image from ${m.username}: ${m.content}` : `Image from ${m.username}`;
  img.addEventListener('load', () => {
    wrap.classList.remove('is-loading');
    if (state.atBottom) scrollToBottom();
  });
  img.addEventListener('error', () => {
    wrap.classList.remove('is-loading');
    wrap.classList.add('is-broken');
  });
  wrap.addEventListener('click', () => {
    if (img.currentSrc && !wrap.classList.contains('is-broken')) openLightbox(m, img.currentSrc);
  });
  signedUrl(m).then((url) => {
    if (url) img.src = url;
    else img.dispatchEvent(new Event('error'));
  });
}

// The bucket is private: ask for a signed URL that lasts until the message
// expires (at most an hour). The storage policy refuses once it's gone.
async function signedUrl(m) {
  const cached = state.signedUrls.get(m.image_path);
  if (cached && cached.until > Date.now()) return cached.url;
  const ttl = Math.max(60, Math.min(3600, Math.ceil((Date.parse(m.expires_at) - Date.now()) / 1000) + 60));
  const { data, error } = await state.sb.storage.from(IMAGE_BUCKET).createSignedUrl(m.image_path, ttl);
  if (error || !data?.signedUrl) {
    console.warn('[GlobalChat] image unavailable', error);
    return null;
  }
  state.signedUrls.set(m.image_path, { url: data.signedUrl, until: Date.now() + (ttl - 30) * 1000 });
  return data.signedUrl;
}

function openLightbox(m, src) {
  el.lightboxImg.src = src;
  el.lightboxImg.alt = m.content || `Image from ${m.username}`;
  el.lightboxCaption.textContent = m.content ? `${m.username}: ${m.content}` : m.username;
  el.lightbox.showModal();
}

// =============================================================================
// Deleting your own message
// =============================================================================
function openDelete(id) {
  if (!state.messages.has(id)) return;
  state.deleteTarget = id;
  el.deleteDialog.showModal();
}

async function confirmDelete() {
  const id = state.deleteTarget;
  if (!id) return;
  el.deleteConfirm.disabled = true;
  const { error } = await state.sb.rpc('gc_delete_my_message', { p_message_id: id });
  el.deleteConfirm.disabled = false;
  el.deleteDialog.close();
  if (error && !String(error.message).includes('MESSAGE_NOT_FOUND')) { featureError(error, id); return; }
  removeMessage(id);
  if (!error) toast('Message deleted.');
}

// =============================================================================
// Reactions + poll totals for messages loaded from history
// =============================================================================
async function loadExtras(ids) {
  if (state.legacy || !ids.length || !state.sb) return;
  const { data, error } = await state.sb.rpc('gc_message_extras', { p_ids: ids });
  if (error) { console.warn('[GlobalChat] extras', error); return; }
  for (const [id, x] of Object.entries(data ?? {})) {
    const entry = state.messages.get(id);
    if (!entry) continue;
    if (x.reactions) {
      entry.data.reactions = x.reactions;
      entry.data.mine = new Set(x.mine ?? []);
      renderReactions(entry.node, entry.data);
    }
    if (Array.isArray(x.poll) && entry.data.kind === 'poll') {
      entry.data.poll = x.poll;
      entry.data.myVote = x.my_vote ?? null;
      renderPoll(entry.node, entry.data);
    }
  }
}

function featureError(error, id) {
  const msg = String(error?.message ?? '');
  console.warn('[GlobalChat]', error);
  if (msg.includes('RATE_LIMITED')) toast('Slow down a little and try again in a moment.', 'danger');
  else if (msg.includes('MESSAGE_NOT_FOUND')) { toast('That message has expired or was removed.'); removeMessage(id); }
  else if (msg.includes('BANNED')) toast('This guest session is blocked by a moderator.', 'danger');
  else toast('That didn’t work. Try again in a moment.', 'danger');
}

// =============================================================================
// Room bot (local only) + "someone joined" notes
// =============================================================================
const isAlone = () => state.connection === 'live'
  && state.people.length === 1 && state.people[0].key === state.presenceKey;

function botLines(name) {
  const tag = `@${name}`;
  const lines = [
    `Hey ${tag} 👋 You're the only one online right now, but your message is live. It stays up for an hour, so the next person who drops in will see it.`,
    `Hi ${tag}! It's quiet at the moment. Want company? Share the room with a friend: ${location.origin}${location.pathname}`,
    `Welcome ${tag} 🌍 You're first in! While you wait, tell the room where you're writing from, or what time it is there.`,
  ];
  if (!state.legacy) {
    lines.push(`Nice one ${tag}! Nobody else is here yet. Tip: start a poll with the + button, and people can vote as soon as they arrive.`);
  }
  return lines;
}

function maybeBotReply() {
  if (state.botRepliedWhileAlone || state.botReplies >= BOT_MAX_PER_TAB || !isAlone()) return;
  state.botRepliedWhileAlone = true;
  state.botReplies++;
  setTimeout(() => {
    if (!isAlone()) return;   // someone arrived meanwhile: let them answer
    const lines = botLines(state.username);
    addLocalNote('bot', lines[randomInt(lines.length)]);
  }, BOT_DELAY_MS);
}

function noteJoinsWhileAlone(people) {
  const others = people.filter((p) => p.key !== state.presenceKey);
  if (others.length === 0) {
    state.aloneSince ??= Date.now();
    return;
  }
  if (state.aloneSince && state.historyLoaded && Date.now() - state.aloneSince > JOIN_NOTE_AFTER_MS) {
    const name = others.find((p) => p.name)?.name;
    addLocalNote('join', `${name ?? 'Someone'} just joined. Say hi 👋`);
  }
  state.aloneSince = null;
  state.botRepliedWhileAlone = false;
}

function addLocalNote(kind, text) {
  const li = document.createElement('li');
  li.dataset.local = kind;
  li.dataset.time = String(Date.now());
  if (kind === 'bot') {
    li.className = 'msg is-bot';
    const avatar = document.createElement('span');
    avatar.className = 'avatar avatar-bot';
    avatar.setAttribute('aria-hidden', 'true');
    avatar.textContent = '🤖';
    const main = document.createElement('div');
    main.className = 'msg-main';
    const head = document.createElement('div');
    head.className = 'msg-head';
    const name = document.createElement('span');
    name.className = 'msg-name msg-name-bot';
    name.textContent = BOT_NAME;
    const badge = document.createElement('span');
    badge.className = 'msg-you msg-bot-badge';
    badge.textContent = 'auto';
    head.append(name, badge);
    const bubble = document.createElement('div');
    bubble.className = 'msg-bubble';
    const p = document.createElement('p');
    p.className = 'msg-text';
    renderRichText(p, text);
    bubble.append(p);
    const note = document.createElement('p');
    note.className = 'msg-bot-note';
    note.textContent = 'Automatic message · only you can see this';
    main.append(head, bubble, note);
    li.append(avatar, main);
  } else {
    li.className = 'room-note';
    li.setAttribute('role', 'status');
    const span = document.createElement('span');
    span.textContent = text;
    li.append(span);
  }
  const stick = isNearBottom();
  el.list.append(li);
  regroup(li.nextElementSibling);
  if (stick) scrollToBottom();
  else { state.unseen++; showJump(); }
}

// =============================================================================
// Country flags (optional, chosen in settings; never detected)
// =============================================================================
const regionNames = (() => {
  try { return new Intl.DisplayNames([navigator.language || 'en'], { type: 'region' }); } catch { return null; }
})();
const countryName = (code) => regionNames?.of(code) ?? code;
const flagEmoji = (code) => String.fromCodePoint(...[...code].map((c) => 0x1F1A5 + c.charCodeAt(0)));

function buildCountrySelect() {
  const none = document.createElement('option');
  none.value = '';
  none.textContent = 'No flag';
  const options = COUNTRY_CODES
    .map((code) => [code, countryName(code)])
    .sort((a, b) => a[1].localeCompare(b[1]))
    .map(([code, label]) => {
      const o = document.createElement('option');
      o.value = code;
      o.textContent = `${flagEmoji(code)} ${label}`;
      return o;
    });
  el.countrySelect.replaceChildren(none, ...options);
}

function renderIdentityFlag() {
  const code = state.tier >= 3 ? state.prefs.country : '';
  el.sideFlag.textContent = code ? flagEmoji(code) : '';
  el.sideFlag.title = code ? countryName(code) : '';
}

function renderCountries() {
  const counts = new Map();
  let unshared = 0;
  for (const p of state.people) {
    if (p.country) counts.set(p.country, (counts.get(p.country) ?? 0) + 1);
    else unshared++;
  }
  const sorted = [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  fillSlots('countries', (list) => {
    list.replaceChildren(...sorted.map(([code, n]) => {
      const li = document.createElement('li');
      li.title = countryName(code);
      li.textContent = `${flagEmoji(code)} ${n}`;
      li.setAttribute('aria-label', `${countryName(code)}: ${n}`);
      return li;
    }));
  });
  fillSlots('countries-note', (p) => {
    p.textContent = sorted.length
      ? (unshared ? `${unshared} more without a flag. Add yours in Appearance & alerts.` : '')
      : 'Nobody is showing a flag yet. Add yours in Appearance & alerts.';
  });
  showCards('countries', state.tier >= 3 && state.people.length > 0);
}

// Fill every element with data-slot="name" (sidebar + phone dialog copies).
function fillSlots(name, fn) {
  document.querySelectorAll(`[data-slot="${name}"]`).forEach(fn);
}
function showCards(name, show) {
  document.querySelectorAll(`[data-card="${name}"]`).forEach((c) => { c.hidden = !show; });
}

// =============================================================================
// Word of the day (same for everyone, by UTC date)
// =============================================================================
function renderWordOfDay() {
  const day = Math.floor(Date.now() / 86_400_000);
  const [word, lang, meaning] = WORDS[day % WORDS.length];
  fillSlots('wotd-word', (n) => { n.textContent = word; });
  fillSlots('wotd-lang', (n) => { n.textContent = `(${lang})`; });
  fillSlots('wotd-meaning', (n) => { n.textContent = meaning; });
}

// =============================================================================
// Room state: pinned message, slow mode, question of the day, stats
// =============================================================================
async function loadRoomState() {
  if (state.tier < 3 || !state.sb) return;
  const { data, error } = await state.sb.rpc('gc_room_state');
  if (error) { console.warn('[GlobalChat] room state', error); return; }
  applyRoomState(data);
}

function applyRoomState(rs) {
  if (!rs || typeof rs !== 'object') return;
  state.roomState = rs;

  const pin = rs.pinned && typeof rs.pinned.id === 'string' ? rs.pinned : null;
  el.pinBar.hidden = !pin;
  if (pin) {
    el.pinName.textContent = `${pin.is_bot ? BOT_NAME : pin.username}:`;
    el.pinContent.textContent = previewText({ kind: pin.kind ?? 'text', content: String(pin.content ?? '') });
    el.pinBar.onclick = () => {
      if (state.messages.has(pin.id)) scrollToMessage(pin.id);
      else toast('That message is older than what’s loaded here.');
    };
  }

  const slow = Number(rs.slow_mode_seconds) || 0;
  el.slowBar.hidden = slow <= 0;
  el.slowSeconds.textContent = String(slow);

  const q = typeof rs.daily_question === 'string' ? rs.daily_question : '';
  fillSlots('question', (n) => { n.textContent = q; });
  showCards('question', Boolean(q));

  renderStats(rs.stats);
}

function renderStats(stats) {
  if (!stats || typeof stats !== 'object') { showCards('stats', false); return; }
  const rows = [
    ['Messages today', Number(stats.today_messages) || 0],
    ['People today', Number(stats.today_people) || 0],
    ['Messages this week', Number(stats.week_messages) || 0],
  ];
  if (Number.isInteger(stats.busiest_hour_utc)) {
    const d = new Date();
    d.setUTCHours(stats.busiest_hour_utc, 0, 0, 0);
    rows.push(['Busiest hour (your time)', new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).format(d)]);
  }
  fillSlots('stats', (dl) => {
    dl.replaceChildren(...rows.flatMap(([label, value]) => {
      const dt = document.createElement('dt');
      dt.textContent = label;
      const dd = document.createElement('dd');
      dd.textContent = typeof value === 'number' ? value.toLocaleString() : value;
      return [dt, dd];
    }));
  });
  showCards('stats', true);
}

// =============================================================================
// "More" menu on a message: translate, copy, mute, report, delete
// =============================================================================
function openMoreMenu(id, anchor) {
  const menu = el.moreMenu;
  if (!menu.hidden && menu.dataset.for === id) { closeMoreMenu(); return; }
  const entry = state.messages.get(id);
  if (!entry) return;
  const m = entry.data;
  const mine = isMine(m);
  const items = [];
  if (m.content) {
    items.push(['🌐 Translate', () => translateMessage(id)]);
    items.push(['📋 Copy text', () => copyMessage(m.content)]);
  }
  if (!mine && !m.is_bot) {
    const muted = state.prefs.muted.includes(m.username);
    items.push([muted ? `🔊 Unmute ${m.username}` : `🔇 Mute ${m.username}`, () => toggleMute(m.username)]);
    items.push(['🚩 Report', () => openReport(id), 'danger']);
  }
  if (mine && state.tier >= 2) items.push(['🗑️ Delete', () => openDelete(id), 'danger']);
  if (!items.length) return;
  showMenu(items, anchor, id);
}

// Show the floating menu with [label, action, tone] items next to `anchor`.
function showMenu(items, anchor, key) {
  const menu = el.moreMenu;
  menu.replaceChildren(...items.map(([label, action, tone]) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.setAttribute('role', 'menuitem');
    b.textContent = label;
    if (tone === 'danger') b.classList.add('is-danger');
    b.addEventListener('click', () => { closeMoreMenu(); action(); });
    return b;
  }));
  menu.dataset.for = key;
  menu.hidden = false;
  const r = anchor.getBoundingClientRect();
  const left = Math.min(Math.max(8, r.right - menu.offsetWidth), window.innerWidth - menu.offsetWidth - 8);
  const below = r.bottom + 6 + menu.offsetHeight < window.innerHeight;
  menu.style.left = `${left}px`;
  menu.style.top = `${below ? r.bottom + 6 : Math.max(8, r.top - menu.offsetHeight - 6)}px`;
  menu.firstElementChild.focus({ preventScroll: true });
}

// Phones: Share, Appearance and About live in a header menu so the title fits.
function openHeadMenu(anchor) {
  if (!el.moreMenu.hidden && el.moreMenu.dataset.for === 'head') { closeMoreMenu(); return; }
  const items = [
    ['🔗 Share GlobalChat', shareRoom],
    ['🎨 Appearance & alerts', () => { fillSettingsForm(); el.settingsDialog.showModal(); }],
    ['ℹ️ Privacy and how it works', () => el.aboutDialog.showModal()],
  ];
  showMenu(items, anchor, 'head');
}

function closeMoreMenu() {
  if (el.moreMenu.hidden) return;
  el.moreMenu.hidden = true;
  delete el.moreMenu.dataset.for;
}

// =============================================================================
// Mute (this browser only)
// =============================================================================
const isMutedMsg = (m) => Boolean(m) && !m.is_bot && !isMine(m) && state.prefs.muted.includes(m.username);

function toggleMute(name) {
  const muted = new Set(state.prefs.muted);
  const nowMuted = !muted.has(name);
  if (nowMuted) muted.add(name); else muted.delete(name);
  state.prefs = { ...state.prefs, muted: [...muted] };
  window.GlobalChatPrefs?.save(state.prefs);
  for (const { data, node } of state.messages.values()) {
    if (data.username === name) {
      node.classList.toggle('is-muted', isMutedMsg(data));
      node.classList.remove('is-unmuted');
      node.classList.toggle('is-mention', isForMe(data));
    }
  }
  renderMutedList();
  toast(nowMuted ? `Muted ${name}. Only you stop seeing their messages.` : `Unmuted ${name}.`);
}

function renderMutedList() {
  el.mutedList.replaceChildren(...state.prefs.muted.map((name) => {
    const li = document.createElement('li');
    const span = document.createElement('span');
    span.textContent = name;
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'link-button';
    b.textContent = 'Unmute';
    b.addEventListener('click', () => toggleMute(name));
    li.append(span, b);
    return li;
  }));
  el.mutedEmpty.hidden = state.prefs.muted.length > 0;
}

// =============================================================================
// Translate: the browser's on-device translator if it has one, otherwise
// Google Translate in a new tab (the user picks it, and is told about it).
// =============================================================================
async function translateMessage(id) {
  const entry = state.messages.get(id);
  if (!entry?.data.content) return;
  const text = entry.data.content;
  const out = entry.node.querySelector('.msg-translation');
  const target = (navigator.language || 'en').split('-')[0];
  if (!out.hidden) { out.hidden = true; return; }

  if ('Translator' in self && 'LanguageDetector' in self) {
    try {
      out.hidden = false;
      out.textContent = 'Translating…';
      const detector = await self.LanguageDetector.create();
      const source = (await detector.detect(text))?.[0]?.detectedLanguage;
      if (!source || source === 'und') throw new Error('unknown language');
      if (source === target) { out.textContent = 'This is already in your language.'; return; }
      const translator = await self.Translator.create({ sourceLanguage: source, targetLanguage: target });
      const result = await translator.translate(text);
      const note = document.createElement('small');
      let from = source;
      try { from = new Intl.DisplayNames([target], { type: 'language' }).of(source) ?? source; } catch { /* keep code */ }
      note.textContent = `Translated from ${from} by your browser`;
      out.replaceChildren(document.createTextNode(result), note);
      return;
    } catch (err) {
      // We've awaited, so the click no longer counts for opening a tab
      // (popup blockers). Offer a link the person can click instead.
      console.info('[GlobalChat] on-device translation unavailable', err);
      const a = document.createElement('a');
      a.href = googleTranslateUrl(text, target);
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
      a.textContent = 'Open in Google Translate ↗';
      out.replaceChildren('Your browser couldn’t translate this. ', a);
      return;
    }
  }
  window.open(googleTranslateUrl(text, target), '_blank', 'noopener,noreferrer');
  toast('Opened Google Translate in a new tab.');
}

const googleTranslateUrl = (text, target) =>
  `https://translate.google.com/?sl=auto&tl=${encodeURIComponent(target)}&op=translate&text=${encodeURIComponent(text)}`;

// =============================================================================
// Editing your own message (2 minutes)
// =============================================================================
function startEdit(id) {
  const entry = state.messages.get(id);
  if (!entry || !isMine(entry.data) || !isEditable(entry.data) || el.input.disabled) return;
  cancelReply();
  clearPendingImage();
  state.editing = id;
  el.editText.textContent = previewText(entry.data);
  el.editBar.hidden = false;
  el.input.value = entry.data.content;
  autosize();
  updateComposer();
  el.input.focus();
  el.input.setSelectionRange(el.input.value.length, el.input.value.length);
}

function cancelEdit({ keepText = false } = {}) {
  if (!state.editing) return;
  state.editing = null;
  el.editBar.hidden = true;
  if (!keepText) { el.input.value = ''; restoreDraft(); }
  autosize();
  updateComposer();
}

async function saveEdit() {
  const id = state.editing;
  const text = normalizeText(el.input.value);
  if (!text) { showComposerError('Type something, or press Esc to cancel editing.'); return; }
  if (charCount(text) > MAX_LEN) { showComposerError(`Messages can be up to ${MAX_LEN} characters.`); return; }
  state.sending = true;
  updateComposer();
  try {
    const { data, error } = await state.sb.rpc('gc_edit_message', { p_message_id: id, p_content: text });
    if (error) throw error;
    applyEdit(id, data?.content ?? text, data?.edited_at ?? new Date().toISOString());
    cancelEdit();
    showComposerError('');
  } catch (err) {
    const msg = String(err?.message ?? '');
    console.warn('[GlobalChat] edit failed', err);
    if (msg.includes('EDIT_WINDOW_PASSED')) { cancelEdit({ keepText: true }); showComposerError('The 2-minute edit window has passed. Your text is still here if you want to send it as a new message.'); }
    else if (msg.includes('RATE_LIMITED')) showComposerError('Slow down a little and try again.');
    else if (msg.includes('MESSAGE_NOT_FOUND')) { cancelEdit({ keepText: true }); showComposerError('That message is gone. Your text is still here.'); }
    else showComposerError('Couldn’t save the edit. Try again in a moment.');
  } finally {
    state.sending = false;
    updateComposer();
  }
}

function applyEdit(id, content, editedAt) {
  const entry = state.messages.get(id);
  if (!entry || typeof content !== 'string') return;
  entry.data.content = content;
  entry.data.edited_at = editedAt;
  renderRichText(entry.node.querySelector('.msg-text'), content);
  entry.node.querySelector('.msg-translation').hidden = true;
  renderEdited(entry.node, entry.data);
  entry.node.classList.toggle('is-mention', isForMe(entry.data));
  refreshRepliesTo(id);
  if (state.filter) applyFilter();
}

// =============================================================================
// Choose your own name
// =============================================================================
function openRename() {
  if (state.tier < 3 || !state.session) return;
  el.renameForm.reset();
  el.renameError.hidden = true;
  el.renameInput.value = (state.username ?? '').split('_')[0];
  el.renameDigits.textContent = `_${1000 + randomInt(9000)}`;
  el.renameDialog.showModal();
  el.renameInput.select();
}

async function submitRename(event) {
  event.preventDefault();
  const fail = (text) => { el.renameError.textContent = text; el.renameError.hidden = !text; };
  const letters = el.renameInput.value.replace(/[^A-Za-z]/g, '');
  if (letters.length < 2) return fail('Use at least 2 letters (A–Z).');
  const word = letters.charAt(0).toUpperCase() + letters.slice(1, 16);
  el.renameSubmit.disabled = true;
  fail('');
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      const name = `${word}${el.renameDigits.textContent}`;
      const { data, error } = await state.sb.rpc('gc_rename', { p_username: name });
      if (!error) {
        setUsername(typeof data === 'string' ? data : name);
        el.renameDialog.close();
        toast(`You're now ${state.username}. Messages you already sent keep your old name.`);
        return;
      }
      const msg = String(error.message ?? '');
      if (msg.includes('USERNAME_TAKEN')) { el.renameDigits.textContent = `_${1000 + randomInt(9000)}`; continue; }
      if (msg.includes('INVALID_USERNAME')) return fail('That name isn’t allowed. Try another.');
      if (msg.includes('RATE_LIMITED')) return fail('You changed your name a moment ago. Try again in a few seconds.');
      return fail('Couldn’t change your name. Try again in a moment.');
    }
    fail('That name is popular! Try a different one.');
  } finally {
    el.renameSubmit.disabled = false;
  }
}

// =============================================================================
// Stickers
// =============================================================================
function buildStickerPanel() {
  for (const [id, label] of STICKERS) {
    const b = document.createElement('button');
    b.type = 'button';
    b.setAttribute('aria-label', `Send sticker: ${label}`);
    const img = document.createElement('img');
    img.src = `stickers/${id}.svg`;
    img.alt = '';
    img.width = 68;
    img.height = 68;
    b.append(img);
    b.addEventListener('click', () => sendSticker(id));
    el.stickerPanel.append(b);
  }
}

function setStickerOpen(open) {
  if (open) { setAttachOpen(false); setEmojiOpen(false); }
  el.stickerPanel.hidden = !open;
  if (open) el.stickerPanel.querySelector('button')?.focus();
}

async function sendSticker(id) {
  setStickerOpen(false);
  await postSpecial({ ...baseRow(''), kind: 'sticker', sticker: id });
  cancelReply();
}

function renderSticker(node, m) {
  const img = node.querySelector('.msg-sticker');
  const label = STICKERS.find(([id]) => id === m.sticker)?.[1] ?? m.sticker;
  img.hidden = false;
  img.src = `stickers/${m.sticker}.svg`;
  img.alt = `Sticker: ${label}`;
  node.classList.add('is-sticker');
}

// Send a non-text message (sticker, voice note) with the same checks and
// error messages as the composer.
async function postSpecial(row) {
  if (el.input.disabled) return null;
  if (Date.now() < state.cooldownUntil || !clientCooldownCheck()) return null;
  try {
    const data = await postRow(row);
    state.sendTimes.push(Date.now());
    afterPosted(data);
    return data;
  } catch (err) {
    const msg = String(err?.message ?? '');
    if (msg.includes('USERNAME_TAKEN')) {
      setUsername(generateUsername());
      showComposerError('Your guest name was taken, so you have a new one. Try again.');
    } else {
      await handleSendError(err, true);
    }
    return null;
  }
}

// =============================================================================
// Voice notes (up to 30 s, private storage like photos)
// =============================================================================
async function startVoice() {
  setAttachOpen(false);
  if (state.recorder || el.input.disabled) return;
  if (!navigator.mediaDevices?.getUserMedia || !('MediaRecorder' in window)) {
    showComposerError('Voice notes aren’t supported in this browser.');
    return;
  }
  const type = VOICE_TYPES.find(([mime]) => MediaRecorder.isTypeSupported(mime));
  if (!type) { showComposerError('This browser can’t record a supported audio format.'); return; }
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch {
    showComposerError('Microphone access was blocked. Allow it in your browser to record a voice note.');
    return;
  }
  const rec = new MediaRecorder(stream, { mimeType: type[0], audioBitsPerSecond: 48_000 });
  const r = { rec, stream, chunks: [], startedAt: Date.now(), type: type[1], ext: type[2] };
  state.recorder = r;
  rec.addEventListener('dataavailable', (e) => { if (e.data.size) r.chunks.push(e.data); });
  rec.addEventListener('stop', () => {
    stream.getTracks().forEach((t) => t.stop());
    clearInterval(r.timer);
    if (state.recorder !== r) return;
    r.blob = new Blob(r.chunks, { type: r.type });
    r.url = URL.createObjectURL(r.blob);
    el.voicePreview.src = r.url;
    el.voicePreview.hidden = false;
    el.voiceBar.classList.add('is-stopped');
    el.voiceLabel.textContent = 'Voice note ready';
    el.voiceStop.hidden = true;
    el.voiceSend.hidden = false;
    el.voiceSend.focus();
  });
  rec.start(250);
  el.voiceBar.hidden = false;
  el.voiceBar.classList.remove('is-stopped');
  el.voiceLabel.textContent = 'Recording…';
  el.voicePreview.hidden = true;
  el.voiceStop.hidden = false;
  el.voiceSend.hidden = true;
  const tick = () => {
    const ms = Date.now() - r.startedAt;
    const secs = Math.min(30, Math.floor(ms / 1000));
    el.voiceTime.textContent = `0:${String(secs).padStart(2, '0')} / 0:30`;
    if (ms >= VOICE_MAX_MS && rec.state === 'recording') rec.stop();
  };
  tick();
  r.timer = setInterval(tick, 250);
  el.voiceStop.focus();
}

function stopVoice() {
  if (state.recorder?.rec.state === 'recording') state.recorder.rec.stop();
}

function cancelVoice() {
  const r = state.recorder;
  if (!r) return;
  state.recorder = null;
  clearInterval(r.timer);
  if (r.rec.state === 'recording') r.rec.stop();
  r.stream.getTracks().forEach((t) => t.stop());
  if (r.url) URL.revokeObjectURL(r.url);
  if (r.path) state.sb?.storage.from(IMAGE_BUCKET).remove([r.path]).catch(() => {});
  el.voicePreview.removeAttribute('src');
  el.voiceBar.hidden = true;
}

async function sendVoice() {
  const r = state.recorder;
  if (!r?.blob) return;
  if (r.blob.size > MAX_UPLOAD_BYTES) { showComposerError('That voice note is too big.'); return; }
  el.voiceSend.disabled = true;
  try {
    if (!r.path) {
      const path = `${state.session.user.id}/${crypto.randomUUID()}.${r.ext}`;
      const { error } = await state.sb.storage.from(IMAGE_BUCKET)
        .upload(path, r.blob, { contentType: r.type, upsert: false, cacheControl: '3600' });
      if (error) throw new Error(`UPLOAD_FAILED ${error.statusCode ?? ''} ${error.message ?? ''}`);
      r.path = path;
    }
    const data = await postSpecial({ ...baseRow(''), kind: 'voice', image_path: r.path });
    if (data) {
      r.path = null;   // the file now belongs to the message
      cancelVoice();
      cancelReply();
    }
  } catch (err) {
    await handleSendError(err, true);
  } finally {
    el.voiceSend.disabled = false;
  }
}

function renderVoice(node, m) {
  const audio = node.querySelector('.msg-voice');
  audio.hidden = false;
  audio.setAttribute('aria-label', `Voice note from ${displayName(m)}`);
  signedUrl(m).then((url) => { if (url) audio.src = url; });
}

// =============================================================================
// Little delights: confetti, message sound, drafts, share
// =============================================================================
function maybeConfetti(list) {
  if (!list.some((m) => !isMutedMsg(m) && CONFETTI_WORDS.test(m.content))) return;
  if (Date.now() - state.confettiAt < 8000) return;
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  state.confettiAt = Date.now();
  runConfetti();
}

function runConfetti() {
  const canvas = el.confetti;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = window.innerWidth * dpr;
  canvas.height = window.innerHeight * dpr;
  canvas.hidden = false;
  ctx.scale(dpr, dpr);
  const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#8B5CF6';
  const colors = [accent, '#FBBF24', '#34D399', '#60A5FA', '#F472B6', '#FFFFFF'];
  const parts = Array.from({ length: 140 }, () => ({
    x: Math.random() * window.innerWidth,
    y: -20 - Math.random() * window.innerHeight * 0.4,
    vx: (Math.random() - 0.5) * 3,
    vy: 2 + Math.random() * 3,
    r: Math.random() * Math.PI,
    vr: (Math.random() - 0.5) * 0.3,
    w: 6 + Math.random() * 6,
    h: 8 + Math.random() * 8,
    c: colors[Math.floor(Math.random() * colors.length)],
  }));
  const start = performance.now();
  const frame = (t) => {
    const elapsed = t - start;
    ctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    ctx.globalAlpha = elapsed > 2200 ? Math.max(0, 1 - (elapsed - 2200) / 600) : 1;
    for (const p of parts) {
      p.x += p.vx; p.y += p.vy; p.vy += 0.04; p.r += p.vr;
      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate(p.r);
      ctx.fillStyle = p.c;
      ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h);
      ctx.restore();
    }
    if (elapsed < 2800) requestAnimationFrame(frame);
    else { ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, canvas.width, canvas.height); canvas.hidden = true; }
  };
  requestAnimationFrame(frame);
}

// A soft single "tick" for every new message (setting), throttled.
function playTick() {
  if (Date.now() - state.audioTick < 800) return;
  state.audioTick = Date.now();
  try {
    state.audio ??= new AudioContext();
    const ctx = state.audio;
    if (ctx.state === 'suspended') ctx.resume();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = 'triangle';
    osc.frequency.value = 660;
    const t = ctx.currentTime;
    gain.gain.setValueAtTime(0.0001, t);
    gain.gain.exponentialRampToValueAtTime(0.06, t + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.12);
    osc.connect(gain).connect(ctx.destination);
    osc.start(t);
    osc.stop(t + 0.14);
  } catch { /* audio is optional */ }
}

function saveDraft() {
  if (state.editing) return;
  try {
    if (el.input.value.trim()) sessionStorage.setItem(DRAFT_KEY, el.input.value);
    else sessionStorage.removeItem(DRAFT_KEY);
  } catch { /* storage unavailable */ }
}

function restoreDraft() {
  try {
    const draft = sessionStorage.getItem(DRAFT_KEY);
    if (draft && !el.input.value) { el.input.value = draft; autosize(); updateComposer(); }
  } catch { /* storage unavailable */ }
}

async function shareRoom() {
  const url = `${location.origin}${location.pathname}`;
  if (navigator.share) {
    try { await navigator.share({ title: 'GlobalChat', text: SHARE_TEXT, url }); return; }
    catch (err) { if (err?.name === 'AbortError') return; }
  }
  try {
    await navigator.clipboard.writeText(`${SHARE_TEXT} ${url}`);
    toast('Link copied. Paste it anywhere to invite people.');
  } catch {
    toast(`Share this link: ${url}`);
  }
}

// =============================================================================
// Donations (config.js → DONATE). Hidden unless the site owner filled it in.
// =============================================================================
const UPI_ID_RE = /^[A-Za-z0-9._-]{2,256}@[A-Za-z][A-Za-z0-9.-]{1,63}$/;

function donateConfig() {
  const d = CONFIG?.DONATE ?? {};
  const upi = typeof d.UPI_ID === 'string' && UPI_ID_RE.test(d.UPI_ID.trim()) ? d.UPI_ID.trim() : '';
  const name = (typeof d.UPI_NAME === 'string' && d.UPI_NAME.trim().slice(0, 50)) || 'GlobalChat';
  const links = (Array.isArray(d.LINKS) ? d.LINKS : [])
    .map((l) => {
      try {
        const url = new URL(String(l?.url ?? ''));
        const label = String(l?.label ?? '').trim().slice(0, 40);
        return url.protocol === 'https:' && label ? { label, url: url.href } : null;
      } catch { return null; }
    })
    .filter(Boolean)
    .slice(0, 4);
  return { upi, name, links, enabled: Boolean(upi || links.length) };
}

function setupDonations() {
  const cfg = donateConfig();
  document.querySelectorAll('[data-open-donate], [data-donate-about]').forEach((n) => { n.hidden = !cfg.enabled; });
  if (!cfg.enabled) return;

  const dialog = $('donate-dialog');
  document.querySelectorAll('[data-open-donate]').forEach((b) => b.addEventListener('click', () => {
    b.closest('dialog')?.close();
    dialog.showModal();
    if (cfg.upi) renderUpi(cfg, currentAmount());
  }));
  dialog.addEventListener('click', (e) => { if (e.target === dialog) dialog.close(); });

  const upiBox = $('donate-upi');
  upiBox.hidden = !cfg.upi;
  if (cfg.upi) {
    $('donate-upi-id').textContent = cfg.upi;
    $('donate-copy').addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(cfg.upi); toast('UPI ID copied.'); }
      catch { toast(`UPI ID: ${cfg.upi}`); }
    });
    upiBox.querySelectorAll('[data-amount]').forEach((b) => b.addEventListener('click', () => {
      upiBox.querySelectorAll('[data-amount]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
      renderUpi(cfg, b.dataset.amount);
    }));
  }

  const linksBox = $('donate-links');
  linksBox.hidden = cfg.links.length === 0;
  linksBox.replaceChildren(...cfg.links.map(({ label, url }) => {
    const a = document.createElement('a');
    a.className = 'button button-quiet';
    a.href = url;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.textContent = `${label} ↗`;
    return a;
  }));
}

function currentAmount() {
  return $('donate-upi').querySelector('[data-amount][aria-pressed="true"]')?.dataset.amount ?? '';
}

// upi://pay link (NPCI format) + a QR code of the same link for computers.
function renderUpi(cfg, amount) {
  const params = new URLSearchParams({ pa: cfg.upi, pn: cfg.name, cu: 'INR', tn: 'Support GlobalChat' });
  if (amount) params.set('am', `${Number(amount).toFixed(2)}`);
  // Keep "@" literal in the UPI ID (as in NPCI's examples); some apps don't decode %40.
  const link = `upi://pay?${params.toString().replace(/\+/g, '%20').replace(/%40/g, '@')}`;
  $('donate-pay').href = link;
  $('donate-pay').textContent = amount ? `Pay ₹${amount} with a UPI app` : 'Pay with a UPI app';
  drawQr(link);
}

let qrLoading = null;
function loadQrLibrary() {
  // Self-hosted copy of qrcode-generator 1.4.4 (MIT, Kazuhiko Arase).
  qrLoading ??= new Promise((resolve, reject) => {
    if (window.qrcode) { resolve(window.qrcode); return; }
    const s = document.createElement('script');
    s.src = 'vendor/qrcode.js';
    s.onload = () => (window.qrcode ? resolve(window.qrcode) : reject(new Error('qrcode missing')));
    s.onerror = reject;
    document.head.append(s);
  });
  return qrLoading;
}

async function drawQr(text) {
  const canvas = $('donate-qr');
  try {
    const qrcode = await loadQrLibrary();
    const qr = qrcode(0, 'M');
    qr.addData(text);
    qr.make();
    const count = qr.getModuleCount();
    const quiet = 3;
    const cell = Math.floor(canvas.width / (count + quiet * 2));
    const offset = Math.floor((canvas.width - cell * count) / 2);
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#000';
    for (let r = 0; r < count; r++) {
      for (let c = 0; c < count; c++) {
        if (qr.isDark(r, c)) ctx.fillRect(offset + c * cell, offset + r * cell, cell, cell);
      }
    }
    canvas.dataset.qr = text;
  } catch (err) {
    console.warn('[GlobalChat] QR code unavailable', err);
    canvas.hidden = true;
  }
}

// =============================================================================
// Toasts
// =============================================================================
function toast(text, tone) {
  const t = document.createElement('div');
  t.className = 'toast';
  if (tone) t.dataset.tone = tone;
  t.textContent = text;
  el.toasts.append(t);
  setTimeout(() => t.remove(), 4500);
}

// =============================================================================
// UI wiring
// =============================================================================
function wireUI() {
  // Composer
  el.composer.addEventListener('submit', (e) => { e.preventDefault(); sendMessage(); });
  el.input.addEventListener('keydown', (e) => {
    // Enter sends; Shift+Enter = newline; never interrupt IME composition.
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) {
      e.preventDefault();
      sendMessage();
    }
  });
  el.input.addEventListener('input', () => {
    autosize();
    updateComposer();
    saveDraft();
    el.commandHint.hidden = !(state.tier >= 3 && !state.editing && el.input.value.startsWith('/'));
    setTyping(el.input.value.trim().length > 0);
    if (!el.composerError.hidden && Date.now() >= state.cooldownUntil) showComposerError('');
  });
  el.input.addEventListener('blur', () => setTyping(false));
  el.input.addEventListener('paste', (e) => {
    const file = [...(e.clipboardData?.files ?? [])].find((f) => f.type.startsWith('image/'));
    if (file && !state.legacy) { e.preventDefault(); attachImage(file); }
  });

  // Community features
  setupDonations();
  buildCountrySelect();
  buildStickerPanel();
  renderWordOfDay();
  renderIdentityFlag();
  restoreDraft();
  setInterval(loadRoomState, ROOM_STATE_REFRESH_MS);
  el.shareButton.addEventListener('click', shareRoom);
  document.getElementById('head-menu').addEventListener('click', (e) => openHeadMenu(e.currentTarget));

  // Touch screens: tap a message to show its actions (they float over it, so
  // bubbles keep their full width). Tap elsewhere to hide them again.
  el.list.addEventListener('click', (e) => {
    if (!matchMedia('(hover: none), (max-width: 599px)').matches) return;
    if (e.target.closest('button, a, audio, input, .spoiler, .msg-actions')) return;
    const msg = e.target.closest('.msg:not([data-local])');
    const wasSelected = msg?.classList.contains('is-selected');
    el.list.querySelectorAll('.msg.is-selected').forEach((n) => n.classList.remove('is-selected'));
    if (msg && !wasSelected) msg.classList.add('is-selected');
  });

  // A shorter placeholder on narrow screens so it doesn't wrap.
  const narrow = matchMedia('(max-width: 379px)');
  const setPlaceholder = () => {
    if (!state.pendingImage) el.input.placeholder = narrow.matches ? 'Message…' : 'Message everyone…';
  };
  narrow.addEventListener('change', setPlaceholder);
  setPlaceholder();
  el.editCancel.addEventListener('click', () => { cancelEdit(); el.input.focus(); });
  el.attachSticker.addEventListener('click', () => setStickerOpen(true));
  el.attachVoice.addEventListener('click', startVoice);
  el.voiceStop.addEventListener('click', stopVoice);
  el.voiceSend.addEventListener('click', sendVoice);
  el.voiceCancel.addEventListener('click', cancelVoice);
  document.querySelectorAll('[data-open-rename]').forEach((b) => b.addEventListener('click', () => {
    b.closest('dialog')?.close();
    openRename();
  }));
  el.renameForm.addEventListener('submit', submitRename);
  el.renameInput.addEventListener('input', () => {
    const clean = el.renameInput.value.replace(/[^A-Za-z]/g, '');
    if (clean !== el.renameInput.value) el.renameInput.value = clean;
  });
  document.querySelectorAll('[data-answer-question]').forEach((b) => b.addEventListener('click', () => {
    b.closest('dialog')?.close();
    el.input.focus();
  }));

  // Replies, images, polls
  el.replyCancel.addEventListener('click', () => { cancelReply(); el.input.focus(); });
  el.imageCancel.addEventListener('click', () => { clearPendingImage(); el.input.focus(); });
  el.attachToggle.addEventListener('click', () => setAttachOpen(el.attachMenu.hidden));
  el.attachImage.addEventListener('click', () => { setAttachOpen(false); el.imageInput.click(); });
  el.attachPoll.addEventListener('click', openPollDialog);
  el.imageInput.addEventListener('change', () => {
    attachImage(el.imageInput.files?.[0]);
    el.imageInput.value = '';
  });
  el.pollAdd.addEventListener('click', addPollOption);
  el.pollForm.addEventListener('submit', submitPoll);
  el.deleteConfirm.addEventListener('click', confirmDelete);
  el.deleteDialog.addEventListener('close', () => { state.deleteTarget = null; });
  el.lightbox.addEventListener('click', (e) => { if (e.target !== el.lightboxImg) el.lightbox.close(); });
  el.lightbox.addEventListener('close', () => el.lightboxImg.removeAttribute('src'));

  // Drag and drop an image onto the chat
  let dragDepth = 0;
  const hasFiles = (e) => [...(e.dataTransfer?.types ?? [])].includes('Files');
  el.feedWrap.addEventListener('dragenter', (e) => {
    if (!hasFiles(e) || state.legacy || el.input.disabled) return;
    e.preventDefault();
    dragDepth++;
    el.dropHint.hidden = false;
  });
  el.feedWrap.addEventListener('dragover', (e) => { if (hasFiles(e) && !el.dropHint.hidden) e.preventDefault(); });
  el.feedWrap.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; el.dropHint.hidden = true; } });
  el.feedWrap.addEventListener('drop', (e) => {
    if (el.dropHint.hidden) return;
    e.preventDefault();
    dragDepth = 0;
    el.dropHint.hidden = true;
    attachImage([...(e.dataTransfer?.files ?? [])].find((f) => f.type.startsWith('image/')));
  });

  // Emoji
  buildEmojiPanel();
  el.emojiToggle.addEventListener('click', () => setEmojiOpen(el.emojiPanel.hidden));
  document.addEventListener('click', (e) => {
    if (!el.emojiPanel.hidden && !e.target.closest('.emoji-wrap')) setEmojiOpen(false);
    if (!el.attachMenu.hidden && !e.target.closest('#attach-menu, #attach-toggle')) setAttachOpen(false);
    if (!el.reactionPicker.hidden && !e.target.closest('#reaction-picker, .msg-react')) closeReactionPicker();
    if (!el.moreMenu.hidden && !e.target.closest('#more-menu, .msg-more, #head-menu')) closeMoreMenu();
    if (!el.stickerPanel.hidden && !e.target.closest('#sticker-panel, #attach-sticker')) setStickerOpen(false);
  });
  window.addEventListener('resize', closeMoreMenu);
  window.addEventListener('resize', closeReactionPicker);

  // Search
  el.searchToggle.addEventListener('click', () => setSearchOpen(el.searchBar.hidden));
  el.searchClose.addEventListener('click', () => setSearchOpen(false));
  el.searchInput.addEventListener('input', () => {
    state.filter = el.searchInput.value.trim();
    applyFilter();
  });

  // Keyboard: "/" jumps to the message box, Escape closes popovers.
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (!el.reactionPicker.hidden) closeReactionPicker();
      else if (!el.moreMenu.hidden) closeMoreMenu();
      else if (!el.stickerPanel.hidden) { setStickerOpen(false); el.attachToggle.focus(); }
      else if (!el.emojiPanel.hidden) { setEmojiOpen(false); el.emojiToggle.focus(); }
      else if (!el.attachMenu.hidden) { setAttachOpen(false); el.attachToggle.focus(); }
      else if (document.querySelector('dialog[open]')) return;
      else if (state.editing && document.activeElement === el.input) cancelEdit();
      else if (state.replyTo && document.activeElement === el.input) cancelReply();
      else if (!el.searchBar.hidden) setSearchOpen(false);
      return;
    }
    const typingInField = e.target.closest?.('input, textarea, [contenteditable="true"]');
    if (e.key === '/' && !typingInField && !e.ctrlKey && !e.metaKey && !e.altKey && !el.input.disabled) {
      e.preventDefault();
      el.input.focus();
    }
  });

  // Scrolling
  el.feed.addEventListener('scroll', () => {
    state.atBottom = isNearBottom();
    closeReactionPicker();
    closeMoreMenu();
    if (!el.jump.hidden && state.atBottom) { state.unseen = 0; el.jump.hidden = true; }
  }, { passive: true });
  el.jump.addEventListener('click', () => { scrollToBottom(); el.input.focus({ preventScroll: true }); });

  // Mobile keyboards resize the visual viewport; keep the latest message visible.
  if (window.visualViewport) {
    let wasNear = true;
    visualViewport.addEventListener('resize', () => {
      document.documentElement.style.setProperty('--app-height', `${visualViewport.height}px`);
      window.scrollTo(0, 0);
      if (wasNear) requestAnimationFrame(() => { el.feed.scrollTop = el.feed.scrollHeight; });
    });
    el.feed.addEventListener('scroll', () => { wasNear = isNearBottom(); }, { passive: true });
  }

  // Network
  window.addEventListener('focus', clearUnread);
  window.addEventListener('offline', () => setConnection('offline'));
  window.addEventListener('online', () => {
    if (state.sb && state.session) { state.reconnectAttempts = 0; reconnectNow(); }
  });

  // Privacy notice (dismissal remembered for this tab only)
  if (!sessionStorage.getItem(NOTICE_KEY)) el.notice.hidden = false;
  el.dismissNotice.addEventListener('click', () => {
    el.notice.hidden = true;
    sessionStorage.setItem(NOTICE_KEY, '1');
  });

  // Dialogs
  document.querySelectorAll('[data-open-about]').forEach((b) =>
    b.addEventListener('click', () => el.aboutDialog.showModal()));
  document.querySelectorAll('[data-open-settings]').forEach((b) =>
    b.addEventListener('click', () => { fillSettingsForm(); el.settingsDialog.showModal(); }));
  document.querySelectorAll('[data-open-people]').forEach((b) =>
    b.addEventListener('click', () => el.peopleDialog.showModal()));
  el.settingsForm.addEventListener('change', onSettingsChange);
  document.querySelectorAll('[data-close-dialog]').forEach((b) =>
    b.addEventListener('click', () => b.closest('dialog').close()));
  for (const d of [el.aboutDialog, el.reportDialog, el.settingsDialog, el.peopleDialog, el.pollDialog, el.deleteDialog, el.renameDialog]) {
    // Click on the backdrop closes the dialog.
    d.addEventListener('click', (e) => { if (e.target === d) d.close(); });
  }
  el.reportForm.addEventListener('submit', submitReport);
  el.reportCancel.addEventListener('click', () => el.reportDialog.close());
  el.reportDetails.addEventListener('input', updateReportCounter);
  el.reportDialog.addEventListener('close', () => { state.reportTarget = null; });

  updateComposer();
}

boot();
