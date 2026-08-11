# iOS Quickstart

## Prerequisites

- Xcode.app
- xcodegen (`brew install xcodegen`)
- Rust toolchain (`rustup`)
- Zig matching `shared/third_party/ghostty/build.zig.zon` (normally
  `brew install zig@0.15`)
- Optional: sccache (`brew install sccache`) for faster Rust rebuilds

## Build with Make (recommended)

```bash
# Full iOS build (device + simulator)
make ios

# Simulator development lane (faster; raw static library)
make ios-sim-fast

# Device development lane (faster; raw static library)
make ios-device-fast

# Build + open Xcode
make ios-run
```

The Makefile handles Codex/Ghostty submodule preparation, patches, UniFFI
bindings, Rust cross-compilation, Alpine local-runtime resources, project
generation, and Xcode builds. Stamp files make repeated runs incremental.

## Build manually (step by step)

1. Sync Codex submodule + apply iOS patch:

   - `./apps/ios/scripts/sync-codex.sh`
   - This preserves the current submodule checkout by default. Use
     `--recorded-gitlink` only to reset to the commit recorded in the parent
     repo.

2. Build the Rust bridge:

   - package lane: `./apps/ios/scripts/build-rust.sh`
   - simulator fast lane: `./apps/ios/scripts/build-rust.sh --fast-sim`
   - device fast lane: `./apps/ios/scripts/build-rust.sh --fast-device`

3. Generate project:

   - `./apps/ios/scripts/regenerate-project.sh`

4. Build app:

   ```bash
   xcodebuild \
     -project apps/ios/Litter.xcodeproj \
     -scheme Litter \
     -configuration Debug \
     -destination 'generic/platform=iOS Simulator' \
     build
   ```

## Configuration

Override via environment variables:

- `IOS_SIM_DEVICE="iPhone 17 Pro"` — change simulator target
- `XCODE_CONFIG=Release` — release build
