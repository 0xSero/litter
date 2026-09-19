# kittylitter

Distribution wrapper for the [alleycat](https://github.com/makyinmars/alleycat) daemon. Ships the daemon to npm, Homebrew, and the platform installer scripts under the kittylitter brand.

The wrapper itself is a 3-line `main()` that re-exports `alleycat::run("kittylitter")`. All daemon behavior lives in the alleycat crate; this crate exists so cargo-dist sees a `kittylitter` package name and produces correctly-named artifacts (`kittylitter-installer.sh`, `kittylitter.rb`, `kittylitter` on npm).

## Preparing a release

1. Publish the reviewed Alleycat commit to the dependency repository.
2. Pin this manifest and `shared/rust-bridge/Cargo.toml` to the same immutable
   revision and source. Update both Cargo lockfiles; `update-alleycat-main.sh`
   intentionally leaves revision-pinned dependencies unchanged.
3. Bump this package's version and its own Cargo lockfile entry when changing
   a previously released wrapper. Validate the wrapper and both mobile clients
   against the intended revision.
4. Review the PR before merging. A push to `main` that changes this manifest
   triggers `auto-release.yml`, which dispatches the release workflow for an
   unpublished version. Preparing these changes on an unmerged PR does not
   publish a release.

## Mobile release status

The `v0.x` releases here contain the host daemon. They do not publish Litter
Android or iOS. See the [Android release guide](../../apps/android/docs/release-automation.md),
[Android Play workflow](https://github.com/0xSero/litter/actions/workflows/android-play-release.yml),
and [iOS release workflow](https://github.com/0xSero/litter/actions/workflows/ios-app-store-release.yml)
for the matching mobile source/build and submission status.

Background agent launches inherit the daemon environment and apply configured
project environment providers. They do not execute an interactive login shell
by default. Make required tools available on the daemon PATH before launching
it; restarting the daemon picks up changed environment variables.
