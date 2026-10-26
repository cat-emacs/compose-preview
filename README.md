# Compose Preview

A Kotlin/JVM CLI and Emacs frontend for rendering Compose `@Preview` functions
with Google's standalone layoutlib renderer. Supports Android and KMP projects,
resources, MultiPreview and PreviewParameter.

It does not generate screenshot tests or rewrite project build files.

## Install

Requirements:

- **JDK 17+**, the project's Gradle wrapper and Android SDK. Use the JDK required
  by the project via `JAVA_HOME`; no Kotlin compiler is needed.
- For Emacs: **29.1+**, Transient **0.3.0+** and
  [`android-project`](https://github.com/cat-emacs/android-project) **0.1.0+**.
- Network access to resolve build/render dependencies on first use.

### Package managers

macOS / Linux ([Homebrew tap](https://github.com/cat-emacs/homebrew-tap)):

```sh
brew install cat-emacs/tap/compose-preview
# Also install for Emacs project sync:
brew install cat-emacs/tap/android-project
```

Windows ([Scoop bucket](https://github.com/cat-emacs/scoop-bucket)):

```powershell
scoop bucket add java
scoop bucket add cat-emacs https://github.com/cat-emacs/scoop-bucket
scoop install cat-emacs/compose-preview cat-emacs/android-project
```

Both install a JDK dependency. Neither requires GitHub Packages credentials.
These are maintained project repositories, not official Homebrew core or WinGet
catalog entries. Release tests cover launcher/doctor on all three platforms;
full Android rendering is not yet verified on every platform.

### Direct download or source build

[Releases](https://github.com/cat-emacs/compose-preview/releases/latest) provide
versioned ZIP/tar.gz archives and `SHA256SUMS`. Verify, extract and add `bin/` to
PATH. JDK 17+ must already be installed. CLI versions are independent of core.

Source builds need GitHub Packages credentials to download
`org.cat-emacs:android-project-core:0.1.6` (published).
Supply `GITHUB_ACTOR` and `GITHUB_TOKEN`
securely using a classic PAT with `read:packages` or an authorized Actions token.
GitHub requires authentication even for public Maven packages. Never commit tokens.

From this checkout, with credentials available:

```sh
make install-local                 # installs under ~/.local; override PREFIX if needed
compose-preview doctor --json
```

Add `~/.local/bin` to PATH. Installed distributions include core and runtime jars;
they need neither registry credentials nor the `android-project` executable for
command-line rendering. To use the checkout without installing, run
`./gradlew :cli:installDist`, then `./bin/compose-preview`.

### Emacs

Install both CLIs for Emacs integration: `compose-preview` renders images, while
`android-project.el` uses its own CLI for project sync and target selection.
The two CLIs share a library; neither starts the other.

```elisp
(use-package android-project
  :vc (:url "https://github.com/cat-emacs/android-project"))

(use-package compose-preview
  :vc (:url "https://github.com/cat-emacs/compose-preview" :lisp-dir "lisp")
  :commands compose-preview)
```

Run `M-x compose-preview` or `M-x compose-preview-refresh` from Kotlin source.
Set `compose-preview-cli-program` if the executable is not discoverable through
PATH or the checkout's `bin/` entry point. Kotlin tree-sitter is needed only for
optional source folding.

## CLI

```sh
# Discover previews; may compile the module, but does not render images.
compose-preview list --project /work/app --module :app --variant debug --json

# Render a source file to an empty output directory.
compose-preview render --project /work/app --module :app --variant debug \
  --file /work/app/app/src/main/kotlin/example/Home.kt \
  --out /tmp/home-preview --json

# Inspect cleanup before explicitly applying it.
compose-preview cache prune --dry-run --older-than 86400 --json
compose-preview cache prune --apply --keep /cache/runs/RUN_ID --json
```

Variant defaults to `debug`; Emacs passes the selected target. Target identity
includes sync entry (`--project`), owning `--build-root`, build-local `--module`,
variant and component. For included builds, pass `--build-root` and explicit
`--module`; execution uses the entry wrapper distribution with the owning build
as project directory. Optional `--module-root` cross-checks relocated modules.

Only `--component main` is currently supported (`--component-name` defaults to the
variant). Test components fail explicitly, not by rendering main instead. Old
compiled models/results without complete target identity require a rebuild and
an updated CLI; the frontend rejects incomplete or mismatched responses.
The CLI renders saved files, and the frontend rejects relevant unsaved buffers.

| Option | Behavior |
|---|---|
| `--reuse` | Reuse a validated compiled model; build if stale |
| `--no-build` | Require a fresh model; never silently build |
| `--model FILE` | Use an exact compiled model with its validation receipt |
| `--preview-id ID` / `--method FQN` | Select previews returned by discovery |
| `--overrides FILE` | Apply temporary device/size settings without editing source |
| `--timeout SECONDS` / `--build-timeout SECONDS` | Bound rendering / building |
| `--no-daemon` | Use the Gradle-client subprocess instead of Tooling API |
| `--result-file FILE` | Atomically write the result JSON |

`--json` produces one schemaVersion=1 object on stdout; logs go to stderr.
Render results include target/model/output paths, declarations, per-card results
and errors. PNG paths are absolute; healthy cards survive sibling failures.

| Exit | Meaning |
|---|---|
| 0 | Success, including no Preview declarations |
| 1 | Partial card failures or inputs changed during rendering |
| 2 | Input, setup, build or global failure |

Failures contain `status: "failed"` and `error.kind`/`error.message`.
`doctor` checks installed resources and versions, not whether a project can build.

<details>
<summary>Temporary device/size overrides</summary>

Use an annotation ID from `list` and copy its exact `configuration` into
`baseline`. A changed source baseline invalidates the override.

```json
{
  "example.HomeKt.Home_HASH": {
    "baseline": {"device": null, "widthDp": null, "heightDp": null, "showSystemUi": null},
    "values": {"widthDp": 360, "heightDp": 640, "showSystemUi": false}
  }
}
```

Allowed fields: `device` (Studio `id:`/`spec:`), `widthDp`, `heightDp`,
`showSystemUi`. Disable system decorations for size overrides to take effect.

</details>

## Preview panel

| Key | Action |
|---|---|
| `g` / `l` | Refresh / build-render log |
| `v`, `n`, `p` | Grid/Focus and card/section navigation |
| `TAB`, `S-TAB` | Fold section / toggle all |
| `/`, `G` | Search / annotation-group filter |
| `f`, `0`, `+`, `-` | Fit / Actual Size / zoom |
| `d`, `s`, `r` | Temporary device / dp size / reset |
| `i`, `o` | Optional component inspection / Preview source |
| `w` | Copy original PNG; Linux needs `wl-copy` or `xclip` |
| `q` | Close, cancel owned work and stop monitoring |

Per-file sessions preserve images, focus, zoom, folds and filters.
Opening results restores only the current source session, not another file's
last images. The old variable alias `compose-preview-use-android-mode-flavors`
and unstructured image-list APIs have been removed. Switching
files does not cancel the in-flight request or display its result on another
file. Fresh cached results avoid rebuilding/rendering. Enable
`compose-preview-auto-refresh-mode` for debounced save refresh.

Filtering, layout, folding and zoom only redraw. Device/size changes render
without building when the compiled model is fresh.

## Cache, cancellation and limits

- Preview requests the active target's dependency graph asynchronously. Ready
  graphs allow known unrelated module source saves to leave other sessions alone.
  Build scripts, unknown ownership, stale/partial/missing graphs retain broad
  invalidation over discovered builds. Only the visible session is monitored.
  CLI baseline signatures remain conservative across the entry/owning build;
  this does not claim fully incremental compilation or eliminate every rebuild.
- Scoped project notifications separate metadata, variant selection and exact
  dependency updates. Graph completion does not discard images or restart an
  in-flight render when its input roots were already protected. Expanded root
  coverage invalidates the matching target; variant selection affects only its
  module. Metadata refresh remains conservatively project-wide.
- stderr `preview-cache` explains model/image reuse or rebuild reasons;
  `preview-timing` reports model preparation, Gradle build, declaration selection,
  launcher preparation, renderer process and final freshness checks. The frontend
  log adds project-model wait, display and total request time. Renderer process
  time includes JVM startup/render/cleanup, not separately measurable phases.
  `prepare-model` includes `gradle-build`; timings are nested, not additive.
- `--input-root DIR` adds dependency-build inputs to CLI identity, receipts and
  render-time revalidation; it never removes entry/owning-build baseline roots.
  The frontend forwards graph roots plus all discovered builds, including
  convention/plugin builds not represented by source dependency edges. Standalone CLI callers must supply
  external roots themselves; this is not full automatic dependency discovery.
- Reuse validates source/resource inputs, compiled artifacts, environment, core
  and renderer identity. Inputs changing during build/render cannot be reported
  as fresh. External build inputs can still require a manual build.
- Cache pruning removes only marked, inactive run directories. It skips symlinks,
  preserves `--keep`, and never removes project outputs or shared Gradle caches.
  Models/launchers are not auto-pruned yet.
- Cancellation affects owned operations/processes, never shared Gradle/Kotlin
  daemons. Renderer defaults: `-Xmx1536m`, 300-second timeout and bounded cleanup.
- Renderer **0.0.1-alpha16**, layoutlib **16.1.0-jdk17**, detector
  **32.5.0-alpha05**. The internal KMP adapter is gated to **AGP 9.3.x**.
- Warm renderer reuse, static callbacks, inflate-only and Interactive/Animation
  Preview are not available. Alpha16 emits no component trees; inspection is
  unsupported without compatible metadata.

See [TODO.md](TODO.md) for official renderer CLI replacement gates and deferred
features. The current Java adapter uses the published renderer, not private
Android Studio patches.

## Development

```text
cli/        Kotlin orchestration and backend tests
renderer/   Java renderer adapter
gradle/     Invocation-local Preview scripts and KMP adapter
lisp/       Emacs frontend and ERT
```

Both CLIs embed `android-project-core`; Tooling API and shared IO/JSON/hash
implementations live in the [android-project repository](https://github.com/cat-emacs/android-project).
Preview keeps its own rendering, resource-input and cache policies.

```sh
# GitHub Packages credentials supplied securely in the environment.
./gradlew :cli:test :cli:installDist :cli:distZip
make install-deps
make lint build test
```

For local core development, publish from an explicit checkout and select the
file repository instead of GitHub Packages:

```sh
make project-core ANDROID_PROJECT_DIR=/path/to/android-project
make cli-test PROJECT_CORE_REPOSITORY="$PWD/.test-deps/project-core-repository"
```

Gradle accepts the same override as `-PandroidProjectRepository=PATH_OR_URL`.
CI uses `packages:read`; `PACKAGES_READ_TOKEN` can override the Actions token if
cross-repository access is unavailable. Real render smoke tests require an
Android SDK and representative projects.
