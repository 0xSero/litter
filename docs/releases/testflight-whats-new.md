Summary

- Restored Local Studio command, tool-call, and tool-result lifecycle events from legacy controllers.
- Made command and tool activity permanently visible, including for users with an older hidden preference.
- Closed the turn-start race that could lose, duplicate, or misorder a rapid second message.
- Preserved exact queued-turn model, mode, effort, and permission settings.
- Kept session identity, item ordering, and tool output stable across reconnect and hydration.
- Batched streaming deltas at display cadence to reduce native UI churn while preserving exact text.

What to test

- Pair with a Local Studio controller, run a shell command, and confirm the command card and completed output appear live.
- Send a second message immediately after the first tool-producing turn; confirm it appears immediately, runs once, and receives one response.
- Background and foreground during streaming, then reconnect; confirm no user, assistant, command, or tool rows replay or disappear.
- Reopen the same session from Litter and Local Studio and confirm the exact thread identity, order, and output match.
- Compare long streaming replies with 1.7.0 and confirm scrolling and token rendering remain smooth and responsive.
- Confirm Pi and Local Studio Pi continue to use no approvals with full workspace access.
- Verify the same session, tool, and streaming behavior on iOS and Android.
