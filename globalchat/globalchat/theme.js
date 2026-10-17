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
  var DEFAULTS = { theme: 'system', accent: 'violet', density: 'comfortable', sound: false, notify: false };
  var ACCENTS = ['violet', 'ocean', 'sunset', 'mint', 'rose'];
  var THEME_COLORS = { dark: '#0A0B12', light: '#F4F5FA' };
  var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: light)') : null;
  var memo = null; // fallback when localStorage is unavailable (private mode)

  function load() {
    var prefs = {};
    try { prefs = JSON.parse(localStorage.getItem(KEY) || 'null') || memo || {}; } catch (e) { prefs = memo || {}; }
    var out = {};
    for (var k in DEFAULTS) out[k] = k in prefs ? prefs[k] : DEFAULTS[k];
    if (['system', 'light', 'dark'].indexOf(out.theme) < 0) out.theme = DEFAULTS.theme;
    if (ACCENTS.indexOf(out.accent) < 0) out.accent = DEFAULTS.accent;
    if (['comfortable', 'compact'].indexOf(out.density) < 0) out.density = DEFAULTS.density;
    out.sound = Boolean(out.sound);
    out.notify = Boolean(out.notify);
    return out;
  }

  function resolveTheme(theme) {
    if (theme === 'light' || theme === 'dark') return theme;
    return media && media.matches ? 'light' : 'dark';
  }

  function apply(prefs) {
    var root = document.documentElement;
    var resolved = resolveTheme(prefs.theme);
    root.dataset.theme = resolved;
    root.dataset.accent = prefs.accent;
    root.dataset.density = prefs.density;
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', THEME_COLORS[resolved]);
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
