# Captr — working notes for Claude

## Workflow

- Solo project. Push fixes/features directly to `main` — no PRs needed for
  review, but a PR is fine when CI signal is wanted before merging.
- Releases are driven by Sparkle via `.github/workflows/release.yml`, which
  triggers on **any push to `main` that touches `Info.plist`**. So:
  after a fix lands on `main`, bump `CFBundleShortVersionString` and
  `CFBundleVersion` in `Info.plist` and push that commit to `main` to cut
  a new build. The release workflow handles archive/sign/notarize/DMG,
  prepends to `appcast.xml`, and creates a GitHub Release.
- Release-note source: the body of the version-bump commit. Lines
  starting with `- ` become `<li>`s in the appcast.

## Versioning

- Bug-fix release → bump patch (e.g. `1.3.5` → `1.3.6`) and build number
  by 1.
- Commit message pattern: `Bump to vX.Y.Z (build N)` followed by a blank
  line and a `- ` bulleted changelog that becomes the appcast notes.

## Build

- macOS-only (deployment target 15.0). Xcode project is generated from
  `project.yml` via `xcodegen generate`.
- CI `build.yml` runs on PRs and pushes to `main`: builds Debug + runs
  `CaptrTests` on `macos-15`.
