# Shared Scripts

Repository-wide build, release, runtime, feedback, and desktop-automation
helpers live here. The root Makefile is the supported build entry point;
invoke individual scripts when debugging their lane.

- `build-android-rust.sh`: builds Android Rust bridge JNI libs into `apps/android/core/bridge/src/main/jniLibs`.
- `codex-app-driver.applescript`: launches `Codex.app`, opens a project root, creates a thread, and pastes/sends prompts through GUI scripting for desktop-side conversation automation.
- `codex-desktop-controller.mjs`: launches or attaches to a remote-debugging-enabled `Codex.app` instance, then drives the real renderer UI through CDP so it can open projects, create threads, send prompts, wait for the turn to finish, and dump the visible transcript as JSON without macOS accessibility scripting.
- `deploy-android-ondevice.sh`: builds Rust JNI libs, assembles the debug APK, installs on a target device (`--serial`/`ANDROID_SERIAL`), and launches the app.
- `pi-mission.sh`: launches, resumes, and inspects one persistent `homelab/glm-5.2` Pi mission for each task in the chat-performance workpack. Mission event logs and review turns stay local under the ignored `.pi-missions/` directory; Pi never pushes or merges.
- `switch-app-identity.sh`: switches local app IDs between `com.sigkitten.litter` and `com.<your-identifier>.litter` for Android+iOS (`--to your-identifier --identifier <name>`), with optional `--team-id` for iOS signing. For iOS it updates `apps/ios/project.yml` and regenerates `apps/ios/Litter.xcodeproj` via `xcodegen` (no direct `.xcodeproj` edits).
- `triage-mobile-feedback.py`: rerunnable triage ledger for GitHub issues/PRs, TestFlight feedback/crashes, and Google Play reviews/crash issues. It stores raw per-run snapshots, a durable local state file, and a generated board under `artifacts/mobile-triage/`.

Mobile triage flow:

```bash
# Fetch GitHub issues/PRs + TestFlight + Play data for the last day and update the local board.
./tools/scripts/triage-mobile-feedback.py --last-hours 24

# Inspect active items without fetching again.
./tools/scripts/triage-mobile-feedback.py list --status active

# Mark work as handled so repeated fetches do not put it back in the active queue.
./tools/scripts/triage-mobile-feedback.py mark '<item-id>' --status done --note 'Fixed in <commit-or-version>'
./tools/scripts/triage-mobile-feedback.py mark '<item-id>' --status pr-open --note 'Fix PR #123'
```

The generated board is `artifacts/mobile-triage/triage-board.md`; the source of truth is `artifacts/mobile-triage/triage-state.json`.

Common `codex-desktop-controller.mjs` flows:

```bash
# Launch a separate Codex instance with Electron remote debugging enabled.
node tools/scripts/codex-desktop-controller.mjs launch \
  --app "/Applications/Codex copy.app" \
  --port 9333 \
  --user-data-dir /tmp/codex-desktop-controller-profile

# Reuse that same instance on later commands. Add --fresh-launch only if you
# intentionally want a brand new app instance on the same port/profile setup.
node tools/scripts/codex-desktop-controller.mjs thread-state --port 9333 --launch

# Attach to an already-running automation instance and inspect the active thread.
node tools/scripts/codex-desktop-controller.mjs thread-state --port 9333

# Send one turn into the current thread, wait for the assistant to finish, and print JSON.
node tools/scripts/codex-desktop-controller.mjs run-turn \
  --port 9333 \
  --message 'Reply with exactly: OK'

# Start a fresh thread in a sidebar project, run the first turn, and print the final transcript.
node tools/scripts/codex-desktop-controller.mjs run-turn \
  --port 9333 \
  --project codex-test \
  --message 'Reply with exactly: OK'
```
