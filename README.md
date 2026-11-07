# Compose Preview

Render Compose `@Preview` functions to PNG with Google's standalone layoutlib
renderer. Use the **Kotlin/JVM CLI** on its own, or add the **Emacs frontend**
for a Preview panel with per-file sessions, navigation and zoom.

Supports Android and Android-targeted KMP, resources, MultiPreview and
PreviewParameter. It does not generate screenshot tests or rewrite project build
files. Discovery and rendering do execute the project's Gradle build.

Google's Android CLI now also provides headless Preview commands. See
[Official Android CLI](#official-android-cli) for the verified differences before
choosing a backend.

[Quick start](#quick-start) · [Official Android CLI](#official-android-cli) · [Install](#install) · [Java selection](#java-selection) ·
[CLI](#cli) · [Emacs](#emacs) · [Agent skill](#agent-skill) ·
[Compatibility and internals](docs/compatibility.md) · [Development](#development)

## Quick start

With the CLI installed and a compatible JDK selected:

```sh
# Check the installation; this does not build the project.
compose-preview doctor --project /work/app --json

# Discover previews. This may compile the selected module.
compose-preview list --project /work/app --module :app --variant debug \
  --file /work/app/app/src/main/kotlin/example/Home.kt --json

# Render all previews in the saved source file.
compose-preview render --project /work/app --module :app --variant debug \
  --file /work/app/app/src/main/kotlin/example/Home.kt --json
```

The render response contains absolute PNG paths in `results[].imagePath`.
Check the overall status and each card's error: a successful build alone is not
proof of a successful render. An empty result can mean no matching declarations.

## Official Android CLI

Android CLI 1.1.16717390 (October 2026) adds:

```sh
android preview list :app --format=json
android preview render :app --fqn=com.example.HomeKt.HomePreview --format=json
```

These commands do not require Android Studio or a device. They overlap with this
CLI's build, discovery and PNG rendering, and also expose daemon and
component-tree options that this project intentionally keeps disabled. This CLI
does not wrap Android CLI yet.

| | This CLI | Android CLI 1.1 |
| --- | --- | --- |
| Android application/library | Verified | Verified |
| Direct KMP `androidMain` target | Verified | Not supported in 1.1.16717390; its Gradle plugin only handles application/library plugins |
| KMP Preview through an Android host | Not the default target model | Verified when the host can build the dependency |
| Emacs panel, sessions, zoom and navigation | Included | Not included |
| Stable per-card identity | Separate IDs for configuration instances | Tested MultiPreview instances shared one `previewId` |
| Freshness and stale rejection | Explicit target/input/JVM receipts | Not equivalent in the tested JSON result |

A real AGP 9.3 KMP project verified this boundary without project changes:
direct `androidMain` failed before rendering, while its Android application host
successfully rendered the same three Preview configurations and component trees.
Do not silently retarget a KMP module to a host: resources, dependencies and
Manifest configuration can differ.

Use Android CLI when its host/application target and output contract fit the
workflow. Use this CLI when direct KMP targets, Emacs integration or strict
result freshness are required. Android CLI's newer capabilities do not by
themselves prove support for every project.

## Install

| Use | Requirements |
| --- | --- |
| CLI / renderer | **JDK 21+**, project Gradle wrapper, Android SDK and the project's build dependencies |
| Optional Emacs frontend | **Emacs 29.1+**, Transient 0.3.0+, `android-project` Elisp frontend and both CLIs |

The installed CLI bundles core/runtime JARs. It needs no Kotlin compiler,
GitHub Packages credentials, Emacs session or device connection. Standalone
rendering does **not** require the `android-project` executable.

### Homebrew — macOS / Linux

```sh
brew install cat-emacs/tap/compose-preview
# Also needed for Emacs project sync:
brew install cat-emacs/tap/android-project
```

The [tap](https://github.com/cat-emacs/homebrew-tap) uses unversioned `openjdk`
and respects an explicit `JAVA_HOME`.

### Scoop — Windows

```powershell
scoop bucket add java
scoop bucket add cat-emacs https://github.com/cat-emacs/scoop-bucket
scoop install cat-emacs/compose-preview
# Also needed for Emacs project sync:
scoop install cat-emacs/android-project
```

The [bucket](https://github.com/cat-emacs/scoop-bucket) declares a Java 21 JDK
for Preview. These are project-maintained tap/bucket repositories, not Homebrew
core or WinGet catalog entries.

### Release archives

Download ZIP or tar.gz from [Releases](https://github.com/cat-emacs/compose-preview/releases/latest),
verify it against `SHA256SUMS`, extract it and add its `bin/` directory to PATH.
A JDK is not bundled. First use may download Gradle/build/render dependencies.

Platform CI verifies installation, launchers and `doctor` on macOS, Linux and
Windows; it does not establish full rendering support on every platform.
For source builds, see [Development](#development).

## Java selection

**CLI/renderer Java and project build Java are independent.** Set `JAVA_HOME`
to a JDK 21+ for Preview. If the project needs another build JDK, keep its existing
Gradle JVM policy or supply an explicit home:

```sh
JAVA_HOME=/path/to/jdk21 compose-preview render \
  --project /work/app --module :app --variant debug \
  --file /work/app/app/src/main/kotlin/example/Home.kt \
  --gradle-java-home /path/to/jdk17 --json
```

Do not change project Java/Kotlin compilation targets just to run the renderer.
Supported Daemon JVM criteria takes precedence even over `--gradle-java-home`.
Otherwise selection considers the explicit home, user/project
`org.gradle.java.home`, linked IDE Gradle JDK, then `JAVA_HOME`/CLI runtime.

- `doctor --project DIR` reports **requested policy**, with actual JVM `not-probed`.
- `list` / `render` report `gradleJvm`: the **actual runtime that built the model**,
  which may be reused from validated compiled state.
- Emacs uses `compose-preview-gradle-java-home` for the optional build-JDK override.

See [JVM policy](docs/compatibility.md#jvm-policy) for IDE macros and limitations.

## CLI

### Select the right target

Use explicit module and variant values; variant defaults to `debug`, which is
not necessarily appropriate for KMP. Obtain uncertain identities from
[Android Project](https://github.com/cat-emacs/android-project).

| Option | Identifies |
| --- | --- |
| `--project DIR` | Entry build; supplies the Gradle wrapper distribution |
| `--build-root DIR` | Owning build; defaults to the entry build |
| `--module :path` | Module path local to the owning build |
| `--module-root DIR` | Optional check against the module's actual directory |
| `--variant NAME` | Variant, for example `debug` or a discovered KMP `androidMain` |
| `--component main` | Only main is supported; test components fail explicitly |
| `--component-name NAME` | Must match the variant; defaults to it |

For included builds, pass `--build-root` and explicit `--module`; the entry
wrapper executes with the owning build as project directory. Use canonical
absolute paths. Rendering consumes saved source, not unsaved editor buffers.

### Render and reuse

| Option | Behavior |
| --- | --- |
| `--out DIR` | Write to a new or empty directory; otherwise use a new cached run |
| `--method FQN` / `--preview-id ID` | Select a method/card returned by discovery |
| `--reuse` | Reuse a validated compiled model; build if stale |
| `--previous-result FILE` | With `--reuse`, also permit validated image reuse |
| `--no-build` | Require fresh compiled state; fail instead of building |
| `--model FILE` | Use a CLI-produced model with its validation receipt, not project-sync metadata |
| `--input-root DIR` | Repeat for external dependency/build inputs that need freshness protection |
| `--overrides FILE` | Temporary device/size overrides; [format and example](skills/compose-preview/references/overrides.md) |
| `--timeout SECONDS` / `--build-timeout SECONDS` | Renderer / build deadlines |
| `--no-daemon` | Use the wrapper subprocess; default builds use Tooling API |
| `--result-file FILE` | Atomically write the same result JSON to a file |

`--json` writes one `schemaVersion: 1` object to stdout. Progress, diagnostics
and timings go to stderr. Keep the streams separate when collecting evidence.

| Exit | Meaning | What to check |
| --- | --- | --- |
| **0** | Operation succeeded, possibly with zero declarations | Expected cards and PNGs exist |
| **1** | Partial card failures or stale render inputs | `status`, `stale`, individual card errors |
| **2** | Input, setup, build or global failure | `error.kind`, `error.message`, stderr |

Healthy cards survive sibling failures. `stale-model` means inputs or JVM policy
changed: stabilize/save inputs and retry, rather than bypassing receipts.
`previewManifestPlaceholders` lists Preview-only fallback keys, not production
configuration; see [KMP resource packaging](docs/compatibility.md#kmp-resource-packaging).

### Clean up owned runs

```sh
# Inspect candidates first; deletion is opt-in.
compose-preview cache prune --dry-run --older-than 86400 --json
compose-preview cache prune --apply --older-than 86400 \
  --keep /absolute/cache/runs/RUN_ID --json
```

Use the same `--cache-dir` for both calls when nondefault. Pruning handles only
marked inactive runs, not model/launcher caches, project outputs or shared Gradle
caches. Cancellation affects owned work, never shared Gradle/Kotlin daemons.

## Emacs

Install both CLIs, then the Elisp frontends:

```elisp
(use-package android-project
  :vc (:url "https://github.com/cat-emacs/android-project"))

(use-package compose-preview
  :vc (:url "https://github.com/cat-emacs/compose-preview" :lisp-dir "lisp")
  :commands compose-preview)
```

Run `M-x compose-preview` or `M-x compose-preview-refresh` from Kotlin source.
The frontend uses Android Project for sync/target selection; the two CLIs share
core but neither starts the other. It never installs the CLI automatically.
Set `compose-preview-cli-program` when executable discovery needs an explicit path.
Kotlin tree-sitter is needed only for optional source folding.

| Key | Action |
| --- | --- |
| `g` / `l` | Refresh / build-render log |
| `v`, `n`, `p` | Grid/Focus and card/section navigation |
| `TAB`, `S-TAB` | Fold section / toggle all |
| `/`, `G` | Search / annotation-group filter |
| `f`, `0`, `+`, `-` | Fit / Actual Size / zoom |
| `d`, `s`, `r` | Temporary device / dp size / reset |
| `i`, `o` | Optional component inspection / Preview source |
| `w` | Copy original PNG; Linux needs `wl-copy` or `xclip` |
| `q` | Close, cancel owned work and stop monitoring |

Per-file sessions retain images, focus, zoom, folds and filters. Background
results stay associated with their source file. Enable
`compose-preview-auto-refresh-mode` for debounced save refresh. Filtering,
layout, folding and zoom redraw only; device/size changes render without a build
when compiled state is fresh. Relevant unsaved buffers block rendering.

## Agent skill

Copy the whole [compose-preview skill](skills/compose-preview/SKILL.md) directory
(including references) into your agent's skill root. From this checkout:

```sh
SKILL_ROOT=/path/to/your/agent/skills
mkdir -p "$SKILL_ROOT"
# Stop if installed; review/update the existing skill separately.
test ! -e "$SKILL_ROOT/compose-preview" && cp -R skills/compose-preview "$SKILL_ROOT/"
```

Reload skill discovery and ask the agent to use `compose-preview`. This installs
instructions only, not the executable. Use a matching CLI: the latest skill
covers the Manifest fallback diagnostics introduced in **0.1.7**.

## Development

```text
cli/        Kotlin orchestration and backend tests
renderer/   Java renderer adapter
gradle/     Invocation-local Preview scripts and KMP adapter
lisp/       Emacs frontend and ERT
skills/     Portable agent workflow
```

Both CLIs embed published **`org.cat-emacs:android-project-core:0.1.7`**.
Tooling API and shared IO/JSON/hash live in the
[Android Project repository](https://github.com/cat-emacs/android-project);
Preview owns rendering, resource inputs and cache policy. CLI and core versions
are independent.

GitHub Packages requires authentication even for public Maven packages. **Source
builds only** need `GITHUB_ACTOR` and `GITHUB_TOKEN` (classic PAT with
`read:packages`, or an authorized Actions token). Supply credentials securely;
never commit them. Installed Release distributions do not need them.

```sh
./gradlew :cli:test :cli:installDist :cli:distZip
# Run the checkout CLI without installing:
./bin/compose-preview doctor --json

# Optional local installation under ~/.local; PREFIX can override it:
make install-local

# Emacs frontend checks:
make install-deps
make lint build test
```

For local core development, publish from an explicit checkout and use a file
repository instead of Packages:

```sh
make project-core ANDROID_PROJECT_DIR=/path/to/android-project
make cli-test PROJECT_CORE_REPOSITORY="$PWD/.test-deps/project-core-repository"
```

Gradle accepts the same override as `-PandroidProjectRepository=PATH_OR_URL`.
CI uses `packages:read`; `PACKAGES_READ_TOKEN` can override the Actions token.
Real render smoke tests require an Android SDK and representative projects.

See [compatibility and internals](docs/compatibility.md) for renderer pins,
resource packaging, cache invalidation and capability limits; [TODO.md](TODO.md)
tracks deferred work and official renderer-CLI replacement gates.
