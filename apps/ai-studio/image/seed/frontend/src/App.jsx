import { useEffect, useState } from 'react';

export default function App() {
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
    <main className="app">
      <h1>MERN Starter</h1>
      <p className="tagline">
        React + Vite, Express, and MongoDB — already running on this
        workspace. The notes below live in the <code>notes</code> collection
        and travel through <code>/api/v1/notes</code>.
      </p>

      <form className="composer" onSubmit={addNote}>
        <input
          value={text}
          onChange={(event) => setText(event.target.value)}
          placeholder="Write a note…"
          maxLength={500}
        />
        <button type="submit" disabled={!text.trim()}>
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
    </main>
  );
}
