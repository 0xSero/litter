Summary

- Follow-up questions retain earlier messages, expansion choices, and the current turn on iOS and Android.
- Long conversations use individually keyed lazy rows to keep scrolling responsive.
- Shared connection workers handle unrelated actions while slow requests are pending and stop cleanly on disconnect.
- Response IDs are validated instead of treating invalid numeric values as zero.
- The existing streaming text render optimization remains included.

What to test

- Send several follow-ups with collapse enabled and disabled; check that prior messages and expansion state remain intact.
- Scroll into older messages in a long turn, then send another follow-up. Check that the scroll position and history remain usable.
- Stream a long reply while loading models or settings; the reply and unrelated actions should continue without a pause.
- Disconnect and reconnect while a request is pending, then send a new turn.
- Check history after an interrupted turn and after reopening the conversation.

Connection notes

- Host adapter latency improvements remain a separate release candidate; they are not included in this mobile build.
- Local timeline fixtures and Rust regressions passed. Test this packaged build with a real connected server before interpreting the fixture timings as device performance.
