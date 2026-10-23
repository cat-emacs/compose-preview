# Compose Preview

A **Kotlin/JVM CLI** and an **Emacs frontend** for Android Studio Compose Preview.
Rendering uses Google's published standalone layoutlib renderer, not generated
screenshot tests, Paparazzi, or project build-file rewriting.

## Repository layout

```text
cli/        Kotlin project/build/cache/process orchestration and backend tests
renderer/   Java adapter around the published Studio renderer
gradle/     Invocation-local model init script and version-gated adapters
lisp/       Emacs Grid/Focus frontend, source navigation and frontend ERT
bin/        Repository CLI entry point
TODO.md     Official CLI replacement gates and deferred capabilities
```

The CLI owns the Gradle → discovery → javac → renderer chain, persistent compiled
model receipts, process timeouts/cancellation and run artifacts. Elisp owns
editor target selection through `android-project`, per-file UI sessions, local
image filtering/layout, view state, and source folding. It no longer launches
Gradle, javac, or the renderer itself. Both clients consume the same backend.

## Requirements and installation

- JDK **17+** to run the CLI. Project Gradle/AGP may require a specific JDK;
  use that project's `JAVA_HOME`. A local Kotlin installation is **not** required.
- Android SDK and the project's Gradle wrapper for real builds.
- Emacs **29.1+**, Transient **0.3.0+**, `android-project` **0.1.0+** for the
  optional Emacs frontend. Kotlin tree-sitter grammar is needed only for source
  folding, not rendering.
- Network access on first build to resolve Gradle/AGP, detector, renderer and
  layoutlib artifacts. CLI operations require no separate authentication.

Source builds resolve the versioned core from GitHub Packages. Supply
`GITHUB_ACTOR` and `GITHUB_TOKEN` through your credential manager; the token must
be a classic PAT with `read:packages` (or an authorized Actions token). Do not
commit credentials. GitHub's Maven registry requires authentication even for
public packages. Installed distributions need no registry credentials.

```sh
./gradlew :cli:test :cli:installDist
./bin/compose-preview --help
./bin/compose-preview doctor --json

# Install Preview with its core dependency bundled; only JDK 17+ is needed.
make install-local                   # defaults to ~/.local
# Or: make install-local PREFIX=/some/prefix
compose-preview doctor --json
```

`./gradlew :cli:distZip :cli:distTar` builds distributable archives containing
runtime jars, Gradle scripts, renderer adapter source, and `lisp/`. Installed
commands locate assets relative to their distribution, independently of cwd.
The repository `bin/compose-preview` requires `:cli:installDist` first; it does
not build itself or download dependencies merely to display help/doctor.
No Python runtime is used.

## CLI commands

```sh
# Environment/resource checks; no project build.
compose-preview doctor --json

# Independent Project System (install from cat-emacs/android-project).
android-project sync --project /work/app --json

# Build and discover annotations/providers; no image rendering.
compose-preview list --project /work/app --module :app --variant debug --json

# Render a source file. Does not edit @Preview or build.gradle(.kts).
compose-preview render --project /work/app --module :app --variant debug \
  --file /work/app/app/src/main/kotlin/example/Home.kt \
  --out /tmp/home-preview --json

# Reuse a fresh module model when possible (otherwise build).
compose-preview render --project /work/app --module :app --reuse \
  --file /work/app/app/src/main/kotlin/example/Other.kt --json

# Exact compiled model escape hatch; rejects absent/invalid validation receipt.
compose-preview render --model /cache/models/.../model-HASH.json --no-build \
  --file /work/app/app/src/main/kotlin/example/Home.kt --json

# Exact annotation ID obtained from list; optional temporary overrides.
compose-preview render --project /work/app --module :app --no-build \
  --preview-id 'example.HomeKt.Home_HASH' --overrides /tmp/overrides.json --json

# Cleanup defaults to dry run. Explicit --apply deletes only marked run paths.
compose-preview cache prune --dry-run --older-than 86400 --json
compose-preview cache prune --apply --keep /cache/runs/RUN_ID --json
```

Prefer explicit `--module` for composite builds or relocated module directories.
Without it, `--file` infers only the ordinary nearest Gradle build directory;
it does not evaluate settings DSL or guess which of several modules is selected.
The CLI currently defaults to variant `debug`; Emacs passes the user's actual
selected target.

