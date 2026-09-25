Summary

- iOS renders the first home frame without waiting for launch connection work, avoiding the black launch screen.
- iOS and Android show recent sessions from the shared Rust cache before saved servers finish reconnecting.
- Follow-up questions retain earlier messages, expansion choices, and the current turn on iOS and Android.
- Long conversations use individually keyed lazy rows to keep scrolling responsive.
- Shared connection workers handle unrelated actions while slow requests are pending and stop cleanly on disconnect.
- Response IDs are validated instead of treating invalid numeric values as zero.
- Large session collections preserve their position when opening a conversation, returning Home, and changing zoom.
- The Home animation retains the latest design with faster image preparation and a stable transition into its loop.
- Streaming refreshes preserve ordered text, and inactive conversation history has a bounded cache while active and offline work stays protected.
- Android screen recreation keeps the shared connection available; iOS Watch startup and app shutdown no longer compete for the main thread.

What to test

- Cold launch iOS and check that the home screen appears without a black wait while servers reconnect.
- Cold launch either platform with saved servers and recent sessions; check that recent sessions appear before reconnection completes and remain correct afterward.
- Send several follow-ups with collapse enabled and disabled; check that prior messages and expansion state remain intact.
- Scroll into older messages in a long turn, then send another follow-up. Check that the scroll position and history remain usable.
- Stream a long reply while loading models or settings; the reply and unrelated actions should continue without a pause.
- Disconnect and reconnect while a request is pending, then send a new turn.
- Check history after an interrupted turn and after reopening the conversation.
- With a large session collection, open a session far down the list, return with Back, and change zoom. Check position, taps, swipes, text scaling, and variable-height messages.
- Check the Home animation from its entrance into its loop, including after backgrounding and returning to the app.
- Repeatedly open older conversations, then revisit them. Verify drafts, running turns, and offline history remain intact while connected inactive history can reload.
- Rotate or recreate the Android screen during a connection, then make another request. Check Watch session updates on iOS after launch.

Connection notes

- Host adapter latency improvements remain a separate release candidate; they are not included in this mobile build.
- Confirm launch speed and cached sessions on a device with a real saved server before making a measured performance claim.
