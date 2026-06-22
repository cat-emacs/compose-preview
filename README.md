# Compose Preview

Android Studio-style Jetpack Compose `@Preview` browsing from Emacs.

Paparazzi is used as the rendering engine because it can render Compose without
an emulator. The Emacs experience is centered on refreshing and viewing previews,
not on running UI tests. Snapshot record/verify commands remain available as
secondary Paparazzi utilities.

## Installation

With `use-package` and `package-vc`:

```elisp
(use-package compose-preview
  :vc (compose-preview :url "https://github.com/chuxubank/emacs-studio"
                       :lisp-dir "compose-preview/")
  :commands (compose-preview-refresh
             compose-preview-record
             compose-preview-verify
             compose-preview-open-results
             compose-preview-set-variant))
```

From a local checkout:

```elisp
(add-to-list 'load-path "/path/to/emacs-studio/android-mode")
(add-to-list 'load-path "/path/to/emacs-studio/compose-preview")
(require 'compose-preview)
```

`compose-preview` can run without `android-mode`, but it reuses android-mode's
module and variant discovery when `android-mode` is available.
That discovery follows Android Studio's model more closely: it uses the Gradle
project path, Android Components variants, and source-set roots reported by
Gradle. This lets Kotlin Multiplatform files under source sets such as
`src/commonMain/kotlin` map back to the Android module that owns the preview.

## Commands

- `M-x compose-preview-refresh`
  - refreshes previews in the background for the current Android module, writes
    Gradle output to `*compose-preview-log*`, and opens the image gallery for
    the current Kotlin buffer's `@Preview` functions. When point is inside a
    `@Preview` function, only that preview function is rendered.
- `C-u M-x compose-preview-refresh`
  - prompts for module and variant using android-mode's cached flavor data.
- `M-x compose-preview-open-results`
  - opens generated preview PNGs. From a Kotlin buffer, it filters to that
    buffer's previews; elsewhere it falls back to the module gallery.
- `M-x compose-preview-set-variant`
  - changes the default variant using android-mode's variant list when present.
- `M-x compose-preview-record`
  - secondary snapshot command: records Paparazzi golden images.
- `M-x compose-preview-verify`
  - secondary snapshot command: verifies Paparazzi golden images.

## How It Works

`compose-preview-refresh` runs Gradle in the background with a temporary init
script. The script injects Paparazzi into the current Android module, generates a
temporary scanner-backed preview runner, runs `test<Variant>UnitTest`, and
opens the resulting PNGs in an Emacs gallery buffer. Build output stays in
`*compose-preview-log*`; failed refreshes display that buffer automatically.
`compose-preview-record` and `compose-preview-verify` use the visible
`*compose-preview*` compilation buffer.

The gallery is source-focused: when refresh is launched from a Kotlin file, it
shows only previews declared in that buffer and labels each section with the
preview display name rather than the Paparazzi PNG filename.
If point is inside a function directly annotated with `@Preview`, refresh is
further narrowed to that function. This mirrors Android Studio's run
configuration behavior, where a preview run is produced from the containing
preview function instead of the whole file.
Preview metadata comes from `AndroidComposablePreviewScanner`, not Emacs-side
annotation parsing, so custom multipreview annotations such as `@DevicePreview`,
`@PreviewBackground`, and AndroidX templates like `@PreviewScreenSizes` follow
the same discovery path as Android Studio-style previews.
When invoked from a Kotlin buffer, the gallery does not fall back to module-wide
images; if the scanner manifest cannot attribute a preview to that source file,
the command reports that no current-buffer previews were found.

The generated runner uses `AndroidComposablePreviewScanner`,
`TestParameterInjector`, and `AndroidPreviewScreenshotIdBuilder`, so preview
discovery is closer to Android Studio than a hand-written regex. Refresh passes
the current Kotlin file to the runner, so it scans with the same scanner path but
renders only previews attributed to that file or, when a direct `@Preview`
function is selected, that function.

## Configuration

```elisp
(setq compose-preview-default-variant "debug"
      compose-preview-paparazzi-version "2.0.0-alpha02"
      compose-preview-image-width 420)
```

Set `compose-preview-disable-ksp2` to non-nil only for projects that still need
KSP1. Recent KSP versions fail configuration when `ksp.useKSP2=false` is passed.

`compose-preview-use-legacy-android-dsl` defaults to non-nil because Paparazzi
`2.0.0-alpha02` still needs AGP's legacy Android extension for resource tasks in
AGP 9 projects.

Refresh uses Gradle build cache, parallel execution, Kotlin incremental
compilation, and KSP incremental processing by default. Configuration cache is
disabled because the preview init script injects dynamic task actions. If a
project hits stale generated state while previewing, temporarily set
`compose-preview-force-clean-build` to non-nil to run a slower clean-style
preview build.

## Notes

- Projects with product flavors usually need a full variant name, for example
  `demoDebug`, because Paparazzi creates tasks like `recordPaparazziDemoDebug`.
  compose-preview reuses android-mode's flavor cache and selection helpers.
- The selected module and variant are cached per Gradle project, so refreshes
  from Kotlin buffers, the preview gallery, or the log buffer reuse the same
  target until you select another one with `C-u M-x compose-preview-refresh` or
  `M-x compose-preview-set-variant`.
- If Gradle reports an ambiguous task such as `recordPaparazziDebug`, the Emacs
  command offers the candidate variants and retries with the selected one.
- Refresh runs the generated preview test through the normal unit-test task and
  reads Paparazzi's HTML report images. It does not record golden snapshots.
- `compose-preview-record` still uses `recordPaparazzi<Variant>`, so recorded
  golden snapshots use Paparazzi's normal `src/test/snapshots` location.

## Development

Run package checks from this directory:

```sh
make install-deps
make lint
make build
make test
```
