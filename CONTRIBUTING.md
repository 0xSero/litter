# Contributing

## Project status

Litter is under active development and a lot of features are in flight at any given time. Direction shifts often, internal APIs are unstable, and large parts of the codebase are mid-refactor.

**Your PR will probably not be merged unless it is small and targets a specific problem.** That's not a rule against contributors — it's just the reality of a fast-moving codebase. A focused fix or a self-contained improvement has a real chance of landing. A sweeping refactor, a new feature, or a pile of stylistic changes almost certainly won't, because it'll collide with work that's already underway.

## Before you open a PR

- **Open an issue first** if you're proposing anything non-trivial. Saves you the work of writing code that overlaps with something we're already doing or have already decided against.
- **Keep it small.** One concern per PR. If you find yourself touching unrelated files, split it.
- **Target a specific problem.** A clear bug, a clear missing piece, a clear regression — not "I think this code could be cleaner."
- **Match the existing style.** Don't reformat code, rename variables, or rearrange things outside the scope of your change.
- **Don't bundle dependency upgrades** with feature/bug PRs.

## Things that will not be merged

- Large refactors not requested by a maintainer.
- Stylistic-only changes (renames, formatting, comment cleanup).
- New features without prior discussion in an issue.
- PRs that depend on other unmerged PRs.
- Anything that breaks parity between iOS and Android without a clear reason.

## Setup

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for prerequisites and build commands, and [AGENTS.md](AGENTS.md) for repo conventions.
