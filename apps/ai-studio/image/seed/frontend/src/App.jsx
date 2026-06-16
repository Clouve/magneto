import { useEffect, useState } from 'react';

// Same asset + link target as the Magneto Agent chat header, so the two UIs
// read as one product. If the CDN is unreachable (offline local dev), the
// alt text renders in its place.
const CLOUVE_LOGO = 'https://cdn.clouve.com/assets/LogoClouve2026.svg';

const CAPABILITIES = [
  {
    icon: '⚡',
    title: 'Live dev loop',
    text: 'Vite hot-module reload and node --watch: every edit to this project shows up here in seconds — no rebuilds, no redeploys.',
  },
  {
    icon: '🤖',
    title: 'Agent-driven coding',
    text: 'Describe what you want in the AI Studio chat. The agent writes the code on this workspace, runs it, and verifies it before reporting back.',
  },
  {
    icon: '🌐',
    title: 'A URL for any port',
    text: 'Start a server on any port and it is instantly reachable in your browser — behind your workspace login, no setup.',
  },
  {
    icon: '🗄️',
    title: 'MongoDB built in',
    text: 'MongoDB 7 runs locally with mongo-express for browsing your data — persistence is ready from the first request.',
  },
  {
    icon: '💾',
    title: 'A workspace that persists',
    text: 'Your code, installed packages, and database survive restarts. Pick up tomorrow exactly where you left off.',
  },
  {
    icon: '🔁',
    title: 'Self-healing stack',
    text: 'Every service is supervised and restarts automatically — the whole stack comes back on its own after a crash or reboot.',
  },
];

const STEPS = [
  { title: 'Open your AI Studio chat', text: 'The agent in your chat tab operates this workspace for you.' },
  { title: 'Ask for a change', text: '“Add a tasks API”, “turn this into a blog”, “add user login” — plain language is the spec.' },
  { title: 'Watch it appear here', text: 'The agent edits this very app; hot reload shows the result live on this page.' },
  { title: 'Keep building', text: 'Everything persists across restarts — iterate for as long as the project takes.' },
];

function StatusPill({ label, ok }) {
  const state = ok === null ? 'pending' : ok ? 'up' : 'down';
  return (
    <span className={`status-pill status-${state}`}>
      <span className="status-dot" aria-hidden="true" />
      {label}
    </span>
  );
}

function Header({ health }) {
  return (
    <header className="site-header">
      <div className="header-left">
        <a href="https://www.clouve.com" target="_blank" rel="noopener noreferrer">
          <img alt="Clouve" src={CLOUVE_LOGO} />
        </a>
        <span className="header-badge">AI Studio</span>
      </div>
      <div className="header-right">
        <StatusPill label="API" ok={health === null ? null : health.ok} />
        <StatusPill label="Mongo" ok={health === null ? null : health.mongo} />
      </div>
    </header>
  );
}

function Hero() {
  return (
    <section className="hero">
      <h1>Your AI-powered development workspace</h1>
      <p>
        A full MERN stack — MongoDB, Express, React, Node — already scaffolded,
        installed, and running. Ask the agent in your chat for a change and
        watch it appear here, live.
      </p>
      <div className="hero-actions">
        <a className="btn btn-primary" href="#demo">See it work ↓</a>
        <a className="btn btn-ghost" href="#how">How it works</a>
      </div>
    </section>
  );
}

