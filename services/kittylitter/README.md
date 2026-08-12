# kittylitter

Distribution wrapper for the [alleycat](https://github.com/dnakov/alleycat) daemon. Ships the daemon to npm, Homebrew, and the platform installer scripts under the kittylitter brand.

The wrapper itself is a 3-line `main()` that re-exports `alleycat::run("kittylitter")`. All daemon behavior lives in the alleycat crate; this crate exists so cargo-dist sees a `kittylitter` package name and produces correctly-named artifacts (`kittylitter-installer.sh`, `kittylitter.rb`, `kittylitter` on npm).

## Cutting a release

1. Land the Alleycat change in `dnakov/alleycat`, then choose the immutable commit to ship.
2. Update the matching `rev` pins and lockfiles in `services/kittylitter` and `shared/rust-bridge`; the daemon and mobile bridge must ship the same Alleycat revision.
3. Run the relevant mobile acceptance lanes, then bump `version` in this crate's `Cargo.toml`.
4. Land that version bump on `main`. The `auto-release` workflow dispatches `release.yml`, which creates the tag and publishes from the pinned dependency graph.
