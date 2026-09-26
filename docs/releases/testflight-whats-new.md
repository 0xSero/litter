Summary

- iOS and Android follow the Litter Quiet design: text-only lists, one mono metadata line, no accent color, and no idle animations.
- The composer is one raised card with attachments, the model pill, voice, and send or stop.
- Reasoning and tool steps fold into one summary line per turn; they stay open while the turn runs and collapse after.
- Launch renders its final layout once, shows saved servers as connecting, and remembers the last project and model.
- The sessions list is one plain grouped list with shared virtualization rules (62 pt rows, 10-row prefetch, 4 concurrent loads, 50-row pages).
- Reconnects skip repeated SSH detection, the folder and model pickers reuse cached results, and going back from a conversation no longer rebuilds Home.
- Store snapshots share item payloads and thread-list pages sync in one update.

What to test

- Cold launch with saved servers and recent sessions; the layout should not jump, and servers should show "connecting…" until they are live.
- Start a new session; the last project and model should be preselected.
- Run a turn with reasoning and tool calls; the work section should be open while running, fold when done, and reopen on tap.
- Go back from a long conversation, open the folder picker twice, and open the model picker twice; each should respond immediately.
- Scroll the sessions list with many sessions and load older pages.
- Reconnect a saved SSH server after restarting the app.
- Check light and dark mode, large Dynamic Type, and the first-run hints on a small iPhone.

Connection notes

- Confirm launch, reconnect and back-navigation speed on a device with real saved servers before making a measured performance claim.
