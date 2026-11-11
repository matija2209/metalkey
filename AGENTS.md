# Agent working instructions

metalkey is a GPU green-screen keyer for Apple Silicon: Swift + Metal, with ffmpeg used only to remux audio and subtitles. It is a public open-source repository.

## Rules

- Keep the CLI backwards compatible: existing flags and defaults keep their meaning. Add, don't change.
- No client or personal material anywhere in the repo or its history: no footage, frames, local paths (`/Volumes/...`, home directories), client or campaign names. Demo media only from freely licensed sources, with source and licence cited.
- The shader stays embedded (`.embedInCode("Shaders.metal")` in `Package.swift`) and is compiled at runtime. The binary must keep working without the Metal toolchain (`xcrun metal`) and without a resource bundle next to it.
- Commits: conventional commits. No AI attribution and no `Co-Authored-By` lines (owner rule).
- Push `main` directly; no PRs unless the owner asks.

## Build and check

```bash
swift build -c release
.build/release/metalkey --help
.build/release/metalkey <green-screen clip> --preview /tmp/check.png --at 3
```

For changes to the key, geometry or encoder, render a real clip and compare against the previous build with `ffmpeg -i new.mp4 -i old.mp4 -lavfi ssim -f null -`, and check that the audio is still bit-identical to the source (`ffmpeg -i X -map 0:a:0 -c copy -f md5 -`). Write test renders to a temp directory, never into the repo.

## Releasing

A release is a version tag plus a Homebrew formula update. Do both.

1. Bump nothing in code (there is no version constant). Make sure `main` is pushed and builds.
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`. `.github/workflows/release.yml` builds on `macos-15` (arm64), smoke-tests `--help`, and creates the GitHub Release with `metalkey-vX.Y.Z-macos-arm64.tar.gz` and its `.sha256`.
3. Wait for it and check the assets:
   ```bash
   gh run watch "$(gh run list --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
   gh release view vX.Y.Z --json assets -q '.assets[].name'
   ```
   If the run is cancelled within seconds with no steps, the runner label is probably retired. Read the check-run annotations (`gh api /repos/matija2209/metalkey/check-runs/<id>/annotations`), move `runs-on` to a supported Apple Silicon image, then `git push --delete origin vX.Y.Z`, re-tag the fixed commit and push the tag again (only while no release exists for it).
4. Update the tap, `matija2209/homebrew-tap`, file `Formula/metalkey.rb`: set `url` to the new tarball and `sha256` to the value from `gh release download vX.Y.Z -R matija2209/metalkey -p '*.sha256' -O -`. Don't add a `version` line (it's read from the URL). Keep the `depends_on` order `arch`, `"ffmpeg"`, `macos` (strict audit requires it). If `Package.swift` raises the minimum macOS, raise `depends_on macos:` to match.
5. Verify like a user, then push the tap:
   ```bash
   brew untap matija2209/tap 2>/dev/null
   brew install matija2209/tap/metalkey
   brew test matija2209/tap/metalkey
   brew audit --strict matija2209/tap/metalkey
   /opt/homebrew/bin/metalkey --help
   ```
   A local dev build earlier on `PATH` (e.g. `~/.local/bin/metalkey`) shadows the brewed one; that warning is expected. `brew uninstall metalkey` afterwards if the owner uses the dev build.

Not published to Homebrew core or npm on purpose: the tap covers Mac CLI users, and an npm package would only wrap the same binary.
