<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<meta name="robots" content="noindex">
<meta name="referrer" content="no-referrer">
<title>AI Studio</title>
<style>
  :root {
    --paper: #f5f6fa;
    --ink: #22262d;
    --muted: #59606c;
    --rule: #dde1e8;
    --blue: #1c71e6;
    --blue-hover: #1660c4;
    --on-blue: #ffffff;
    color-scheme: light dark;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --paper: #15181d;
      --ink: #e9ebef;
      --muted: #a4abb6;
      --rule: #2d333c;
      --blue: #5c9cf0;
      --blue-hover: #84b5f5;
      --on-blue: #0c1015;
    }
  }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0;
    min-height: 100vh;
    background: var(--paper);
    color: var(--ink);
    font: 400 1rem/1.6 "Poppins", system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  }
  main {
    max-width: 34rem;
    margin: 0 auto;
    padding: 16vh 16px 3rem;
  }
  h1 {
    margin: 0 0 1rem;
    font-size: clamp(1.5rem, 1.2rem + 1.5vw, 2rem);
    line-height: 1.2;
    font-weight: 600;
    letter-spacing: -0.015em;
  }
  p { margin: 0 0 1rem; color: var(--muted); }
  .open {
    display: inline-block;
    margin: 0.75rem 0 0.5rem;
    padding: 0.7rem 1.25rem;
    border-radius: 0.375rem;
    background: var(--blue);
    color: var(--on-blue);
    font-weight: 500;
    text-decoration: none;
  }
  .open:hover { background: var(--blue-hover); }
  .open:focus-visible { outline: 3px solid var(--blue); outline-offset: 3px; }
  .address { margin-bottom: 2.5rem; font-size: 0.875rem; overflow-wrap: anywhere; }
  .help { padding-top: 1.25rem; border-top: 1px solid var(--rule); font-size: 0.9375rem; }
</style>
</head>
<body>
<main>
  <h1>Open the AI Assistant to work on this app</h1>
  <p>This is the address of an AI Studio workspace. You build the app by chatting with the AI Assistant, and it gives you preview links that open once you sign in.</p>
<!-- link -->
  <a class="open" href="@AI_URL@">Open the AI Assistant</a>
  <p class="address">@AI_HOST@</p>
  <p class="help">If it doesn't open, go to this deployment's page in Clouve, where the AI Assistant's address is listed. If the AI Assistant is off, turn it on there.</p>
<!-- /link -->
<!-- no-link -->
  <p class="help">Go to this deployment's page in Clouve, where the AI Assistant's address is listed. If the AI Assistant is off, turn it on there.</p>
<!-- /no-link -->
</main>
</body>
</html>