function Capabilities() {
  return (
    <section className="section">
      <h2>What your workspace can do</h2>
      <div className="cards">
        {CAPABILITIES.map((c) => (
          <article className="card" key={c.title}>
            <span className="card-icon" aria-hidden="true">{c.icon}</span>
            <h3>{c.title}</h3>
            <p>{c.text}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

function HowTo() {
  return (
    <section className="section section-tinted" id="how">
      <h2>How to use it</h2>
      <ol className="steps">
        {STEPS.map((s, i) => (
          <li key={s.title}>
            <span className="step-num" aria-hidden="true">{i + 1}</span>
            <div>
              <h3>{s.title}</h3>
              <p>{s.text}</p>
            </div>
          </li>
        ))}
      </ol>
    </section>
  );
}

function NotesDemo() {
  const [notes, setNotes] = useState(null);
  const [text, setText] = useState('');
  const [error, setError] = useState(null);

  async function loadNotes() {
    try {
      const res = await fetch('/api/v1/notes');
      if (!res.ok) throw new Error(`API responded ${res.status}`);
      setNotes(await res.json());
      setError(null);
    } catch (err) {
      setError(err.message);
    }
  }

  useEffect(() => {
    loadNotes();
  }, []);

  async function addNote(event) {
    event.preventDefault();
    const trimmed = text.trim();
    if (!trimmed) return;
    const res = await fetch('/api/v1/notes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: trimmed }),
    });
    if (res.ok) {
      setText('');
      loadNotes();
    } else {
      setError(`API responded ${res.status}`);
    }
  }

  async function deleteNote(id) {
    try {
      const res = await fetch(`/api/v1/notes/${id}`, { method: 'DELETE' });
      if (!res.ok) throw new Error(`API responded ${res.status}`);
      loadNotes();
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <section className="section" id="demo">
      <h2>Live demo — this widget runs through the real stack</h2>
      <p className="stack-flow" aria-label="Request path">
        <code>React</code> ─▶ <code>Express :4000</code> ─▶ <code>MongoDB</code>
      </p>

      <div className="demo-card">
        <form className="composer" onSubmit={addNote}>
          <input
            value={text}
            onChange={(event) => setText(event.target.value)}
            placeholder="Write a note…"
            maxLength={500}
          />
          <button type="submit" className="btn btn-primary" disabled={!text.trim()}>
            Add note
          </button>
        </form>

        {error && <p className="error">Couldn&apos;t reach the API: {error}</p>}
        {notes === null && !error && <p className="empty">Loading notes…</p>}
        {notes !== null && notes.length === 0 && (
          <p className="empty">No notes yet — add the first one above.</p>
        )}

        <ul className="notes">
          {(notes ?? []).map((note) => (
            <li key={note._id}>
              <span>{note.text}</span>
              <button
                type="button"
                className="delete"
                onClick={() => deleteNote(note._id)}
                aria-label="Delete note"
              >
                ×
              </button>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="site-footer">
      <div className="footer-grid">
        <table className="ports">
          <caption>What&apos;s running</caption>
          <tbody>
            <tr><th>Frontend</th><td>:5173</td><td>Vite + React, hot reload</td></tr>
            <tr><th>API</th><td>:4000</td><td>Express 5, watch mode</td></tr>
            <tr><th>DB browser</th><td>:8081</td><td>mongo-express</td></tr>
            <tr><th>MongoDB</th><td>:27017</td><td>loopback only — browse via mongo-express, or tunnel in for native clients</td></tr>
          </tbody>
        </table>
        <p className="footer-note">
          This page is the seed project itself — see <code>README.md</code> and{' '}
          <code>NOTES.md</code> in the project root for how it is wired, then
          make it yours.
        </p>
      </div>
      <p className="footer-copy">
        © {new Date().getFullYear()}{' '}
        <a href="https://www.clouve.com" target="_blank" rel="noopener noreferrer">Clouve</a>
        {' '}— your workspace, your data.
      </p>
    </footer>
  );
}

export default function App() {
  // null = first check still in flight; afterwards always an {ok, mongo} shape.
  const [health, setHealth] = useState(null);

  useEffect(() => {
    let cancelled = false;
    async function check() {
      try {
        const res = await fetch('/api/v1/health');
        const body = res.ok ? await res.json() : null;
        if (!cancelled) setHealth(body ?? { ok: false, mongo: false });
      } catch {
        if (!cancelled) setHealth({ ok: false, mongo: false });
      }
    }
    check();
    const timer = setInterval(check, 10000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, []);

  return (
    <>
      <Header health={health} />
      <main>
        <Hero />
        <Capabilities />
        <HowTo />
        <NotesDemo />
      </main>
      <Footer />
    </>
  );
}