### Independent Project System dependency

[`android-project`](https://github.com/cat-emacs/android-project) owns the
Kotlin core, Tooling API/AGP models, project collector and independent CLI.
Its standalone project CLI requires no Preview, renderer or layoutlib.
The two CLIs share the same core library, not each other's executables:

```text
compose-preview CLI -> android-project-core <- android-project CLI
Preview / Logcat Emacs frontends -> android-project.el -> android-project CLI
```

`android-project.el` invokes `android-project sync` and owns editor metadata,
cache and selection. Preview/Logcat consume its public APIs. This CLI no longer
provides `project sync` or owns a duplicate project collector. Project model
capabilities and limitations are documented in that repository.

Preview directly calls the core's `GradleTooling` inside its own JVM, passing
its `composePreviewModel` task/init script and Preview-specific environment.
There is no `android-project build` child process, no second CLI JVM and no
`--project-cli`/`ANDROID_PROJECT_CLI` selection. Installed Preview distributions
bundle core and its transitive runtime jars, and do not require the project
executable on PATH. The Emacs frontend still uses the separate project CLI for
project synchronization through `android-project.el`.

Source builds pin `org.cat-emacs:android-project-core:0.1.1`
with `https://maven.pkg.github.com/cat-emacs/android-project` as the default registry.
Version 0.1.1 is published and its jar has been verified after download.
No sibling checkout or `mavenLocal()` is used. CI has `packages:read`; the package must permit the
consumer repository's Actions token, otherwise configure the
`PACKAGES_READ_TOKEN` Actions secret (classic PAT with `read:packages`).

For explicit core development only, `make project-core ANDROID_PROJECT_DIR=/checkout`
publishes to `.test-deps/project-core-repository` without installing a CLI. Then
use `./gradlew -PandroidProjectRepository="$PWD/.test-deps/project-core-repository" ...`
or `make cli-build PROJECT_CORE_REPOSITORY="$PWD/.test-deps/project-core-repository"`.
The default remains the versioned registry, never an implicit local fallback.

Shared IO/JSON/hash implementations come from core's `cat.android.project.io`.
Preview still owns resource/font/image suffixes, marked-run exclusions, artifact
receipts and render identity; project-model input policy remains in core. CLI
parsers and business result schemas are intentionally separate.

The project backend uses the wrapper/JDK/environment, CancellationToken and
bounded timeout, with diagnostics on stderr. Closing/cancelling an owned
operation never stops shared daemons. Sync-only configuration-cache flags do not
leak into Preview builds. Explicit `--no-daemon` retains the direct Gradle-client
subprocess path because Tooling API always uses a daemon. `list` may compile the
module to discover complete MultiPreview/PreviewParameter metadata; it is not a
source-only scan.

Temporary override input, keyed by the annotation ID returned by `list`:

```json
{
  "example.HomeKt.Home_HASH": {
    "baseline": {"device": null, "widthDp": null, "heightDp": null, "showSystemUi": null},
    "values": {"widthDp": 360, "heightDp": 640, "showSystemUi": false}
  }
}
```

Use the exact `configuration` baseline returned by discovery. If source
configuration changes, old overrides are ignored. Allowed fields are `device`
(Studio `id:`/`spec:`), `widthDp`, `heightDp` and `showSystemUi`. Size overrides
must disable system decorations to take effect. CLI renders saved source files;
Emacs rejects unsaved relevant buffers before invoking it.

### JSON / exit contract

`--json` is accepted before or after the command. stdout contains **one** JSON
object; Gradle/compiler/renderer output goes to stderr. `--result-file PATH`
atomically writes the render envelope for editor clients.

```json
{
  "schemaVersion": 1,
  "status": "ready",
  "target": {"projectRoot": "/work/app", "moduleRoot": "/work/app/app", "modulePath": ":app", "variant": "debug"},
  "modelPath": "/cache/models/.../model-HASH.json",
  "outputDirectory": "/cache/runs/UUID",
  "reusedModel": true,
  "stale": false,
  "declarations": [],
  "results": [],
  "globalError": null
}
```

Results preserve renderer `previewId`, `methodFQN`, parameter-instance identity,
error diagnostics and optional component paths, plus source annotation metadata
for clients. Nonempty PNG paths are absolute. Annotation IDs include method,
provider parameters, wrapper, full annotation configuration and annotation index;
display names are never identity. Partial failures preserve healthy siblings.

| Exit | Meaning |
|---|---|
| 0 | Success, including no Preview declarations |
| 1 | Partial card failures or inputs changed during rendering (`stale`) |
| 2 | Input/setup/build/global/protocol failure |
| signal | Cancellation; owned child tasks are terminated by shutdown cleanup |

Failures use `{"schemaVersion":1,"status":"failed","error":{"kind":"...","message":"..."}}`.
Unknown renderer capabilities are not advertised as supported. `doctor` reports
Java, installed resources, pinned versions and authentication requirements; it
is not proof that a particular Android project can build.

### Cache and process policy

- Models are keyed by build root, module, variant and renderer versions. Input
  and classpath/resource signatures plus model-content hashes form a receipt.
- `--reuse` revalidates a receipt; `--no-build` fails instead of silently
  rebuilding. Explicit `--model` also requires its matching receipt. Receipts
  include a hash of the build environment (JDK/SDK/Gradle locations and JVM
  options); environment values are not stored in the receipt. Older receipts
  without this field require one rebuild.
- Image-run identity also binds the validated input/artifact signatures, actual
  JDK executable/release metadata, layoutlib/fonts metadata and launcher source.
  Recompilation into unchanged classpath paths cannot reuse older PNGs merely
  because the model JSON is unchanged.
- Builds are locked per target; launcher compilation is locked per source/
  classpath hash. Returned compiled snapshots are immutable by content hash.
- Inputs changing during build invalidate the build receipt; changes during
  rendering return stale results rather than claiming freshness.
- Run output directories are immutable and must be empty. Cache prune defaults
  to dry run, preserves `--keep`, skips active locks/symlinks/unowned directories,
  and never removes project build outputs or shared Gradle caches.
- Models/launchers are deliberately not auto-pruned yet. Do not apply run cleanup
  while an external editor still references an old run without passing `--keep`.
- Renderer JVMs default to `-Xmx1536m`, total timeout 300 seconds, bounded
  renderer/framework cleanup, then process exit. `--java-option=...` can override
  renderer JVM options; build timeout is separately configurable.
- Cancellation terminates owned client/renderer children, not shared
  GradleDaemon/KotlinCompileDaemon. `--no-daemon` explicitly opts out of Gradle
  reuse but does not stop pre-existing daemons or govern Kotlin daemon settings.
- Input tracking is conservative within the selected project root. External
  included builds and toolchain/environment changes can require a manual build.

## Emacs frontend (`lisp/`)

Install the CLI distribution first, or build the bundled one. Configure VC
installation to use `:lisp-dir "lisp"`:

```elisp
(use-package compose-preview
  :vc (:url "https://github.com/cat-emacs/compose-preview" :lisp-dir "lisp")
  :commands compose-preview
  :custom
  ;; nil checks PATH, then the repository bin/ entry point.
  (compose-preview-cli-program nil))
```

No root-level compatibility loader is installed. Existing manual load paths
must point to `lisp/`. Cat Emacs' Android module is updated accordingly.
`android-project` remains responsible for editor selected module/variant state;
standalone CLI use does not require Emacs or the `android-project` executable;
the shared project core is bundled as a library.

Run `M-x compose-preview-refresh` from Kotlin source, or use `M-x compose-preview`.
The frontend invokes the CLI asynchronously and consumes schemaVersion=1 output.

| Key | Action |
|---|---|
| `g` / `l` | Refresh / file build-render log |
| `v`, `n`, `p` | Grid/Focus and card/section navigation |
| `TAB`, `S-TAB` | Fold section / toggle all |
| `/`, `G` | Local search / annotation-group filter |
| `f`, `0`, `+`, `-` | Fit / density-aware Actual Size / zoom |
| `d`, `s`, `r` | Temporary device / dp size / reset (CLI `--no-build`) |
| `i`, `o` | Optional component inspection / Preview source |
| `w` | Copy original PNG (macOS, Windows, Linux via wl-copy/xclip) |
| `q` | Close, cancel owned work, pause monitoring |

File sessions preserve images, focus, zoom, folds, filtering and card-position
anchors. Activation displays cached images immediately, then asks the CLI to
validate the compiled model and previous run; a fresh identical request returns
`reusedImages=true` without rebuilding or rendering. File switching does not cancel the in-flight request: it caches the
original result and runs only the latest waiting file. Inactive results cannot
replace another file's surface. Default in-memory session limit is 8.
`compose-preview-auto-refresh-mode` enables debounced save refresh. UI input
monitoring is throttled (30 seconds), visible-project-only, and stops when the
panel closes. These UI image-session signatures are not a second compiled
model cache: the CLI independently validates every build/render reuse.

Source folding (`compose-preview-fold-source` / `compose-preview-unfold-source`)
uses Kotlin tree-sitter with annotation imports/aliases. Custom MultiPreview
methods use fresh CLI discovery; nested ordinary functions are not folded.
Missing grammar is explicit; there is no regex-only folding fallback.

## Studio alignment and official CLI TODO

Pinned published renderer: `0.0.1-alpha16`; layoutlib: `16.1.0-jdk17`; detector:
`32.5.0-alpha05`. AGP KMP adapter remains explicitly gated to **9.3.x**.
Configuration cache/Isolated Projects remain supported by invocation-local
Gradle adapters; project build files and test sources are not rewritten.

Audited Studio checkout (2026-10-23): `tools/adt/idea` `001c2a2cb31b`,
`tools/base` `ae69b3ef270c`.

Recent mainline work adds warm renderer/library caching (`ebdebd5074a`,
`86628813a6f`), static layoutlib callbacks with dispatcher-state isolation
(`ae7836bf399`, `b5b22b6cdc7`), correct Focus element resolution (`c8324bfc19e`),
DeviceSpec parent state (`2d4dccca121`) and diamond MultiPreview wrapper handling
(`9eb8c371bdc`). The frontend now resolves selected cards against the latest
items by stable ID; removed cards cannot mutate configuration. The CLI binds
image caches to validated input/artifact/backend signatures. Build receipts also
bind the exact embedded project-core artifact content, including local rebuilds. Warm JVM reuse,
callback execution and upstream device/wrapper behavior remain unavailable on
published alpha16 and are explicitly tracked in TODO.md, not emulated through
private renderer patches.

The Studio toolchain itself moved to Gradle 9.7.1/Kotlin 2.4.0. This CLI does
not need to match Studio's build tool versions to consume the published renderer;
its independently pinned build remains unchanged.
Relevant upstream work includes per-card failures (`19bdf7910b1`), correct Preview
configuration identity (`8f43e405e88`), unified component JSON (`0eab2119615`),
R-class work per classloader (`694b3a00813`), and safe cleanup of uninitialized
AndroidUiDispatcher.Main (`493d150540f`). Published alpha16 does not include all
of these. Local per-card handling and bounded cleanup work with alpha16; no
main-only performance improvement is claimed.

The optional inspector accepts both older `.bounds.json` and unified component
JSON, validates card identity/source locations, and preserves semantics,
modifiers and parameters. **Alpha16 does not emit component trees**: inspection
reports unsupported without fabricating data. Image-click selection,
inflate-only and Interactive/Animation Preview are not implemented.

The official artifact includes `com.android.tools.render.common.MainKt`, but
its entry point is not yet a replacement for the project's reliable R-class
bootstrap/metadata/cleanup adapter. See [TODO.md](TODO.md) for the explicit gates
for replacing our launcher with the official CLI. The backend adapter can change
without changing the project CLI protocol or Emacs frontend.

## Development

```sh
# GITHUB_ACTOR / GITHUB_TOKEN provided securely in the environment
./gradlew :cli:test :cli:installDist   # Kotlin backend, resolving published core
make install-deps                   # isolated Emacs test dependencies
make lint build test                # Elisp frontend
make install-local                  # test installed CLI from another directory
```

Backend tests cover model/input/artifact receipts, identities, overrides,
timeouts, discovery and safe prune. Frontend ERT covers UI/state/source behavior
and the CLI-result seam. Real Android/KMP/partial-failure smoke tests require a
local Android SDK and representative Gradle projects; unit tests do not
synchronize, upgrade, or delete user package/project state.
