# docs.julialang.org

Built documentation for the [Julia language](https://julialang.org/). Source files live in the [Julia repository](https://github.com/JuliaLang/julia) — contribute there.

## Branches

- **`gh-pages`** — HTML docs served at [docs.julialang.org](https://docs.julialang.org)
- **`assets`** — PDF manuals for every Julia release, pre-release, and nightly
- **`master`** — CI pipeline for building PDFs

## PDF pipeline

A daily [GitHub Actions workflow](.github/workflows/PDFs.yml) builds PDF documentation:

1. **Collect versions** — compares tags against existing PDFs on the `assets` branch; skips versions already built or listed in [`pdf/skip-versions.txt`](pdf/skip-versions.txt)
2. **Build in parallel** — each missing version + nightly runs as a separate matrix job: downloads the Julia binary, clones the source at the matching tag, and runs `make pdf` via [Documenter.jl](https://github.com/JuliaDocs/Documenter.jl)
3. **Commit** — collects built PDFs and pushes to the `assets` branch

### Key files

| File | Purpose |
|------|---------|
| [`pdf/make.jl`](pdf/make.jl) | Download binaries, build PDFs, commit to assets |
| [`pdf/skip-versions.txt`](pdf/skip-versions.txt) | Versions to skip (missing binaries, build failures) |
| [`.github/workflows/PDFs.yml`](.github/workflows/PDFs.yml) | CI workflow (collect → build → commit) |
| [`.github/actions/setup-pdf-build/`](.github/actions/setup-pdf-build/) | Composite action for Julia + TeX Live + repo setup |

### Adding a skip

If a version fails to build, add it to `pdf/skip-versions.txt` — no code changes needed.
