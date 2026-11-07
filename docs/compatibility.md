# Compatibility and internals

[Back to README](../README.md)

## Renderer and supported scope

| Dependency | Pin / requirement |
| --- | --- |
| Standalone renderer | `0.0.1-alpha17` |
| Layoutlib | `17.0.4` |
| Preview detector | `32.5.0-alpha05` |
| CLI / renderer JDK | 21+ |
| Internal Android KMP artifact adapter | AGP 9.3.x only |
| Preview component | main only |

The Java adapter uses the published renderer, not private Studio patches. It
refreshes project classes before each top-level screenshot through alpha17's
public API. Without this isolation a failed composition can contaminate later
cards or hide missing-class errors.

Static callbacks run through alpha17. A `LaunchedEffect` probe matched its settled
reference PNG, but arbitrary animation, network data and unscoped coroutine work
are not guaranteed to settle.

Warm renderer reuse, component-tree extraction, inflate-only and interactive /
animation Preview are not enabled. Each render invocation uses a cold owned
process. The Emacs inspector can consume compatible component metadata, but
finding tree classes in the renderer JAR does not establish extraction support.

Android resource, MultiPreview and PreviewParameter rendering and independent
AGP 9.3 KMP resources have been exercised locally. Release/platform CI covers
installation, launchers and doctor, not full rendering on every OS. CLI runtime
compatibility does not imply every project supports that JDK for Gradle.

## JVM policy

The renderer uses the CLI's JDK. Gradle JVM selection is separate, in this order:

1. Supported project Daemon JVM criteria (Gradle 8.8+).
2. Explicit `--gradle-java-home`.
3. User / project `org.gradle.java.home`.
4. Linked IDE Gradle JVM settings.
5. `JAVA_HOME`, otherwise the CLI runtime.

Criteria retains Gradle's precedence even over an explicit home. IDE
`#JAVA_HOME` is supported; `#GRADLE_LOCAL_JAVA_HOME` reads
`.gradle/config.properties` only when selected by the matching root in
`.idea/gradle.xml`. An unknown named IDE SDK requires an explicit path: the CLI
does not import IDE SDK tables or guess another installed JDK.

The same policy applies to Tooling API and wrapper `--no-daemon` builds. The
implementation does not rewrite configuration, migrate JVM targets or provision
JDKs; Gradle may provision according to existing project settings.

Doctor reports requested selection without starting Gradle (`gradleJvmActual:
not-probed`). Model/list/render `gradleJvm` records the actual runtime used to
build that model; a reused model is not a new probe. JVM policy files, user
properties and JDK identities participate in freshness. The independent Android
Project CLI/core retain Java 17 support.

## KMP resource packaging

Preview currently obtains an AGP host-test resource APK and runtime R JAR for
layoutlib. It renders **main** classes; it does not execute host tests.

During this Preview invocation, the adapter enables Android resources on the
existing host-test compilation, preserving its other options and source sets.
When absent it creates a temporary host test. These are invocation-local changes,
not edits to user build files or persistent changes to ordinary Gradle builds.
The AGP version gate and resource-artifact validation remain enforced.

### Manifest placeholders

Dependency AAR manifests may require application placeholders such as `qqappid`.
For Preview resource packaging, missing values are filled with `compose-preview`:

```text
explicit host value > main-variant value > Preview fallback
```

This applies to existing and automatically created host tests. AGP's
`applicationId` is excluded from the fallback. Other invalid values still fail
Manifest/resource validation; nodes and checks are not removed to force success.

AGP disallows early reads during `onVariants`. The lazy merge uses Gradle's
internal MapProperty replacement capability to detach the original supplier,
avoid self-reference and preserve explicit values. Missing capability fails
explicitly. This compatibility seam has been exercised with Gradle 9.6.1 and 9.8.0;
it is not a promise of compatibility with arbitrary Gradle releases.

stderr and the `previewManifestPlaceholders` field in model/list/render JSON
report fallback **keys**, not configured values. The stand-ins support resource
packaging only: they do not validate production login, deeplinks or manifest
runtime behavior. The host-resource change shipped in CLI 0.1.6; the existing-host
placeholder fix and diagnostics shipped in 0.1.7.

## Freshness and cache behavior

A reusable result is bound to target identity, source/resource/build inputs,
compiled artifacts, core, renderer and JDK environment. Inputs changing during
build/render cannot be accepted as fresh. Old compiled models/results missing
complete target identity require a rebuild. Receipts are derived state, not
files to edit to bypass validation.

CLI signatures protect entry and owning build roots. Repeat `--input-root DIR`
for known external dependency/build inputs: it extends baseline coverage rather
than replacing it. Standalone CLI does not automatically discover every external
input; dynamic inputs can still need a manual build.

### Emacs invalidation

- The frontend requests the active target's dependency graph asynchronously.
  Ready graphs permit scoped invalidation for known source ownership. Unknown
  ownership, build scripts, partial/stale/missing graphs remain conservative.
- It forwards dependency roots and all discovered build roots, including
  convention/plugin builds absent from source edges. This does not claim fully
  incremental compilation or eliminate every rebuild.
- Scoped project notifications distinguish metadata, variant selection and exact
  dependency updates. Completing a graph with unchanged input coverage does not
  discard images or restart an in-flight render. Expanded coverage invalidates
  its target; selection changes affect that module. Metadata refresh remains
  project-wide.
- Only the visible session is monitored. Background results stay attached to
  their source; opening a different file never displays another file's last PNGs.

### Diagnostics and cleanup

`preview-cache` on stderr explains model/image reuse or rebuild reasons.
`preview-timing` covers model preparation, Gradle build, declaration selection,
launcher preparation, renderer process and final freshness. Frontend logs add
project-model wait, display and total time. Timings are nested: `prepare-model`
includes `gradle-build`; renderer-process includes JVM startup, render and cleanup.
Do not add these values as independent phases.

Pruning deletes only marked inactive run directories, skips symlinks and honors
`--keep`. Models and launchers are not auto-pruned; project outputs and shared
Gradle caches are outside its scope. Cancellation and bounded cleanup apply to
owned operations/processes, never shared Gradle/Kotlin daemons. Renderer defaults
are `-Xmx1536m` and a 300-second timeout.

## Removed interfaces

The former `compose-preview-use-android-mode-flavors` alias and unstructured
image-list APIs are removed. Use Android Project target APIs and the structured
CLI result contract. See [TODO.md](../TODO.md) for deferred work and replacement
gates for the custom renderer launcher.
