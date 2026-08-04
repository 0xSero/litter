Summary

- Improved Local Studio cold-start discovery so Pi, Codex, and other enabled agents appear before selection.
- Renamed sessions now prefer their explicit title over first-message preview text.
- Restored Photos attachments no longer reopen transient Photos-library paths.
- Kept generic KittyLitter pairing immediate while Local Studio uses a bounded registration wait.

What to test

- Local Studio cold start: paste a connection JSON immediately after the controller starts and confirm Pi and Codex appear before Connect is enabled.
- Agent selection: confirm every available Local Studio agent can be selected, connected, and used for a streamed turn.
- KittyLitter: pair with a generic KittyLitter host and confirm the scanner remains responsive without the Local Studio wait.
- Session names: rename a session, reopen the session list, and confirm the explicit title wins over preview text.
- Photos: attach a Photos image, reopen the conversation, and confirm the rendered attachment does not resolve an internal `.photoslibrary` path.
- Core chat: verify reasoning, tool calling, streaming text, images, reconnect, and thread resume on both Codex and Pi sessions.
