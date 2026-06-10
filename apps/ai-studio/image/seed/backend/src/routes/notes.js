import { Router } from 'express';
import { Note } from '../models/Note.js';

// Express 5 forwards rejected async handlers to the error middleware, so no
// per-route try/catch is needed here.
const router = Router();

router.get('/', async (_req, res) => {
  const notes = await Note.find().sort({ createdAt: -1 }).limit(100);
  res.json(notes);
});

router.post('/', async (req, res) => {
  const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
  if (!text) {
    return res.status(400).json({ error: 'text is required' });
  }
  const note = await Note.create({ text });
  res.status(201).json(note);
});

router.delete('/:id', async (req, res) => {
  const deleted = await Note.findByIdAndDelete(req.params.id);
  if (!deleted) {
    return res.status(404).json({ error: 'not found' });
  }
  res.status(204).end();
});

export default router;
