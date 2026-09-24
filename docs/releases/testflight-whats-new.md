Summary

- iOS renders the first home frame without waiting for launch connection work, avoiding the black launch screen.
- iOS and Android show recent sessions from the shared Rust cache before saved servers finish reconnecting.
- Follow-up questions retain earlier messages, expansion choices, and the current turn on iOS and Android.
- Long conversations use individually keyed lazy rows to keep scrolling responsive.
- Shared connection workers handle unrelated actions while slow requests are pending and stop cleanly on disconnect.
- Response IDs are validated instead of treating invalid numeric values as zero.

What to test

- Cold launch iOS and check that the home screen appears without a black wait while servers reconnect.
- Cold launch either platform with saved servers and recent sessions; check that recent sessions appear before reconnection completes and remain correct afterward.
- Send several follow-ups with collapse enabled and disabled; check that prior messages and expansion state remain intact.
- Scroll into older messages in a long turn, then send another follow-up. Check that the scroll position and history remain usable.
- Stream a long reply while loading models or settings; the reply and unrelated actions should continue without a pause.
- Disconnect and reconnect while a request is pending, then send a new turn.
- Check history after an interrupted turn and after reopening the conversation.

Connection notes

- Host adapter latency improvements remain a separate release candidate; they are not included in this mobile build.
- Confirm launch speed and cached sessions on a device with a real saved server before making a measured performance claim.
