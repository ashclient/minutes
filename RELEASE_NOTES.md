Minutes 2.9.0 adds a meeting chat sidebar.

- Click Ask while recording or reviewing a meeting to ask about something you missed.
- Answers use timestamped transcript excerpts and your personal notes, using the AI provider selected in Settings. Long recordings use bounded retrieval of relevant passages and recent speech; responses cannot recover audio that was never transcribed.
- Stream replies, stop a response while keeping its partial text, and return to the same chat after switching meetings. Chat history is saved on your Mac and included in JSON backups; it stays out of Notion sync and note exports unless you click Add to my notes.
- Recording continues while you ask. Apple chat waits until any existing notes-generation job finishes before accepting a question, to avoid starting extra work on your Mac.
- Updater installation waits for a chat reply to finish. Closing Minutes saves the visible partial reply without waiting for AI.

Cloud chat sends selected transcript passages, personal notes, your question and recent chat history to the chosen NVIDIA or OpenRouter provider. Apple chat stays on your Mac. Accuracy depends on the transcript; check important details against the recording.
