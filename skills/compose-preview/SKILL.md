---
name: compose-preview
description: >-
  Discover and render Android or Kotlin Multiplatform Compose @Preview functions
  to PNG with the compose-preview CLI; inspect per-card errors, use fresh render
  caches, apply temporary device/size overrides or prune owned preview runs.
  Use for headless Compose Preview and render/JDK diagnosis. For project metadata,
  variant/source ownership or dependency graphs, use android-project.
---

# Compose Preview

Use the installed `compose-preview` CLI for headless discovery/rendering.
No Emacs session, emulator or `android-project` executable is required to render
an already identified target. Project metadata can be obtained separately with
`android-project`; the two CLIs share a JVM library, not a CLI-to-CLI transport.

## Preflight and target

1. Locate the executable (`command -v compose-preview`, or `Get-Command` on
   Windows) and read `compose-preview --help`. Release 0.1.5 requires **JDK 21+**
   for the CLI/renderer. Check PATH for an older shadowing installation.
2. Choose the trusted project entry root, owning build root, build-local module,
   variant, module root and saved Kotlin source. Use canonical absolute paths.
   Obtain uncertain identities from `android-project` metadata; do not guess a
   KMP variant or resolve duplicate module paths by display name.
3. Run `compose-preview doctor --project "$ROOT" --json`. Require ready installed
   resources; inspect versions and `gradleJvmSelection`. Doctor does not start
   Gradle: `gradleJvmActual: not-probed` is not proof of a successful build.
   If missing, offer [README installation choices](https://github.com/cat-emacs/compose-preview#install); install/upgrade only when
   authorized. Release distributions need no Packages credentials.

Only the **main** component is supported. Keep entry `--project` separate from
owning `--build-root` in composites. Pass explicit `--module`, `--build-root`,
`--module-root`, `--variant`, `--component main`, and `--component-name` equal to
variant when consuming metadata. KMP's internal artifact adapter is AGP 9.3.x
only. An unsupported host-resource configuration is a blocker, not permission to
edit user Gradle files or render main in place of a test component.

CLI reads disk, not unsaved editor buffers; confirm intended edits are saved.
Discovery may compile; rendering configures/builds trusted project code, resolves
dependencies and writes project outputs/caches. Keep stdout JSON separate from
stderr, capture the exit code, and set the outer deadline longer than both build
and render deadlines plus startup/cleanup.

## Discover, then render

The following POSIX examples assume a unique writable `$WORK` and an exact
non-composite target. Add the identity options above for composite/metadata use.

```sh
compose-preview list --project "$ROOT" --module "$MODULE" --variant "$VARIANT" \
  --file "$SOURCE" --build-timeout 600 --json \
  > "$WORK/previews.json" 2> "$WORK/list.log"

compose-preview render --project "$ROOT" --module "$MODULE" --variant "$VARIANT" \
  --file "$SOURCE" --out "$WORK/images" --build-timeout 600 --timeout 300 \
  --result-file "$WORK/result.json" --json \
  > "$WORK/render.json" 2> "$WORK/render.log"
```

`--out` must be absent/nonexistent or empty; use a new output directory rather
than deleting existing images. `--method FQN` or `--preview-id ID` selects an
entry returned by discovery. Do not fabricate IDs, especially for MultiPreview
or parameter-provider instances. An exit-0 result with no declarations/images
is not evidence that the requested function rendered: confirm expected discovery.

Inspect `status`, `stale`, `target`, `globalError`, top-level `error`, and every
`results[]` entry's error and nonempty `imagePath`. Healthy PNGs can coexist with
card errors. Verify PNG files exist and use an available image-viewing tool when
the request is visual; reporting paths alone is not visual validation. Preserve
per-card identities and parameter instances in the report.

## Keep the renderer and project JDK separate

CLI/renderer use Java 21+. Project Gradle can use a different JDK:

```sh
compose-preview render --project "$ROOT" --module "$MODULE" --variant "$VARIANT" \
  --file "$SOURCE" --gradle-java-home /absolute/jdk17 --json
```

Preserve supported Daemon JVM criteria; it takes precedence even over the explicit
home. Otherwise selection uses the explicit home, user/project
`org.gradle.java.home`, linked IDE JVM macro/path, then `JAVA_HOME`/CLI runtime.
`#GRADLE_LOCAL_JAVA_HOME` requires its linked IDE selection and local config;
unknown named IDE SDKs need an explicit path. `doctor --project` is a policy
check; render/list `gradleJvm` reports the runtime used to build the model (which
may be reused). Keep the reported `gradleJvmSelection` distinct from that runtime.
Use `--no-daemon` only when requested; it selects wrapper subprocess execution.
Do not rewrite project JVM targets, disable host-resource validation or install
JDKs to hide an error. Gradle may provision under existing project settings.

## Reuse and external inputs

- `--reuse` validates a compiled model and builds if stale. Add
  `--previous-result "$WORK/result.json"` to permit validated image reuse too.
  Omit `--out` for a new cached run or select another empty output directory;
  existing output directories are not overwritten.
- `--no-build` requires fresh compiled state and fails instead of building.
- `--model FILE` accepts a CLI-produced compiled model **with its receipt**, not
  Project System metadata. Keep its exact target, JDK selection and artifacts.
- Repeat `--input-root DIR` for known dependency/build inputs outside baseline
  roots, especially when invoking CLI without Emacs dependency tracking. Project
  dependency edges alone do not cover every external/convention/plugin input.
- On `stale-model` or `stale: true`, discard freshness claims, stabilize/save
  inputs and rebuild. A bounded retry is reasonable; repeated changes need
  investigation. Never edit receipts or reuse flags to bypass validation.

## Temporary configuration and cleanup

For device/dp overrides, read [overrides.md](references/overrides.md). Overrides
change rendering only; they are not source edits or screenshot-test generation.

Prune only when cleanup is requested. First inspect candidates:

```sh
compose-preview cache prune --dry-run --older-than 86400 --json
# After reviewing candidates and confirming deletion scope:
compose-preview cache prune --apply --older-than 86400 \
  --keep /absolute/cache/runs/RUN_ID --json
```

Use the same `--cache-dir` for both operations if nondefault. Preserve runs still
needed by the user; the command only handles owned inactive run directories, not
model/launcher caches, project outputs or shared Gradle caches. Cancel only owned
processes/operations; leave shared daemons alone.

## Completion

| Exit | Interpretation |
| --- | --- |
| 0 | Successful operation; still verify expected declarations/images |
| 1 | Partial card failures or stale inputs; retain/report healthy siblings |
| 2 | Input/setup/build/global failure; inspect JSON and stderr |

Report exact target, requested/actual build JVM, renderer versions, freshness,
healthy/failed card counts, image/output paths and diagnostics. Preserve the
original nonzero exit status when collecting logs. PNG rendering does not imply
runtime app correctness or cross-platform rendering support. Warm rendering,
component-tree extraction, inflate-only and interactive/animation preview remain
disabled; do not claim them from class presence or doctor success.
