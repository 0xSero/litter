# kittylitter

Distribution wrapper for the [alleycat](https://github.com/0xSero/alleycat) daemon.

The next host release is 0.3.11. After its GitHub release is published, install and pair it:

```sh
npx --yes https://github.com/0xSero/litter/releases/download/v0.3.11/kittylitter-npm-package.tar.gz
```

The GitHub release package supports the same platforms as the npm wrapper.
Registry publishing currently fails because the `kittylitter` npm package is
owned by another account; `npx kittylitter` still resolves the older 0.3.4 release.
The pinned GitHub package above is the coordinated host candidate; it is not
available until the 0.3.11 release finishes. The currently published fallback is
[0.3.10](https://github.com/0xSero/litter/releases/tag/v0.3.10).

The wrapper passes its package version and Kittylitter application identity to
`alleycat::App::run()`. All daemon behavior lives in the alleycat crate; this crate exists so cargo-dist sees a `kittylitter` package name and produces correctly-named artifacts (`kittylitter-installer.sh`, `kittylitter.rb`, `kittylitter` on npm).

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

Local Studio's bundled Pi runs through `node` on the daemon PATH. The host never
uses the desktop Electron executable for that background runtime, even in
Electron's Node mode. If Node is unavailable, bundled Pi discovery fails closed;
install Node and restart the daemon to enable it.
