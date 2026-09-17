;;; compose-preview-tests.el --- Tests for compose-preview -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for pure compose-preview helpers.

;;; Code:

(require 'ert)
(require 'android-mode)
(require 'compose-preview)

(ert-deftest compose-preview-module-paths ()
  "Module path helpers convert directory paths to Gradle project paths."
  (let ((project-root "/tmp/project/")
        (module-root "/tmp/project/app/feature/"))
    (should (equal (compose-preview--module-path project-root module-root)
                   ":app:feature"))
    (should (equal (compose-preview--module-name ":app:feature")
                   "app:feature"))
    (should (equal (compose-preview--module-root-from-name project-root "app:feature")
                   "/tmp/project/app/feature/"))))

(ert-deftest compose-preview-current-buffer-class-prefix ()
  "Kotlin source buffers map to generated file facade class names."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/project/app/src/main/java/example/Foo.kt")
    (insert "package com.example.ui\n\nfun Foo() = Unit\n")
    (should (equal (compose-preview--current-buffer-class-prefix)
                   "com.example.ui.FooKt"))))

(ert-deftest compose-preview-current-preview-method ()
  "Current Kotlin position maps to the containing @Preview function."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/project/app/src/main/java/example/Foo.kt")
    (insert "package com.example.ui\n\n"
            "import androidx.compose.ui.tooling.preview.Preview\n\n"
            "@Preview(name = \"Main\")\n"
            "@Composable\n"
            "private fun MainPreview() {\n"
            "  Text(\"Main\")\n"
            "}\n\n"
            "private fun Helper() = Unit\n")
    (goto-char (point-min))
    (search-forward "Text")
    (should (equal (compose-preview--current-preview-method)
                   "MainPreview"))
    (should (equal (compose-preview--current-preview-method-fqn)
                   "com.example.ui.FooKt.MainPreview"))
    (search-forward "Helper")
    (should-not (compose-preview--current-preview-method))))

(ert-deftest compose-preview-current-class-preview-method-fqn ()
  "Class and nested Preview methods map to their exact JVM owners."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/project/example/Foo.kt")
    (insert "package com.example\n"
            "class First {\n"
            "  @Preview\n  fun Card() { Text(\"first\") }\n"
            "}\n"
            "class Second {\n"
            "  class Nested {\n"
            "    @Preview\n    fun Card() { Text(\"nested\") }\n"
            "  }\n}\n")
    (goto-char (point-min))
    (search-forward "Text(\"first\")")
    (should (equal (compose-preview--current-preview-method-fqn)
                   "com.example.First.Card"))
    (search-forward "Text(\"nested\")")
    (should (equal (compose-preview--current-preview-method-fqn)
                   "com.example.Second$Nested.Card"))))

(ert-deftest compose-preview-select-model-previews ()
  "Model previews are narrowed to source functions and the selected method."
  (let* ((source (make-temp-file "Foo" nil ".kt"))
         (source-name (file-name-nondirectory source))
         (previews
          (list
           (list (cons "methodFQN" "com.example.FooKt.First")
                 (cons "sourceFile" source-name))
           (list (cons "methodFQN" "com.example.FooKt.Second")
                 (cons "sourceFile" source-name))
           (list (cons "methodFQN" "com.example.BarKt.First")
                 (cons "sourceFile" "Bar.kt"))
           (list (cons "methodFQN" "com.example.First.First")
                 (cons "sourceFile" source-name))
           (list (cons "methodFQN" "com.example.Second.First")
                 (cons "sourceFile" source-name))
           (list (cons "methodFQN" "com.example.Outer$Nested.First")
                 (cons "sourceFile" source-name))
           (list (cons "methodFQN" "com.other.BazKt.First")
                 (cons "sourceFile" source-name))))
         (model (list (cons "previews" previews))))
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "package com.example\nfun First() {}\nfun Helper() {}\n"))
          (should (equal
                   (mapcar (lambda (preview)
                             (compose-preview--json-get preview "methodFQN"))
                           (compose-preview--select-model-previews
                            model source nil))
                   '("com.example.FooKt.First"
                     "com.example.First.First"
                     "com.example.Second.First"
                     "com.example.Outer$Nested.First")))
          (should (equal
                   (mapcar (lambda (preview)
                             (compose-preview--json-get preview "methodFQN"))
                           (compose-preview--select-model-previews
                            model source "com.example.Second.First"))
                   '("com.example.Second.First")))
          (should-not (compose-preview--select-model-previews
                       model source "Second")))
      (delete-file source))))

