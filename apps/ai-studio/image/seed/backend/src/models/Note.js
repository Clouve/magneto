import mongoose from 'mongoose';

const noteSchema = new mongoose.Schema(
  {
    text: { type: String, required: true, trim: true, maxlength: 500 },
  },
  { timestamps: true },
);

export const Note = mongoose.model('Note', noteSchema);
