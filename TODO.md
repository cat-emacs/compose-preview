# Backend follow-ups

## Replace the custom launcher with the official standalone renderer CLI

- [ ] Track Google Maven `com.android.tools.compose:compose-preview-renderer`
  releases. The current pin is `0.0.1-alpha16`; Studio main is not a released
  binary. Do not claim main-only optimizations/capabilities for alpha16.
- [ ] Verify that the published official entry point forwards `rClassJars` and
  renders our Android and AGP-9.3 KMP resource fixtures correctly.
- [ ] Require per-screenshot class-loading/element failures to preserve healthy
  siblings, with stable parameter-provider identity/display names.
- [ ] Verify bounded renderer/project/framework cleanup and normal process exit,
  including deadlocked disposal and non-daemon layoutlib threads.
- [ ] Detect the actual published component-tree and inflate-only capabilities;
  verify `componentTreePath`, semantics/modifiers/parameters, source locations,
  pixel units and empty image paths before enabling extraction options.
- [ ] Rebenchmark published per-classloader R-class initialization optimizations
  on our fixtures; never copy Studio internal R-class patches into Elisp.
- [ ] Gate warm-renderer reuse (`ebdebd5074a`, `86628813a6f`) on a released API:
  verify project classes reload, library cache invalidates on JAR changes,
  resources/configuration reset, inactive timeout/exit, and cross-project
  isolation. Retain cold one-shot mode as the supported fallback.
- [ ] Gate static layoutlib callbacks (`ae7836bf399`, `b5b22b6cdc7`,
  `fd7c02b1b53`) on a released renderer. Verify initial focus/LaunchedEffect,
  animation/Popup settling, exception reporting, and no dispatcher/callback
  state leaking into the next card. Golden PNGs may legitimately change.
- [ ] Verify DeviceSpec parent device state (`2d4dccca121`) and diamond
  MultiPreview wrapper discovery (`9eb8c371bdc`) when the renderer is upgraded.
- [ ] When all gates pass, switch only the renderer adapter. Retain the stable
  project CLI result/error contract and Gradle model preparation.
- [ ] Remove `renderer/ComposePreviewRenderLauncher.java` only after Android,
  KMP, resources, PreviewParameter and partial-failure smoke tests pass.

## Deliberately not part of the initial CLI extraction

- [x] Independent `android-project` Kotlin core/CLI owns Tooling API, GradleBuild,
  AGP V2 basic models and the single Variant API/KGP project collector.
- [x] Both CLIs embed the versioned `android-project-core` library; Preview
  builds use the same JVM, not CLI-to-CLI calls. Project sync has no Preview
  dependency and the project collector has only one source owner.
- [x] Publish/pin core 0.1.0 on GitHub Packages; source builds use authenticated
  registry resolution, with a file repository only as an explicit dev override.
- [x] Share JSON/atomic writes/traversal/stamps/hashing through core IO APIs,
  while preserving independent project/Preview scan and cache policies.
- [x] Publish and verify core 0.1.1 with the shared IO/JSON API.
- [x] Verify cross-repository package read access in Preview CI; the consumer
  builds directly from GitHub Packages with its Actions token.
- [ ] In `android-project`: replace supplemental collection with equivalent AGP
  V2 fields without losing IDs/defaults/components or KMP semantics.
- [ ] In `android-project`: full AGP V2 dependency models, phased sync and
  configuration-aware variant propagation (not inferred from names).
- [ ] Watch/daemon transport with cancellation tokens (the first CLI is one-shot).
- [ ] Cross-project/included-build input tracking beyond the selected project.
- [ ] Full interactive/animation Preview and live canvas resizing.
- [ ] Bound model/launcher cache disk usage. `cache prune` currently handles
  marked run artifacts only; model snapshots are intentionally not auto-deleted.
- [ ] Windows native CI and long-running cancellation stress tests.
