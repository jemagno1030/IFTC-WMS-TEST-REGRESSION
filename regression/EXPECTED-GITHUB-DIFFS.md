# Expected GitHub differences between WMS LIVE and TEST

These differences must NOT be reported as failures:

1. `config.js`
   - LIVE must point to Supabase project `sqpxgwhhfxojzblitnni`.
   - TEST must point to Supabase project `gfswztynzocobxbtaitc`.
   - TEST currently has `ALLOW_SIGNUP: false`.

2. `styles.css`
   - TEST contains the permanent warning banner:
     `⚠ TEST / REGRESSION ENVIRONMENT — NOT LIVE WAREHOUSE`
   - LIVE does not contain this marker.

Normal parity targets unless an enhancement is intentionally under TEST:
- `app.js`
- `index.html`
- `config.example.js`
- `icon.svg`
- `manifest.webmanifest`

When an enhancement is under TEST, the regression controller should explicitly record the expected changed file(s) and should not silently treat arbitrary drift as acceptable.
