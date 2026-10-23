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

- [ ] Gradle Tooling API + AGP V2 project/variant dependency model.
- [ ] Watch/daemon transport with cancellation tokens (the first CLI is one-shot).
- [ ] Cross-project/included-build input tracking beyond the selected project.
- [ ] Full interactive/animation Preview and live canvas resizing.
- [ ] Bound model/launcher cache disk usage. `cache prune` currently handles
  marked run artifacts only; model snapshots are intentionally not auto-deleted.
- [ ] Windows native CI and long-running cancellation stress tests.
