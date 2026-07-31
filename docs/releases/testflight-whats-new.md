Summary

- Pair with Local Studio and use its Pi agents from mobile.
- Resume controller-scoped sessions after reconnecting or restarting.
- Smoother interleaved reasoning, text, and tool-call streaming.
- Create files from mobile tools and see the same sessions in Litter and Local Studio.
- Improved Codex and Local Studio hydration, compaction, and reconnect stability.
- Added a Local Studio website link under Settings > Local AI.

What to test

- Codex: connect to a Codex server, open an existing thread, send a prompt, and confirm streaming completes.
- Local Studio: discover or pair with a Local Studio controller, select a Pi agent and model, send a prompt, and confirm the response streams.
- Tools: run a tool that creates a file and confirm reasoning, content, tool status, and the file appear in order.
- Session sync: open the same session in Litter and Local Studio, then confirm messages created on either side appear on the other.
- Compaction: continue a long session through compaction and confirm the next turn streams normally.
- Reconnect: background and reopen the app, then confirm the selected controller and session resume without duplicating messages.
- Settings: open Settings > Local AI > Local Studio and confirm localstudio.ai opens.
