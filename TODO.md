# Backend follow-ups

## Replace the custom launcher with the official standalone renderer CLI

- [ ] Track Google Maven `com.android.tools.compose:compose-preview-renderer`
  releases. The current pin is `0.0.1-alpha17`; Studio main is not a released
  binary. Alpha17 passed Android (21 results), independent AGP 9.3 KMP resources,
  callback settling and mixed healthy/failing-card probes on Java 21 with
  layoutlib 17.0.4 (the initial alpha17 adoption used Java 17/layoutlib 16.1). The public
  refreshClassPath API is called per top-level screenshot to isolate project
  compositions/dispatcher state. The earlier missing-class probe now reports an
  error after a healthy card. This does not enable warm/tree/inflate features.
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
  isolation. Include the newer warm-cache and render-thread timeout fixes
  (`6c2436fb8e7`, `68300ba144b`, `2c49d27833f`). Retain cold one-shot mode as
  the supported fallback.
- [x] Adopt alpha17 static callbacks with a settled LaunchedEffect pixel check,
  project classpath refresh per top-level screenshot and failing/healthy-card
  isolation. Golden PNGs may legitimately change.
- [ ] Expand callback coverage for focus, animation/Popup settling, timeout and
  arbitrary unscoped coroutine work. Do not promise asynchronous data settling.
- [ ] Include the FastServiceLoader dispatcher-factory fix (`26d2ab5f21d`) in
  the released-renderer gate. Verify coroutines 1.8.x and 1.9+ factories on both
  dependency and project classpaths. Alpha17 is now published; verify the
  behavior in that binary rather than backporting classloader patches.
- [ ] Include interrupted ZIP-resource reads (`630123516ff`) in callback timeout
  tests: bounded retries, restored interrupt state and healthy sibling previews.
  A newer layoutlib alone does not supply renderer/resource-reader fixes.
- [ ] Verify DeviceSpec parent device state (`2d4dccca121`) and diamond
  MultiPreview wrapper discovery (`9eb8c371bdc`) when the renderer is upgraded.
- [ ] When all gates pass, switch only the renderer adapter. Retain the stable
  project CLI result/error contract and Gradle model preparation.
- [ ] Remove `renderer/ComposePreviewRenderLauncher.java` only after Android,
  KMP, resources, PreviewParameter and partial-failure smoke tests pass.

## KMP resource preparation

- [x] Enable Android resources on an existing host compilation only during the
  Preview invocation, retaining user source sets and other host-test options.
  A real AGP 9.3 fixture with resources explicitly false rendered a resource PNG;
  configuration cache was reused and a subsequent ordinary build still saw false.
- [ ] Replace host-test resource artifact collection only after a released
  alternative covers KMP resources/R classes. Studio editor resource repositories
  and standalone runfiles are distinct paths; current upstream runfiles also
  borrows unit-test resource packaging.

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
- [x] Preserve sync/build/module/variant/component identity through Preview
  requests, compiled receipts and results; track the entry and owning build inputs.
- [x] Protect entry/owning roots plus graph roots and all discovered builds,
  including convention/plugin inputs. Arbitrary undiscovered external inputs
  remain outside this guarantee.
- [ ] Component-specific rendering for androidTest/unitTest/screenshotTest and
  other tests; currently reject these instead of silently using main artifacts.
- [ ] Full interactive/animation Preview and live canvas resizing.
- [ ] Bound model/launcher cache disk usage. `cache prune` currently handles
  marked run artifacts only; model snapshots are intentionally not auto-deleted.
- [x] Native Windows distribution and Scoop install/launcher/doctor CI.
- [ ] Real Linux/Windows rendering and long-running cancellation stress tests.
