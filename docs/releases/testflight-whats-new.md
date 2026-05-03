Summary

- Fixed the conversation composer hiding Send behind Cancel while a turn is active.
- Fixed remote project browsing for Pi/alleycat hosts that rejected directory-picker commands with sandbox wrapper arguments.
- Fixed Linux `kittylitter` autostart setup so the packaged systemd unit is enabled and `stop` only warns about OS restart when autostart is actually active.
- Added a keyboard escape hatch on the home composer project-required warning.
- Fixed a streaming render race that could make the first assistant-response character appear missing.
- Added Copy to the iOS user-message long-press menu.
- Updated pet sprite animation timing so idle pets breathe slower and action states play a short burst before returning to idle.
- Daemon now installs in one step: run `npx kittylitter` on your Mac/Linux box and it sets up autostart and prints the pair QR.

What to test

- Active-turn composer: start a conversation turn, type into the composer while the turn is still active, and confirm the outer action changes to Send instead of staying as Cancel. Clear the text and confirm Cancel returns.
- Remote project picker: connect to a Pi/alleycat host, open the new-project directory picker, and confirm folders load without a `--sandbox-policy` error.
- Linux daemon autostart: on Ubuntu, run `npx kittylitter cold`, then confirm `systemctl --user is-enabled kittylitter.service` is enabled and `systemctl --user status kittylitter.service` is running.
- Home composer keyboard: open the home composer with no project selected, type a prompt, tap Send, then tap the warning's close button and confirm the keyboard dismisses.
- Assistant streaming: start several new turns and confirm assistant messages begin with their full first word/character while streaming and after completion.
- Message actions: long-press a user message in the iOS conversation timeline. The menu should include Copy, Edit Message, and Fork From Here, and Copy should place the message text on the clipboard.
- Pet animation pacing: enable a pet and watch the idle loop. It should animate at a slower, less frantic pace. Trigger action states such as active turn, waiting, review/input-needed, failed, and dragging; each action should play briefly, then return to the idle loop.
- Daemon onboarding: on a fresh Mac with no kittylitter installed, run `npx kittylitter`. It should install the autostart entry, start the daemon, and print a pair QR you can scan from the iOS app to complete pairing in one go.
