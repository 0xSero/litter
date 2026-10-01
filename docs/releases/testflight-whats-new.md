Summary

- Typing no longer freezes after a reply: each keystroke used to redraw the whole conversation.
- Full history for Claude Code, Pi and other harnesses (it was cut to the newest few turns).
- Session titles no longer show raw Claude Code markup.
- New model picker: choose a harness, then a model grouped by provider; search across everything; modes kept separate.
- Conversations stay in a centered column; code and tables scroll inside their own box.
- Simpler Settings in three groups.
- Faster reconnects; pairing uses Kittylitter 0.3.11.

What to test

- Open a Claude Code session and scroll up: older turns should load.
- Send a message, wait for the reply, then type a long follow-up: it should keep up.
- Open the model picker and search for a model.
