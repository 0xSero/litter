Summary

- Reconnecting after launch or returning to the app no longer waits on the slowest computer's account check.
- Kittylitter tokens are cached in memory instead of being read from the Keychain on every reconnect.
- Conversations sit in a centered reading column on wide screens.
- Pairing uses Kittylitter 0.3.11 (faster session loading).
- Removed the "add a remote computer" hint on the empty home screen.

What to test

- Background the app for a minute, return, and send a prompt: your computer should reconnect quickly.
- Open a conversation on iPad or Mac: text should sit in a centered column.
