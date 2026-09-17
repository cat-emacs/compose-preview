# Compose Preview

Android Studio-style Jetpack Compose `@Preview` browsing from Emacs.

Previews are rendered by `compose-preview-renderer`, the standalone layoutlib
renderer that Android Studio publishes and uses for its own Compose screenshot
support. Nothing is injected into the project: no generated sources, no extra
test plugins, no build file rewriting, no snapshot testing framework.

## Status

The Gradle side and the renderer invocation are implemented and verified. The
Emacs side has not been ported yet, so `compose-preview.el` still drives the
previous Paparazzi-based flow and does not match `preview.init.gradle`.

## How It Works

Rendering happens in three steps.

1. A Gradle init script registers `composePreviewModel` on the target module.
   The task resolves layoutlib and the renderer from Google's Maven repository,
   collects the module's classpath through AGP's public `ScopedArtifacts` API,
   discovers `@Preview` functions from compiled bytecode, and writes everything
   to a JSON model file.
2. Emacs picks the previews to render and writes a rendering settings file.
3. A small launcher renders them in a separate JVM and writes a results file
   with one PNG per preview.

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

## Verified Against

- `Android-screenshot-testing-playground`, AGP 8.11.1 / Gradle 8.13, library
  module. Rendered sizes match the official
  `com.android.compose.screenshot` plugin output for every shared preview, and
  the shared preview is 99.94% pixel-identical.
- `nowinandroid`, AGP 9.3.2 / Gradle 9.7.1, with Isolated Projects and the
  configuration cache enabled and a flavored variant (`demoDebug`). 21 preview
  declarations expanded to 40 renders with no errors.

## Configuration

The init script reads these environment variables:

| Variable | Meaning |
| --- | --- |
| `COMPOSE_PREVIEW_MODULE_PATH` | Gradle path of the target module, required |
| `COMPOSE_PREVIEW_MODEL_FILE` | Where to write the JSON model, required |
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
