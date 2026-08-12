Summary

- Preserved Local Studio session identity across listing, streaming, hydration, and reconnect.
- Routed new Local Studio conversations through its built-in Pi runtime from the first request.
- Kept newly synchronized Local Studio sessions visible alongside legacy pinned sessions.
- Removed false OpenAI sign-in warnings from Local Studio connections.
- Enforced full filesystem access with no approval prompts for Pi and Local Studio Pi sessions.

What to test

- Upgrade from 1.6 or 1.7 with existing Local Studio pins and confirm current sessions remain visible and every Local Studio row keeps its label.
- Start a Local Studio conversation from mobile, stream the reply, use shell and file tools, then reopen it in both Litter and Local Studio.
- Background and foreground the app during and after a turn; confirm the session and completed content survive reconnect and resume.
- Confirm Local Studio shows connected without an OpenAI sign-in warning.
- Confirm Pi and Local Studio Pi never request approval and can read and write the selected workspace.
- Confirm ordinary Codex, Pi, and generic Kittylitter connections retain their explicit pairing, URL, and SSH behavior.
- Verify reasoning, tool calls, streaming text, images, compaction, and older-turn hydration on iOS and Android.
