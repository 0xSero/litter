# kittylitter

Distribution wrapper for the [alleycat](https://github.com/dnakov/alleycat) daemon. Ships the daemon to npm, Homebrew, and the platform installer scripts under the kittylitter brand.

The wrapper itself is a 3-line `main()` that re-exports `alleycat::run("kittylitter")`. All daemon behavior lives in the alleycat crate; this crate exists so cargo-dist sees a `kittylitter` package name and produces correctly-named artifacts (`kittylitter-installer.sh`, `kittylitter.rb`, `kittylitter` on npm).

## Cutting a release

1. Push the alleycat changes to `dnakov/alleycat`.
2. Bump the `alleycat` dependency in `Cargo.toml` to a pinned git rev (replace the `path = ...` form with the `git = ..., rev = ...` form in the comment above it).
3. Bump `version` in this crate's `Cargo.toml` and the version of the kittylitter binary tracking it.
4. Tag `vX.Y.Z` on the litter repo. The `release.yml` workflow at the repo root builds and publishes.
