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
