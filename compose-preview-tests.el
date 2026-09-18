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

(ert-deftest compose-preview-model-files-separate-gradle-cache-and-render-snapshots ()
  "Gradle model paths stay stable while renderer snapshots remain isolated."
  (let ((target '(:module-root "/tmp/project/app/" :variant "androidMain")))
    (should (equal (compose-preview--model-file target)
                   "/tmp/project/app/build/compose-preview/emacs/model-androidMain.json"))
    (should (equal (compose-preview--model-file target 7)
                   "/tmp/project/app/build/compose-preview/emacs/model-androidMain-7.json"))))

(ert-deftest compose-preview-successful-gradle-snapshots-model-before-rendering ()
  "A successful active Gradle process snapshots its stable model."
  (let ((compose-preview--generation 3)
        events)
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_process) 0))
              ((symbol-function 'process-get)
               (lambda (_process _property) '(:generation 3)))
              ((symbol-function 'compose-preview--snapshot-model)
               (lambda (_context) (push 'snapshot events)))
              ((symbol-function 'compose-preview--start-render)
               (lambda (_context) (push 'render events))))
      (compose-preview--gradle-sentinel 'process "finished\n")
      (should (equal (nreverse events) '(snapshot render))))))

(ert-deftest compose-preview-current-buffer-class-prefix ()
  "Kotlin source buffers map to generated file facade class names."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/project/app/src/main/java/example/Foo.kt")
    (insert "package com.example.ui\n\nfun Foo() = Unit\n")
    (should (equal (compose-preview--current-buffer-class-prefix)
                   "com.example.ui.FooKt"))))

(ert-deftest compose-preview-source-file-scanners-do-not-prompt-on-temp-kill ()
  "Temporary Kotlin scans must not ask to kill a modified file buffer."
  (let ((file (make-temp-file "compose-preview" nil ".kt")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "package com.example\nclass Card\nfun Preview() {}\n"))
          (cl-letf (((symbol-function 'read-multiple-choice)
                     (lambda (&rest _) (error "kill prompt"))))
            (should (equal (compose-preview--source-file-class-prefix file)
                           (concat "com.example." (file-name-base file) "Kt")))
            (should (member "com.example.Card"
                            (compose-preview--source-declaring-prefixes file)))))
      (delete-file file))))

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
            (cons "parameterNames" (list "user"))
            (cons "annotations"
                  (list nil (list (cons "name" "Phone")
                                  (cons "group" "Devices"))))))))
    (unwind-protect
        (let* ((render (compose-preview--render-settings model previews target))
               (settings (compose-preview--read-json (plist-get render :settings)))
               (screenshots (compose-preview--json-get settings "screenshots"))
               (metadata (plist-get render :metadata))
               (phone-id "com.example.FooKt.Preview_Phone"))
          (should (= (length screenshots) 2))
          (should (equal (compose-preview--json-get settings "rClassJars")
                         '("/R.jar")))
          (should (equal (plist-get (gethash phone-id metadata) :group)
                         "Devices"))
          (should (equal (plist-get (gethash phone-id metadata) :preview-name)
                         "Phone"))
          (should (equal (plist-get (gethash phone-id metadata) :parameter-name)
                         "user"))
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
      (should (string-match-p "parameterNames" script))
      (should (string-match-p "previewParameterNames" script))
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
      (should (string-match-p "readStrings(settings, \"rClassJars\")" source))
      (should (string-match-p "displayName" source))
      (should (string-match-p "instanceId" source))))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "compose-preview.el"))
    (should (string-match-p "layoutlib.thread.profile.timeoutms"
                            (buffer-string)))))

(ert-deftest compose-preview-sections-group-the-same-preview-method ()
  "Grid sections follow Studio organization groups by composable method."
  (let* ((phone (make-compose-preview-item
                 :name "Phone" :method "CardPreview"
                 :method-fqn "example.CardPreview" :group "Devices"))
         (tablet (make-compose-preview-item
                  :name "Tablet" :method "CardPreview"
                  :method-fqn "example.CardPreview" :group "Tablets"))
         (other (make-compose-preview-item
                 :name "Plain" :method "OtherPreview"
                 :method-fqn "example.OtherPreview"))
         (groups (compose-preview--group-items (list phone other tablet))))
    (should (equal (mapcar #'car groups)
                   '("example.CardPreview" "example.OtherPreview")))
    (should (equal (mapcar #'compose-preview-item-name
                           (cdr (assoc "example.CardPreview" groups)))
                   '("Phone" "Tablet")))
    (should (equal (compose-preview--section-title phone) "CardPreview"))))

(ert-deftest compose-preview-panel-filters-compose-name-and-group ()
  "Text and group filters compose without changing the result model."
  (with-temp-buffer
    (compose-preview-results-mode)
    (setq-local compose-preview--items
                (list (make-compose-preview-item
                       :name "Phone Card" :method-fqn "example.Phone"
                       :group "Devices")
                      (make-compose-preview-item
                       :name "Tablet Card" :method-fqn "example.Tablet"
                       :group "Devices")
                      (make-compose-preview-item
                       :name "Phone Dark" :method-fqn "example.Dark"
                       :group "Themes"))
                compose-preview--search-query "PHONE"
                compose-preview--group-filter "Devices")
    (should (equal (mapcar #'compose-preview-item-name
                           (compose-preview--visible-items))
                   '("Phone Card")))))

(ert-deftest compose-preview-focus-navigation-wraps-filtered-items ()
  "Focus navigation cycles through only currently visible items."
  (with-temp-buffer
    (compose-preview-results-mode)
    (setq-local compose-preview--items
                (list (make-compose-preview-item :id "one" :name "One")
                      (make-compose-preview-item :id "two" :name "Two"))
                compose-preview--module-root "/tmp/"
                compose-preview--view-mode 'focus
                compose-preview--focus-id "two")
    (cl-letf (((symbol-function 'compose-preview--redraw) #'ignore))
      (compose-preview-next)
      (should (eq compose-preview--view-mode 'focus))
      (should (equal compose-preview--focus-id "one"))
      (compose-preview-previous)
      (should (equal compose-preview--focus-id "two")))))

(ert-deftest compose-preview-grid-navigation-visits-section-headings ()
  "Grid n/p visit Magit-style section headings then visible cards."
  (with-temp-buffer
    (compose-preview-results-mode)
    (let ((one (make-compose-preview-item
                :id "one" :name "Card - One" :method "Card"
                :method-fqn "ex.Card" :preview-name "One"))
          (two (make-compose-preview-item
                :id "two" :name "Card - Two" :method "Card"
                :method-fqn "ex.Card" :preview-name "Two"))
          (inhibit-read-only t))
      (setq-local compose-preview--items (list one two)
                  compose-preview--module-root "/tmp/"
                  compose-preview--view-mode 'grid)
      (cl-letf (((symbol-function 'compose-preview--insert-image)
                 (lambda (&rest _args) (insert "[image]"))))
        (insert "Compose Preview\n\n")
        (compose-preview--insert-group "ex.Card" (list one two)))
      (goto-char (point-min))
      (compose-preview-next)
      (should (eq compose-preview--view-mode 'grid))
      (should (equal (compose-preview--group-at-point) "ex.Card"))
      (should (get-text-property (point) 'compose-preview-group))
      (compose-preview-next)
      (should (equal (compose-preview-item-id (compose-preview--current-item))
                     "one"))
      (compose-preview-next)
      (should (equal (compose-preview-item-id (compose-preview--current-item))
                     "two"))
      (should (= (point) (compose-preview--item-title-position two)))
      (should-error (compose-preview-next))
      (compose-preview-previous)
      (should (equal (compose-preview-item-id (compose-preview--current-item))
                     "one"))
      (compose-preview-previous)
      (should (get-text-property (point) 'compose-preview-group))
      (compose-preview-toggle-group)
      (should (gethash "ex.Card" compose-preview--collapsed-groups)))))

(ert-deftest compose-preview-scale-commands-update-panel-state ()
  "Fit, original size, and zoom commands update scale without rendering."
  (with-temp-buffer
    (compose-preview-results-mode)
    (cl-letf (((symbol-function 'compose-preview--redraw) #'ignore))
      (compose-preview-original-size)
      (should-not compose-preview--fit-images)
      (should (= compose-preview--image-zoom 1.0))
      (compose-preview-zoom-in)
      (should (= compose-preview--image-zoom 1.25))
      (compose-preview-zoom-out)
      (should (= compose-preview--image-zoom 1.0))
      (compose-preview-fit)
      (should compose-preview--fit-images)))
  (should (eq (lookup-key compose-preview-results-mode-map (kbd "0"))
              #'compose-preview-original-size))
  (should-not (eq (lookup-key compose-preview-results-mode-map (kbd "1"))
                  #'compose-preview-original-size)))

(ert-deftest compose-preview-key-hints-can-be-hidden ()
  "Keybinding hints are shown by default and can be disabled."
  (with-temp-buffer
    (compose-preview-results-mode)
    (setq-local compose-preview--items
                (list (make-compose-preview-item
                       :name "Phone" :method "Phone" :method-fqn "ex.Phone"))
                compose-preview--status "ready"
                compose-preview--module-root "/tmp/")
    (cl-letf (((symbol-function 'compose-preview--insert-image) #'ignore))
      (let ((compose-preview-show-key-hints t))
        (compose-preview--redraw)
        (should (string-match-p "TAB fold" (buffer-string))))
      (let ((compose-preview-show-key-hints nil))
        (compose-preview--redraw)
        (should-not (string-match-p "TAB fold" (buffer-string)))))))

(ert-deftest compose-preview-actual-size-follows-density-and-host-scale ()
  "Actual size maps renderer pixels to Studio surface coordinates."
  (cl-letf (((symbol-function 'compose-preview--image-width)
             (lambda (_image) 1080))
            ((symbol-function 'compose-preview--frame-scale-factor)
             (lambda () 2.0)))
    (should (= (compose-preview--actual-image-width 'image 480) 180))
    (should (= (compose-preview--actual-image-width 'image nil) 1080))))

(ert-deftest compose-preview-image-spec-uses-shared-fit-scale ()
  "Fit mode applies one Studio-style scale and may enlarge images."
  (let ((compose-preview--fit-images t)
        (compose-preview--fit-scale 2.0)
        created-widths)
    (cl-letf (((symbol-function 'create-image)
               (lambda (_file _type _data-p &rest properties)
                 (push (plist-get properties :width) created-widths)
                 'image))
              ((symbol-function 'compose-preview--actual-image-width)
               (lambda (_image _density) 180)))
      (compose-preview--image-spec "phone.png" 480)
      (should (equal created-widths '(360 nil))))))

(ert-deftest compose-preview-fit-scale-respects-layout-width-and-height ()
  "Zoom to Fit finds one scale bounded by both surface dimensions."
  (cl-letf (((symbol-function 'compose-preview--available-size)
             (lambda () '(320 . 240)))
            ((symbol-function 'compose-preview--fit-layout-size)
             (lambda (_items scale) (cons (* 200 scale) (* 300 scale)))))
    (let ((scale (compose-preview--fit-scale-for-items '(preview))))
      (should (< (abs (- scale 0.8)) 0.001)))))

(ert-deftest compose-preview-group-sections-toggle-visibility ()
  "Group headers hide and reveal their Preview body without rebuilding it."
  (with-temp-buffer
    (compose-preview-results-mode)
    (let ((inhibit-read-only t))
      (cl-letf (((symbol-function 'compose-preview--insert-image)
                 (lambda (&rest _args) (insert "[image]"))))
        (compose-preview--insert-group
         "Devices"
         (list (make-compose-preview-item :name "Phone" :files '("phone.png"))))))
    (goto-char (point-min))
    (should (equal (compose-preview--group-at-point) "Devices"))
    (should (eq (lookup-key (get-char-property (point) 'keymap) [tab])
                #'compose-preview-toggle-group))
    (let ((header (gethash "Devices" compose-preview--group-header-overlays)))
      (should (overlay-get header 'before-string)))
    (search-forward "Phone")
    (should (equal (compose-preview--group-at-point) "Devices"))
    (compose-preview-toggle-group)
    (should (gethash "Devices" compose-preview--collapsed-groups))
    (should (overlay-get (gethash "Devices" compose-preview--group-header-overlays)
                         'before-string))
    (should (get-text-property (point) 'compose-preview-group))
    (should (seq-some (lambda (overlay) (overlay-get overlay 'invisible))
                      (overlays-in (point-min) (point-max))))
    (compose-preview-toggle-group "Devices")
    (should-not (gethash "Devices" compose-preview--collapsed-groups))
    (should-not (seq-some (lambda (overlay) (overlay-get overlay 'invisible))
                          (overlays-in (point-min) (point-max))))))

(ert-deftest compose-preview-render-results-restores-status-and-validates-group ()
  "Rendering restores issue status and clears a stale group filter."
  (let ((items (list (make-compose-preview-item
                      :id "broken" :name "Broken" :group "Current"
                      :error '(("message" . "boom"))))))
    (unwind-protect
        (cl-letf (((symbol-function 'compose-preview--insert-image) #'ignore)
                  ((symbol-function 'compose-preview--display-panel) #'ignore))
          (with-current-buffer (get-buffer-create compose-preview-results-buffer-name)
            (compose-preview-results-mode)
            (setq compose-preview--group-filter "Previous"))
          (compose-preview--render-results "/tmp/" nil items nil)
          (with-current-buffer compose-preview-results-buffer-name
            (should-not compose-preview--group-filter)
            (should (= (point) (point-min)))
            (should (string-match-p
                     "1 issue" (substring-no-properties header-line-format)))))
      (when-let* ((buffer (get-buffer compose-preview-results-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest compose-preview-render-results-preserves-fold-state ()
  "Refreshing the panel preserves collapsed Preview groups."
  (let ((items (list (make-compose-preview-item
                      :name "Phone" :method "CardPreview"
                      :method-fqn "example.CardPreview" :group "Devices"
                      :files '("phone.png")))))
    (unwind-protect
        (cl-letf (((symbol-function 'compose-preview--insert-image)
                   (lambda (&rest _args) (insert "[image]")))
                  ((symbol-function 'compose-preview--display-panel) #'ignore))
          (compose-preview--render-results "/tmp/" nil items nil)
          (with-current-buffer compose-preview-results-buffer-name
            (compose-preview-toggle-group "example.CardPreview")
            (setq compose-preview--view-mode 'focus)
            (should (gethash "example.CardPreview" compose-preview--collapsed-groups)))
          (compose-preview--render-results "/tmp/" nil items nil)
          (with-current-buffer compose-preview-results-buffer-name
            (should (eq compose-preview--view-mode 'focus))
            (should (gethash "example.CardPreview" compose-preview--collapsed-groups))
            (setq compose-preview--view-mode 'grid)
            (compose-preview--redraw)
            (should (eq (overlay-get
                         (gethash "example.CardPreview" compose-preview--group-overlays)
                         'invisible)
                        'compose-preview-fold))))
      (when-let* ((buffer (get-buffer compose-preview-results-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest compose-preview-result-items-preserve-preview-labels ()
  "Renderer results map to panel items and retain multipreview labels."
  (let* ((id "com.example.FooKt.CardPreview_Phone")
         (metadata (make-hash-table :test #'equal))
         (results `((("methodFQN" . "com.example.FooKt.CardPreview")
                     ("previewId" . ,id)
                     ("imagePath" . "phone.png")
                     ("densityDpi" . 480))))
         (_ (puthash id '(:preview-name "Phone" :group "Devices"
                          :source-file "Foo.kt") metadata))
         (items (compose-preview--result-items results "/tmp/rendered/" metadata))
         (item (car items)))
    (should (equal (compose-preview-item-name item) "CardPreview - Phone"))
    (should (equal (compose-preview--card-title item) "Phone"))
    (should (equal (compose-preview-item-preview-name item) "Phone"))
    (should (equal (compose-preview-item-group item) "Devices"))
    (should (equal (compose-preview-item-source-file item) "Foo.kt"))
    (should (= (compose-preview-item-density-dpi item) 480))
    (should (equal (compose-preview-item-files item)
                   '("/tmp/rendered/phone.png")))))

(ert-deftest compose-preview-result-items-expand-parameterized-previews ()
  "Each @PreviewParameter value becomes a uniquely identified Grid item."
  (let* ((id "com.example.FooKt.LoginPreview_Login")
         (metadata (make-hash-table :test #'equal))
         (results `((("methodFQN" . "com.example.FooKt.LoginPreview")
                     ("previewId" . ,id)
                     ("imagePath" . "a.png")
                     ("parameterIndex" . 0)
                     ("parameterCount" . 2)
                     ("instanceId" . "com.example.FooKt.LoginPreview#param00")
                     ("displayName" . "LoginPreview - Login (param0 0)")
                     ("parameterName" . "param0 0"))
                    (("methodFQN" . "com.example.FooKt.LoginPreview")
                     ("previewId" . ,id)
                     ("imagePath" . "b.png")
                     ("parameterIndex" . 1)
                     ("parameterCount" . 2)
                     ("instanceId" . "com.example.FooKt.LoginPreview#param01")
                     ("displayName" . "LoginPreview - Login (param0 1)")
                     ("parameterName" . "param0 1"))))
         (_ (puthash id '(:preview-name "Login" :group "Auth"
                          :source-file "Foo.kt" :parameter-name "user")
                     metadata))
         (items (compose-preview--result-items results "/tmp/rendered/" metadata)))
    (should (equal (mapcar #'compose-preview-item-id items)
                   '("com.example.FooKt.LoginPreview_Login#com.example.FooKt.LoginPreview#param00"
                     "com.example.FooKt.LoginPreview_Login#com.example.FooKt.LoginPreview#param01")))
    (should (equal (mapcar #'compose-preview-item-name items)
                   '("LoginPreview - Login (user 0)"
                     "LoginPreview - Login (user 1)")))
    (should (equal (mapcar #'compose-preview--card-title items)
                   '("Login - user 0" "Login - user 1")))
    (should (equal (compose-preview-item-parameter-name (car items)) "user"))
    (should (equal (compose-preview-item-group (car items)) "Auth"))
    (should (= (compose-preview-item-parameter-index (cadr items)) 1))
    (should (equal (mapcar #'car (compose-preview--group-items items))
                   '("com.example.FooKt.LoginPreview")))))

(ert-deftest compose-preview-grid-gap-matches-studio-dynamic-padding ()
  "Grid card spacing follows Studio's scale-responsive padding."
  (should (= (compose-preview--grid-gap 0.1) 5))
  (should (= (compose-preview--grid-gap 0.2) 5))
  (should (= (compose-preview--grid-gap 0.8) 12))
  (should (= (compose-preview--grid-gap 1.0) 15))
  (should (= (compose-preview--grid-gap 2.0) 15)))

(ert-deftest compose-preview-grid-rows-wrap-to-available-width ()
  "Grid rows wrap when the next Preview would exceed the panel width."
  (cl-letf (((symbol-function 'compose-preview--fit-width) (lambda () 250))
            ((symbol-function 'compose-preview--grid-entry)
             (lambda (preview)
               (list :item preview :file nil :image nil :width 100))))
    (should (equal
             (mapcar (lambda (row)
                       (mapcar (lambda (entry)
                                 (compose-preview-item-name
                                  (plist-get entry :item)))
                               row))
                     (compose-preview--grid-rows
                      (list (make-compose-preview-item :name "A")
                            (make-compose-preview-item :name "B")
                            (make-compose-preview-item :name "C"))))
             '(("A" "B") ("C"))))))

(ert-deftest compose-preview-result-items-preserve-render-issues ()
  "Renderer issues stay attached to their individual Preview item."
  (let* ((error '(("status" . "ERROR_RENDER_TASK")
                  ("message" . "Could not inflate ComposeViewAdapter")))
         (results `((("methodFQN" . "com.example.FooKt.Broken")
                     ("previewId" . "com.example.FooKt.Broken_0")
                     ("imagePath" . "broken.png")
                     ("error" . ,error))))
         (item (car (compose-preview--result-items results "/tmp/"))))
    (should (equal (compose-preview-item-method-fqn item)
                   "com.example.FooKt.Broken"))
    (should (equal (compose-preview-item-error item) error))))

(ert-deftest compose-preview-insert-preview-shows-image-and-issue ()
  "A Preview can display its image and renderer issue together."
  (with-temp-buffer
    (cl-letf (((symbol-function 'file-readable-p) (lambda (_file) t))
              ((symbol-function 'compose-preview--insert-image)
               (lambda (&rest _args) (insert "[image]"))))
      (compose-preview--insert-preview
       (make-compose-preview-item
        :name "Broken" :files '("broken.png")
        :error '(("message" . "Missing dependency")))))
    (should (string-match-p "\\[image\\]" (buffer-string)))
    (should (string-match-p "Issue: Missing dependency" (buffer-string)))))

(ert-deftest compose-preview-copy-image-uses-current-card-png ()
  "Copy image sends the current card's first readable PNG to clipboard."
  (let ((file (make-temp-file "compose-preview-copy-" nil ".png")) copied)
    (unwind-protect
        (with-temp-buffer
          (let ((item (make-compose-preview-item :name "Phone" :files (list file))))
            (insert (propertize "preview" 'compose-preview-item item))
            (goto-char (point-min))
            (cl-letf (((symbol-function 'compose-preview--copy-png-to-clipboard)
                       (lambda (image) (setq copied image)))
                      ((symbol-function 'message) #'ignore))
              (compose-preview-copy-image))
            (should (equal copied file))))
      (delete-file file))))

(ert-deftest compose-preview-copy-image-requires-card-at-point ()
  "Copy image reports when point is not on a Preview card."
  (with-temp-buffer
    (should-error (compose-preview-copy-image) :type 'user-error)))

(ert-deftest compose-preview-png-clipboard-method-follows-platform ()
  "PNG clipboard backend selection follows the current desktop."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (program)
               (member program '("osascript" "wl-copy" "xclip" "powershell.exe")))))
    (let ((system-type 'darwin))
      (should (eq (compose-preview--png-clipboard-method) 'osascript)))
    (let ((system-type 'windows-nt))
      (should (eq (compose-preview--png-clipboard-method) 'powershell)))
    (let ((system-type 'gnu/linux)
          (process-environment (cons "WAYLAND_DISPLAY=wayland-0"
                                     process-environment)))
      (should (eq (compose-preview--png-clipboard-method) 'wl-copy)))
    (let ((system-type 'gnu/linux)
          (process-environment
           (cons "WAYLAND_DISPLAY="
                 (seq-remove (lambda (entry)
                               (string-prefix-p "WAYLAND_DISPLAY=" entry))
                             process-environment))))
      (should (eq (compose-preview--png-clipboard-method) 'xclip)))))

(ert-deftest compose-preview-goto-preview-method-selects-exact-owner ()
  "Source navigation disambiguates methods with identical names."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/Foo.kt")
    (insert "package com.example\nclass First {\n  @Preview\n  fun Card() {}\n}\n"
            "class Second {\n  @Preview\n  fun Card() {}\n}\n")
    (should (compose-preview--goto-preview-method
             (make-compose-preview-item
              :method "Card" :method-fqn "com.example.Second.Card")))
    (should (looking-at-p "fun Card"))
    (should (save-excursion (re-search-backward "class Second" nil t)))))

(ert-deftest compose-preview-finish-render-keeps-partial-results ()
  "Individual render failures do not discard successful Preview results."
  (let* ((results-file (make-temp-file "compose-preview-results" nil ".json"))
         (compose-preview--last-result-items nil)
         rendered)
    (unwind-protect
        (progn
          (with-temp-file results-file
            (insert "{\"screenshotResults\":["
                    "{\"methodFQN\":\"com.example.FooKt.Good\","
                    "\"previewId\":\"com.example.FooKt.Good_0\","
                    "\"imagePath\":\"good.png\"},"
                    "{\"methodFQN\":\"com.example.FooKt.Bad\","
                    "\"previewId\":\"com.example.FooKt.Bad_0\","
                    "\"error\":{\"message\":\"boom\"}}]}"))
          (with-current-buffer (get-buffer-create compose-preview-results-buffer-name)
            (compose-preview-results-mode))
          (cl-letf (((symbol-function 'compose-preview--render-results)
                     (lambda (_root _images items _source)
                       (setq rendered items)))
                    ((symbol-function 'compose-preview--log) #'ignore))
            (compose-preview--finish-render
             `(:target (:module-root "/tmp/")
               :render (:results ,results-file :output "/tmp/"))))
          (should (= (length rendered) 2))
          (should-not (compose-preview-item-error (car rendered)))
          (should (compose-preview-item-error (cadr rendered))))
      (delete-file results-file)
      (when-let* ((buffer (get-buffer compose-preview-results-buffer-name)))
        (kill-buffer buffer)))))

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

(ert-deftest compose-preview-disabled-file-following-installs-no-hook ()
  "Disabling file following avoids installing the command hook."
  (let ((compose-preview-follow-current-file nil)
        (compose-preview--follow-active nil)
        installed)
    (cl-letf (((symbol-function 'add-hook) (lambda (&rest _) (setq installed t))))
      (compose-preview--start-following 'source)
      (should-not installed)
      (should-not compose-preview--follow-active))))

(ert-deftest compose-preview-following-schedules-selected-kotlin-buffer ()
  "An active Preview session refreshes the newly selected Kotlin file."
  (let ((source (generate-new-buffer " *compose-preview-follow-source*"))
        (compose-preview--follow-active t)
        (compose-preview-follow-current-file t)
        scheduled cancelled)
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local buffer-file-name "/tmp/Next.kt"))
          (cl-letf (((symbol-function 'selected-window) (lambda () 'window))
                    ((symbol-function 'window-buffer) (lambda (_window) source))
                    ((symbol-function 'compose-preview--cancel-process)
                     (lambda () (setq cancelled t)))
                    ((symbol-function 'run-with-timer)
                     (lambda (_delay _repeat function buffer)
                       (setq scheduled (list function buffer))
                       'timer)))
            (compose-preview--follow-selected-buffer))
          (should cancelled)
          (should (equal scheduled
                         (list #'compose-preview--follow-refresh-buffer source))))
      (kill-buffer source))))

(ert-deftest compose-preview-following-hides-files-without-previews ()
  "Following a Kotlin file without Preview declarations hides the panel."
  (let (hidden failed)
    (cl-letf (((symbol-function 'compose-preview--read-json)
               (lambda (_file) '(("previews"))))
              ((symbol-function 'compose-preview--select-model-previews)
               (lambda (&rest _) nil))
              ((symbol-function 'compose-preview--hide-panel)
               (lambda () (setq hidden t)))
              ((symbol-function 'compose-preview--fail)
               (lambda (&rest _) (setq failed t)))
              ((symbol-function 'compose-preview--log) #'ignore))
      (compose-preview--start-render
       '(:model-file "/tmp/model.json"
         :source-file "/tmp/Plain.kt"
         :follow-refresh t
         :target (:module-path ":app")))
      (should hidden)
      (should-not failed))))

(ert-deftest compose-preview-hide-panel-preserves-selected-window ()
  "Background panel hiding never steals focus from a newly opened window."
  (let ((preview (generate-new-buffer " *compose-preview-hide-panel*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((selected (selected-window))
                (preview-window (split-window-right)))
            (set-window-buffer preview-window preview)
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _) preview-window))
                      ((symbol-function 'quit-window)
                       (lambda (&rest _) (select-window preview-window))))
              (compose-preview--hide-panel))
            (should (eq (selected-window) selected))))
      (kill-buffer preview))))

(ert-deftest compose-preview-following-hides-panel-for-non-kotlin-buffer ()
  "An active Preview session closes its panel outside Kotlin files."
  (let ((other (generate-new-buffer " *compose-preview-follow-other*"))
        (compose-preview--follow-active t)
        (compose-preview-follow-current-file t)
        cancelled hidden)
    (unwind-protect
        (cl-letf (((symbol-function 'selected-window) (lambda () 'window))
                  ((symbol-function 'window-buffer) (lambda (_window) other))
                  ((symbol-function 'compose-preview--cancel-process)
                   (lambda () (setq cancelled t)))
                  ((symbol-function 'compose-preview--hide-panel)
                   (lambda () (setq hidden t))))
          (compose-preview--follow-selected-buffer)
          (should cancelled)
          (should hidden))
      (kill-buffer other))))

(ert-deftest compose-preview-panel-quit-stops-file-following ()
  "Manually closing Preview stops automatic file following."
  (let ((compose-preview--follow-active t)
        (compose-preview--follow-buffer 'source)
        cancelled quit)
    (cl-letf (((symbol-function 'compose-preview--cancel-follow-timer) #'ignore)
              ((symbol-function 'compose-preview--cancel-process)
               (lambda () (setq cancelled t)))
              ((symbol-function 'remove-hook) #'ignore)
              ((symbol-function 'quit-window) (lambda (&rest _) (setq quit t))))
      (compose-preview-panel-quit)
      (should-not compose-preview--follow-active)
      (should-not compose-preview--follow-buffer)
      (should cancelled)
      (should quit))))

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

(ert-deftest compose-preview-gradle-arguments-reuse-daemon-and-caches ()
  "Preview Gradle invocations reuse the daemon and incremental caches."
  (let ((compose-preview-use-gradle-daemon t)
        (compose-preview-force-clean-build nil))
    (should (equal (compose-preview--gradle-arguments ":app:preview" "/init.gradle")
                   '(":app:preview" "--init-script" "/init.gradle" "--daemon"))))
  (let ((compose-preview-use-gradle-daemon nil)
        (compose-preview-force-clean-build t))
    (should (equal (compose-preview--gradle-arguments ":app:preview" "/init.gradle")
                   '(":app:preview" "--init-script" "/init.gradle"
                     "--no-build-cache" "--no-parallel")))))

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
