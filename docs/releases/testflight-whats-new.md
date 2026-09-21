Summary

- Updated the embedded Codex runtime and native protocol support.
- Model catalogs refresh from each connected harness, including custom models and plugin modes. Failed refreshes keep the last successful catalog.
- Added searchable harness settings with native value types, source information, and save verification on iOS and Android.
- OMP has its own runtime identity and configuration, separate from Pi.
- Android logo and splash animations avoid recomposing their layout on every frame.
- Model and reasoning selections use each harness's advertised capabilities.

What to test

- Connect Kittylitter and open the model picker before starting a conversation. Check each enabled harness, custom model, plugin mode, and available reasoning effort.
- Change a model or reasoning effort, send a turn, and confirm the harness uses the selection.
- Open Settings → Harnesses, search for a setting, edit it, then reopen it and verify the saved value. Policy-controlled settings must remain read-only.
- Repeat through direct SSH for Claude, Pi, and OMP, verifying settings belong to the remote computer.
- Disconnect during a model refresh and reconnect. Confirm cached choices remain available and the refreshed catalog belongs to the new connection.
- Stream a conversation while searching models or settings; both screens should stay responsive.
- Confirm discovery, settings, and conversation actions do not open host terminal windows or foreground helper applications.

Connection notes

- Install the matching Kittylitter host release for the new native settings and catalog adapters.
- Settings take effect according to each harness's reload/session rules. Remote services without a configuration API expose read-only settings.
