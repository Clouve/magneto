import express from 'express';
import mongoose from 'mongoose';
import { Note } from './models/Note.js';
import notesRouter from './routes/notes.js';

const PORT = Number(process.env.PORT) || 4000;
const MONGO_URL = process.env.MONGO_URL || 'mongodb://127.0.0.1:27017/starter';

const app = express();
app.use(express.json());

// Liveness for healthchecks and deploy verification.
app.get('/api/v1/health', (_req, res) => {
  res.json({ ok: true, mongo: mongoose.connection.readyState === 1 });
});

app.use('/api/v1/notes', notesRouter);

// mongod may still be starting (or recovering its journal after an unclean
// stop) when we come up. Retry here instead of exiting: under `node --watch`
// the process manager only sees the watcher process, so exiting would leave
// the API dead while the supervisor still reports the program RUNNING.
for (;;) {
  try {
    await mongoose.connect(MONGO_URL, { serverSelectionTimeoutMS: 5000 });
    break;
  } catch (err) {
    console.error(`[backend] MongoDB not ready (${err.message}) — retrying in 3s`);
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
}

// Seed sample data only if the notes collection has never existed, so the
// page proves the Mongo round-trip on first boot — but a collection the user
// later emptied on purpose stays empty.
const notesCollectionExists =
  (await mongoose.connection.db.listCollections({ name: 'notes' }).toArray()).length > 0;
if (!notesCollectionExists) {
  await Note.insertMany([
    { text: 'This note was read from MongoDB through the Express API.' },
    { text: 'Add a note below — it round-trips browser → Vite → Express → MongoDB.' },
  ]);
}

// 0.0.0.0: clv-proxy reaches this pod from outside; a loopback-only server
// would be unreachable through it.
app.listen(PORT, '0.0.0.0', () => {
  console.log(`[backend] listening on 0.0.0.0:${PORT} — mongo: ${MONGO_URL}`);
});
