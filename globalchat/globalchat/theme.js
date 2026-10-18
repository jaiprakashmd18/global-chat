// =============================================================================
// GlobalChat — theme.js
//
// Loaded as a classic (blocking) script in <head> so the saved theme, accent
// and density are applied before first paint — no flash of the wrong theme.
// A separate file rather than an inline script because the CSP forbids
// inline scripts. app.js uses window.GlobalChatPrefs to read and change them.
// =============================================================================
(function () {
  var KEY = 'globalchat.prefs';
  var DEFAULTS = {
    theme: 'system', accent: 'violet', density: 'comfortable',
    sound: false, notify: false, soundAll: false, country: '', muted: [],
    gender: '', genderAsked: false,
  };
  var THEMES = ['system', 'light', 'dark', 'amoled', 'contrast', 'neon'];
  // Variants are dark themes with their own tweaks.
  var VARIANTS = { amoled: 'dark', contrast: 'dark', neon: 'dark' };
  var ACCENTS = ['violet', 'ocean', 'sunset', 'mint', 'rose'];
  var THEME_COLORS = { dark: '#0A0B12', light: '#F4F5FA', amoled: '#000000', contrast: '#000000', neon: '#07040F' };
  var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: light)') : null;
  var memo = null; // fallback when localStorage is unavailable (private mode)

  function load() {
    var prefs = {};
    try { prefs = JSON.parse(localStorage.getItem(KEY) || 'null') || memo || {}; } catch (e) { prefs = memo || {}; }
    var out = {};
    for (var k in DEFAULTS) out[k] = k in prefs ? prefs[k] : DEFAULTS[k];
    if (THEMES.indexOf(out.theme) < 0) out.theme = DEFAULTS.theme;
    if (ACCENTS.indexOf(out.accent) < 0) out.accent = DEFAULTS.accent;
    if (['comfortable', 'compact'].indexOf(out.density) < 0) out.density = DEFAULTS.density;
    out.sound = Boolean(out.sound);
    out.notify = Boolean(out.notify);
    out.soundAll = Boolean(out.soundAll);
    out.country = /^[A-Z]{2}$/.test(out.country) ? out.country : '';
    out.gender = ['male', 'female', 'nonbinary'].indexOf(out.gender) >= 0 ? out.gender : '';
    out.genderAsked = Boolean(out.genderAsked);
    out.muted = Array.isArray(out.muted)
      ? out.muted.filter(function (n) { return /^[A-Za-z]{2,20}_[0-9]{4}$/.test(n); }).slice(0, 200)
      : [];
    return out;
  }

  function resolveTheme(theme) {
    if (theme === 'light' || theme === 'dark') return theme;
    if (VARIANTS[theme]) return VARIANTS[theme];
    return media && media.matches ? 'light' : 'dark';
  }

  function apply(prefs) {
    var root = document.documentElement;
    var resolved = resolveTheme(prefs.theme);
    root.dataset.theme = resolved;
    if (VARIANTS[prefs.theme]) root.dataset.variant = prefs.theme;
    else delete root.dataset.variant;
    root.dataset.accent = prefs.accent;
    root.dataset.density = prefs.density;
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', THEME_COLORS[VARIANTS[prefs.theme] ? prefs.theme : resolved]);
  }

  function save(prefs) {
    memo = prefs;
    try { localStorage.setItem(KEY, JSON.stringify(prefs)); } catch (e) { /* private mode: keep in memory */ }
    apply(prefs);
  }

  apply(load());

  // Follow the OS setting live while the theme is "system".
  if (media && media.addEventListener) {
    media.addEventListener('change', function () { if (load().theme === 'system') apply(load()); });
  }

  window.GlobalChatPrefs = { load: load, save: save, apply: apply, accents: ACCENTS };
})();