(ert-deftest compose-preview-target-prefers-android-mode-source-metadata ()
  "Target lookup follows Android Studio-style module metadata for KMP files."
  (cl-letf (((symbol-function 'compose-preview--find-project-root)
             (lambda () "/tmp/project/"))
            ((symbol-function 'android--target-for-source-file)
             (lambda (_file _project-root)
               (list :module-path ":composeApp"
                     :module-name "composeApp"
                     :module-root "/tmp/project/composeApp"
                     :variant "androidMain"
                     :application-id "com.example"
                     :source-roots '("src/commonMain/kotlin")
                     :preview-task "assembleAndroidMain"))))
    (let ((compose-preview--target-cache nil)
          (buffer-file-name
           "/tmp/project/composeApp/src/commonMain/kotlin/example/Foo.kt"))
      (should
       (equal
        (compose-preview--target)
        (list :project-root "/tmp/project/"
              :module-root "/tmp/project/composeApp/"
              :module-path ":composeApp"
              :variant "androidMain"
              :preview-task "assembleAndroidMain"))))))

(ert-deftest compose-preview-target-refreshes-non-rendering-kmp-metadata ()
  "Stale Android KMP metadata is refreshed before selecting a preview task."
  (let ((refreshed nil))
    (cl-letf (((symbol-function 'compose-preview--find-project-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'android--get-flavors)
               (lambda (&optional refresh)
                 (setq refreshed refresh)))
              ((symbol-function 'android--target-for-source-file)
               (lambda (_file _project-root)
                 (list :module-path ":composeApp"
                       :module-name "composeApp"
                       :module-root "/tmp/project/composeApp"
                       :variant "androidMain"
                       :application-id "com.example"
                       :source-roots '("src/commonMain/kotlin")
                       :preview-task (if refreshed
                                         "desktopTest"
                                       "assembleAndroidMain")))))
      (let ((compose-preview--target-cache nil)
            (compose-preview--metadata-refresh-roots nil)
            (buffer-file-name
             "/tmp/project/composeApp/src/commonMain/kotlin/example/Foo.kt"))
        (should (equal (plist-get (compose-preview--target) :preview-task)
                       "desktopTest"))
        (should refreshed)))))

(ert-deftest compose-preview-target-refreshes-stale-cache-from-android-mode ()
  "Android-mode source metadata should replace stale in-memory targets."
  (cl-letf (((symbol-function 'compose-preview--find-project-root)
             (lambda () "/tmp/project/"))
            ((symbol-function 'android--target-for-source-file)
             (lambda (_file _project-root)
               (list :module-path ":composeApp"
                     :module-name "composeApp"
                     :module-root "/tmp/project/composeApp"
                     :variant "androidMain"
                     :application-id "com.example"
                     :source-roots '("src/commonMain/kotlin")
                     :preview-task "assembleAndroidMain"))))
    (let ((compose-preview--target-cache
           (list (cons "/tmp/project"
                       (list :project-root "/tmp/project/"
                             :module-root "/tmp/project/composeApp/"
                             :module-path ":composeApp"
                             :variant "debug"))))
          (buffer-file-name
           "/tmp/project/composeApp/src/commonMain/kotlin/example/Foo.kt"))
      (should
       (equal
        (compose-preview--target)
        (list :project-root "/tmp/project/"
              :module-root "/tmp/project/composeApp/"
              :module-path ":composeApp"
              :variant "androidMain"
              :preview-task "assembleAndroidMain"))))))

(ert-deftest compose-preview-cached-target-upgrades-to-android-mode-variant ()
  "Cached module targets should use android-mode's real variant metadata."
  (cl-letf (((symbol-function 'compose-preview--find-project-root)
             (lambda () "/tmp/project/"))
            ((symbol-function 'compose-preview--android-flavors-available-p)
             (lambda () t))
            ((symbol-function 'android--get-flavors)
             (lambda (&optional _refresh)
               (list
                (list :module-path ":composeApp"
                      :module-name "composeApp"
                      :module-root "/tmp/project/composeApp"
                      :variant "androidMain"
                      :application-id "com.example"
                      :source-roots '("src/commonMain/kotlin")
                      :preview-task "assembleAndroidMain")))))
    (let ((compose-preview--target-cache
           (list (cons "/tmp/project"
                       (list :project-root "/tmp/project/"
                             :module-root "/tmp/project/composeApp/"
                             :module-path ":composeApp"
                             :variant "debug"))))
          (buffer-file-name nil))
      (should
       (equal
        (compose-preview--target)
        (list :project-root "/tmp/project/"
              :module-root "/tmp/project/composeApp/"
              :module-path ":composeApp"
              :variant "androidMain"
              :preview-task "assembleAndroidMain"))))))

(ert-deftest compose-preview-force-prompt-uses-android-mode-module-root ()
  "Prompted android-mode modules keep their Gradle metadata module root."
  (cl-letf (((symbol-function 'compose-preview--find-project-root)
             (lambda () "/tmp/project/"))
            ((symbol-function 'compose-preview--find-module-root)
             (lambda () "/tmp/project/current/file/module/"))
            ((symbol-function 'compose-preview--android-flavors-available-p)
             (lambda () t))
            ((symbol-function 'android--select-module)
             (lambda () "demo-android"))
            ((symbol-function 'compose-preview--read-variant-for-module)
             (lambda (_module _force-prompt) "debug"))
            ((symbol-function 'android--get-flavors)
             (lambda (&optional _refresh)
               (list
                (list :module-path ":demo-android"
                      :module-name "demo-android"
                      :module-root "/tmp/project/app/demo-android"
                      :variant "debug"
                      :application-id "com.example.demo"
                      :source-roots '("src/main/java")
                      :preview-task "testDebugUnitTest")))))
    (let ((compose-preview--target-cache nil)
          (buffer-file-name "/tmp/project/composeApp/src/commonMain/kotlin/Foo.kt"))
      (should
       (equal
        (compose-preview--target t)
        (list :project-root "/tmp/project/"
              :module-root "/tmp/project/app/demo-android/"
              :module-path ":demo-android"
              :variant "debug"
              :preview-task "testDebugUnitTest"))))))

(ert-deftest compose-preview-render-settings-expands-annotations ()
  "Renderer settings expand annotations and preserve parameter providers."
  (let* ((root (make-temp-file "compose-preview-module" t))
         (target (list :module-root root))
         (model '(("layoutlibPath" . "/layoutlib")
                  ("fontsPath" . "/layoutlib/data/fonts")
                  ("classPath" . ("/classes"))
                  ("projectClassPath" . ("/classes"))
                  ("rClassJars" . ("/R.jar"))
                  ("namespace" . "com.example")
                  ("resourceApkPath" . "/resources.ap_")))
         (previews
          (list
           (list
            (cons "methodFQN" "com.example.FooKt.Preview")
            (cons "previewWrapperFQN" nil)
            (cons "methodParams"
                  (list (list (cons "provider" "com.example.Provider"))))
            (cons "annotations"
                  (list nil (list (cons "name" "Phone"))))))))
    (unwind-protect
        (let* ((render (compose-preview--render-settings model previews target))
               (settings (compose-preview--read-json (plist-get render :settings)))
               (screenshots (compose-preview--json-get settings "screenshots")))
          (should (= (length screenshots) 2))
          (should (equal (compose-preview--json-get settings "rClassJars")
                         '("/R.jar")))
          (should (equal (compose-preview--json-get
                          (car (compose-preview--json-get
                                (car screenshots) "methodParams"))
                          "provider")
                         "com.example.Provider")))
      (delete-directory root t))))

(ert-deftest compose-preview-init-script-configures-layoutlib-model ()
  "Init script collects Studio renderer inputs without snapshot frameworks."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "preview.init.gradle"))
    (let ((script (buffer-string)))
      (should (string-match-p "compose-preview-renderer" script))
      (should (string-match-p "PreviewMethodFinder" script))
      (should (string-match-p "composePreviewModel" script))
      (should (string-match-p "sourceFileForMethod" script))
      (should (string-match-p "composePreviewRegisterKmp" script))
      (should (string-match-p "COMPOSE_PREVIEW_ADAPTER_DIRECTORY" script))
      (should-not (string-match-p "InternalArtifactType" script))
      (should (string-match-p "rClassJars" script))
      (should (string-search "aggregatedRJars + projectDirFiles" script))
      (should (string-match-p "runtime configuration" script))
      (should-not (string-match-p "targetVariant}CompileClasspath" script))
      (should (string-match-p "includeAndroidResources" script))
      (should-not (string-match-p "Paparazzi\\|Roborazzi" script)))))

(ert-deftest compose-preview-kmp-adapter-is-version-gated ()
  "Android KMP internal artifacts stay isolated behind an AGP version gate."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "adapters/agp-9.3-kmp.init.gradle"))
    (let ((adapter (buffer-string)))
      (should (string-match-p "com.android.kotlin.multiplatform.library" adapter))
      (should (string-match-p "ANDROID_GRADLE_PLUGIN_VERSION" adapter))
      (should (string-match-p "9\\\\.3" adapter))
      (should (string-match-p "APK_FOR_LOCAL_TEST" adapter))
      (should (string-match-p "COMPILE_AND_RUNTIME_R_CLASS_JAR" adapter))
      (should (string-match-p "withHostTest" adapter))
      (should (string-match-p "previewPlaceholderDefaults" adapter))
      (should (string-match-p "manifestPlaceholders.putAll" adapter))
      (should (string-match-p "finalizeDsl" adapter))
      (should (string-match-p "setIncludeAndroidResources" adapter))
      (should (string-match-p "isIncludeAndroidResources" adapter))
      (should-not (string-match-p "requires withHostTestBuilder" adapter)))))

(ert-deftest compose-preview-launcher-passes-r-class-jars ()
  "Launcher uses Studio's bootstrapper entry point with R class jars."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "ComposePreviewRenderLauncher.java"))
    (let ((source (buffer-string)))
      (should (string-match-p "RenderEnvironmentBootstrapper" source))
      (should (string-match-p "readStrings(settings, \"rClassJars\")" source))))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "compose-preview.el"))
    (should (string-match-p "layoutlib.thread.profile.timeoutms"
                            (buffer-string)))))

(ert-deftest compose-preview-result-items-preserve-preview-labels ()
  "Renderer results map to panel items and retain multipreview labels."
  (let* ((results '((("methodFQN" . "com.example.FooKt.CardPreview")
                     ("previewId" . "com.example.FooKt.CardPreview_Phone")
                     ("imagePath" . "phone.png"))))
         (items (compose-preview--result-items results "/tmp/rendered/"))
         (item (car items)))
    (should (equal (compose-preview-item-name item) "CardPreview - Phone"))
    (should (equal (compose-preview-item-files item)
                   '("/tmp/rendered/phone.png")))))

(ert-deftest compose-preview-stale-render-sentinel-is-ignored ()
  "A superseded renderer process cannot replace current panel results."
  (let ((compose-preview--generation 2)
        finished)
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'exit))
              ((symbol-function 'process-get)
               (lambda (_process _property) '(:generation 1)))
              ((symbol-function 'compose-preview--finish-render)
               (lambda (_context) (setq finished t))))
      (compose-preview--render-sentinel 'process "finished\n")
      (should-not finished))))

(ert-deftest compose-preview-auto-refresh-uses-source-buffer ()
  "Debounced refresh runs in its original source buffer."
  (let ((source (generate-new-buffer " *compose-preview-source*"))
        refreshed all-in-file)
    (unwind-protect
        (with-current-buffer source
          (compose-preview-auto-refresh-mode 1)
          (cl-letf (((symbol-function 'compose-preview-refresh)
                     (lambda (&optional _variant)
                       (setq refreshed (current-buffer)
                             all-in-file compose-preview--refresh-all-in-file))))
            (compose-preview--auto-refresh-buffer source))
          (should (eq refreshed source))
          (should all-in-file))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest compose-preview-failure-normalizes-package-prefix ()
  "Panel failures do not repeat an existing compose-preview prefix."
  (let (status logged)
    (cl-letf (((symbol-function 'compose-preview--panel-status)
               (lambda (_source _root message &optional _face)
                 (setq status message)))
              ((symbol-function 'compose-preview--log)
               (lambda (_format message) (setq logged message))))
      (compose-preview--fail
       '(:target (:module-root "/tmp/")) "%s"
       "compose-preview: Android KMP failed")
      (should (equal status "failed — Android KMP failed"))
      (should (equal logged "Android KMP failed")))))

(ert-deftest compose-preview-gradle-failure-prefers-specific-diagnostic ()
  "Gradle failures surface compose-preview diagnostics in the panel."
  (with-temp-buffer
    (insert "* What went wrong:\n"
            "> compose-preview: Android KMP resources are unavailable\n")
    (should (equal
             (compose-preview--gradle-failure-message
              (list :log-buffer (current-buffer)) 1)
             "compose-preview: Android KMP resources are unavailable"))))

(ert-deftest compose-preview-launcher-compilation-is-asynchronous ()
  "A stale launcher cache starts javac without blocking Emacs."
  (let ((context '(:generation 1
                   :target (:project-root "/tmp/" :module-root "/tmp/")
                   :source-buffer nil
                   :launcher (:javac "/jdk/bin/javac"
                              :classpath "/renderer.jar"
                              :directory "/tmp/launcher/"
                              :source "/package/Launcher.java")
                   :log-buffer nil))
        command sentinel)
      (with-temp-buffer
        (setf (plist-get context :log-buffer) (current-buffer))
        (cl-letf (((symbol-function 'make-directory) #'ignore)
                  ((symbol-function 'make-process)
                   (lambda (&rest args)
                     (setq command (plist-get args :command))
                     'javac-process))
                  ((symbol-function 'process-put) #'ignore)
                  ((symbol-function 'set-process-sentinel)
                   (lambda (_process function) (setq sentinel function)))
                  ((symbol-function 'compose-preview--panel-status) #'ignore))
          (compose-preview--compile-launcher context)))
      (should (equal (car command) "/jdk/bin/javac"))
      (should (equal (seq-take (cdr command) 3)
                     '("-nowarn" "--release" "17")))
      (should (eq sentinel #'compose-preview--launcher-sentinel))))

(provide 'compose-preview-tests)

;;; compose-preview-tests.el ends here
