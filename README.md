# Compose Preview

Android Studio-style Jetpack Compose `@Preview` browsing from Emacs.

Previews are rendered by `compose-preview-renderer`, the standalone layoutlib
renderer that Android Studio publishes and uses for its own Compose screenshot
support. Nothing is injected into the project: no generated sources, no extra
test plugins, no build file rewriting, no snapshot testing framework.

## Status

The Emacs, Gradle, and renderer paths are implemented end to end. A refresh
returns immediately, builds and renders in background processes, and updates a
persistent side-window panel without clearing the last successful images while
work is in progress. The panel shows build, render, ready, and failure status.
Saving can also trigger a debounced refresh when
`compose-preview-auto-refresh-mode` is enabled in the source buffer.

## How It Works

Rendering happens in three steps.

1. A Gradle init script registers `composePreviewModel` on the target module.
   The task resolves layoutlib and the renderer from Google's Maven repository,
   collects the module's classpath through AGP's public `ScopedArtifacts` API,
   discovers `@Preview` functions from compiled bytecode, and writes everything
   to a JSON model file.
2. Emacs filters the model to the current Kotlin file or containing preview
   function, writes a rendering settings file, and compiles the fixed launcher
   once per renderer version under `compose-preview-cache-directory`.
3. The launcher renders in a separate JVM and writes a results file with one
   PNG per preview. Gradle and the renderer run asynchronously; a newer refresh
   cancels and supersedes an older one.

## Emacs UI

Run `M-x compose-preview-refresh` from a Kotlin source buffer. The command opens
a panel on the right and returns immediately. Inside the panel:

- `g` refreshes from its associated source buffer;
- `l` opens the Gradle and renderer log;
- `q` closes the side window.

Run `M-x compose-preview-auto-refresh-mode` in a source buffer to refresh all
previews in that file after each save. Saves are debounced by
`compose-preview-auto-refresh-delay`; automatic refresh is buffer-local and is
off by default. `compose-preview-panel-width` controls the side-window width.

### Preview discovery

Discovery uses `compose-preview-detector`, the same bytecode scanner AGP uses.
Multipreview annotations expand exactly as they do in Studio, so
`@PreviewScreenSizes`, `@PreviewFontScale`, `@PreviewLightDark` and custom
multipreview annotations all work, and `@PreviewParameter` providers are
expanded by the renderer itself.

### Why a launcher instead of the renderer's own CLI

The renderer ships a CLI entry point, but it constructs
`RenderEnvironmentBootstrapper` without `rClassJars`. That leaves the renderer
with no registered resource packages, so `ViewLoader` never parses any R class.
Because the renderer runs with final resource ids, every id a library reads
through its own R class then resolves to `0`. In practice this means previews
render as blank images, and `ComposeViewAdapter` fails while attaching the
lifecycle owner.

`ComposePreviewRenderLauncher.java` calls the eight-argument bootstrapper with
`rClassJars`, which is the same entry point Studio's screenshot test engine
uses. Everything else reuses the renderer's own model classes and JSON
serialization. The launcher is compiled once against the resolved renderer jars.

A future renderer release will make the launcher unnecessary for discovery:
`Renderer.render` on Studio's main branch expands multipreview itself, so only a
method name has to be passed. That change is not in `0.0.1-alpha16`.

### Resource apk

layoutlib resolves resources against a resource apk whose ids must match the R
classes on the classpath. The module's local test component provides both from
the same `aapt2` link, so the task uses `APK_FOR_LOCAL_TEST` and the matching
non-namespaced R jar. AGP only links that apk when Android resources are
requested for local tests, so the init script enables
`testOptions.unitTests.includeAndroidResources` for the target module.

### Kotlin Multiplatform

Traditional Kotlin Multiplatform modules using `androidTarget` with
`com.android.application` or `com.android.library` follow the ordinary Android
variant path. Modules using the newer
`com.android.kotlin.multiplatform.library` plugin are supported on AGP 9.3.x by
a version-gated adapter under `adapters/`.

The KMP module must create an Android host test, include Android resources, and
put the Android Compose tooling runtime on the Android target's runtime
classpath:

```kotlin
kotlin {
    android {
        androidResources.enable = true
        withHostTestBuilder {}.configure {
            isIncludeAndroidResources = true
        }
    }
    sourceSets.androidMain.dependencies {
        implementation("androidx.compose.ui:ui-tooling:<compose-version>")
    }
}
```

The tooling dependency provides `ComposeViewAdapter`; Compose Multiplatform's
common `uiToolingPreview` dependency provides the `@Preview` annotation but not
that Android runtime implementation.

AGP's public Variant API exposes the KMP host-test component but not its
layoutlib resource APK or matching runtime R jar. The AGP 9.3 adapter contains
the only two internal artifact lookups used by this package; project classes,
dependency classpaths, task registration, and rendering continue to use public
APIs. An unverified AGP version or changed internal artifact model fails with a
specific compatibility error rather than guessing intermediate paths.

## Verified Against

- `Android-screenshot-testing-playground`, AGP 8.11.1 / Gradle 8.13, library
  module. Rendered sizes match the official
  `com.android.compose.screenshot` plugin output for every shared preview, and
  the shared preview is 99.94% pixel-identical.
- `nowinandroid`, AGP 9.3.2 / Gradle 9.7.1, with Isolated Projects and the
  configuration cache enabled and a flavored variant (`demoDebug`). 21 preview
  declarations expanded to 40 renders with no errors.
- `com.android.kotlin.multiplatform.library`, AGP 9.3.2 / Gradle 9.7.1, using
  the `androidMain` variant and host-test resources. Both an `androidMain`
  Preview reading a string through the module R class and a Compose
  Multiplatform Preview declared in `commonMain` rendered through layoutlib as
  non-empty 630 x 263 PNGs. The model task reused Gradle's configuration cache;
  removing the host test produced the expected `withHostTestBuilder {}`
  diagnostic.

These checks are focused runtime validation rather than repository test
fixtures: this personal configuration repository does not add new test files.
The existing ERT suite asserts the adapter boundary, AGP version gate, required
artifact keys, and user-facing configuration diagnostics.

## Configuration

The init script reads these environment variables:

| Variable | Meaning |
| --- | --- |
| `COMPOSE_PREVIEW_MODULE_PATH` | Gradle path of the target module, required |
| `COMPOSE_PREVIEW_MODEL_FILE` | Where to write the JSON model, required |
| `COMPOSE_PREVIEW_ADAPTER_DIRECTORY` | Versioned AGP adapters; set by Emacs |
| `COMPOSE_PREVIEW_VARIANT` | Variant name, defaults to `debug` |
| `COMPOSE_PREVIEW_LAYOUTLIB_VERSION` | Defaults to the version AGP pins |
| `COMPOSE_PREVIEW_RENDERER_VERSION` | Standalone renderer version |
| `COMPOSE_PREVIEW_DETECTOR_VERSION` | Preview detector version |

Projects with product flavors need a full variant name, for example
`demoDebug`. Projects using Isolated Projects reject
`--no-configuration-cache`, so the task is configuration-cache compatible and
that flag must not be passed.

## Development

Run package checks from this directory:

```sh
make install-deps
make lint
make build
make test
```

Licensed under GPL-3.0-or-later.
