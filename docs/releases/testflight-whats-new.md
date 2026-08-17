Summary

- Fixed the render stalls that made the app unusable after a Local Studio connect pulled sessions in.
- Cut the per-update work at the Rust store boundary: the per-thread accessor no longer deep-clones the whole app state, and item lookups are constant-time instead of scanning every token.
- Composer typing now costs one view update per keystroke instead of three.
- Model picker no longer makes hundreds of uncached FFI calls per keystroke.
- Transcript no longer rebuilds preview text for the entire conversation on every streaming tick.
- Theme switching is perceptually instant.
- Claude Code and opencode are selectable over the SSH bridge; agent labels and icons now appear on every connection path, not only after an Alleycat probe.
- Composer accepts up to four images per message.
- Assistant message text can be selected and copied.
- Conversations load 20 turns per page instead of 5.
- Conversation back button works again; the new-thread screen has a back control.
- Android: session rows open from anywhere on the row; timestamps no longer wrap one character per line.
- Removed ~5,500 lines of unreachable code, including a DEBUG-only proximity-pairing subsystem that shipped in every release build.

What to test

- Connect Local Studio and let sessions load. The home list, project picker, model picker, and composer should all stay responsive while a thread streams in the background.
- Type into the composer during an active turn — on the home screen and inside a conversation.
- Open the model picker and type in its search field; open the project picker and select a project.
- Send several messages across multiple turns in one conversation and confirm it does not get progressively slower.
- Attach multiple images to one message, remove one before sending, and confirm every remaining image arrives.
- Long-press assistant text and confirm Copy and Select Text work.
- Switch themes and confirm it is immediate and that message text repaints in the new theme.
- Confirm Claude Code and opencode appear and connect; confirm agent names and icons render right after connecting.
- Approve a command mid-turn and confirm the approval prompt still appears promptly.
- Start and stop realtime voice, and open a terminal session, to confirm state still updates correctly.
- Scroll back through a long conversation and confirm older turns load.

Known gaps

- Android was not exercised on-device for this build; only CI verified it.
- Droid, Devin, Amp, Hermes, Grok and Shell are registered but reachable only through Alleycat pairing, not the SSH bridge.
