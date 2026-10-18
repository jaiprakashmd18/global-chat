// =============================================================================
// GlobalChat — frontend configuration
//
// Replace the two placeholder values below with your own project's values from
// Supabase Dashboard → Project Settings → API (or "API Keys").
//
// These values are PUBLIC by design. Every visitor's browser downloads them.
// Security comes from Row Level Security and triggers in schema.sql, not from
// hiding this file.
//
// NEVER put the service_role key (or a "secret" key, sb_secret_...) here.
// =============================================================================

export const CONFIG = {
  // e.g. 'https://abcdefghijklmnop.supabase.co'
  SUPABASE_URL: 'https://kjtlzlvkvszpmfrhrqjh.supabase.co',

  // The anon public key (a long JWT starting with eyJ...) or the newer
  // publishable key (starts with sb_publishable_...).
  SUPABASE_ANON_KEY: 'sb_publishable_uOnk9L2K8S5l1l6k3-4ezg_0V9aHphj',

  // Optional, strongly recommended before public launch: Cloudflare Turnstile
  // site key. When set, visitors complete a Turnstile check before their
  // anonymous session is created, and Supabase verifies the token server-side
  // (requires Auth → Attack Protection → CAPTCHA to be enabled with the
  // matching secret key). Leave as '' to disable.
  TURNSTILE_SITE_KEY: '',

  // Optional: donations. Fill in either part and a "Support GlobalChat" 💜
  // button appears (sidebar, header, About). Leave both empty to hide it.
  DONATE: {
    // India: your UPI ID, e.g. 'yourname@okaxis'. People pay with GPay,
    // PhonePe, Paytm or any UPI app (QR code on computers, a button on phones).
    UPI_ID: '',
    UPI_NAME: 'GlobalChat',          // name shown in the UPI app

    // Anywhere: up to 4 https links, e.g.
    //   { label: 'Buy me a coffee', url: 'https://buymeacoffee.com/yourname' },
    //   { label: 'Ko-fi', url: 'https://ko-fi.com/yourname' },
    //   { label: 'PayPal', url: 'https://paypal.me/yourname' },
    LINKS: [],
  },
};
