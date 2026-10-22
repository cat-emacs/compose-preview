;;; compose-preview-tests.el --- Tests for compose-preview -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for pure compose-preview helpers.

;;; Code:

(require 'ert)
(require 'android-project)
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
                           (concat "com.example." (file-name-base file) "Kt")))))
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

(ert-deftest compose-preview-target-prefers-android-project-source-metadata ()
  "Target lookup follows Android Studio-style module metadata for KMP files."
  (cl-letf (((symbol-function 'compose-preview--find-project-root)
             (lambda () "/tmp/project/"))
            ((symbol-function 'android-target-for-source-file)
             (lambda (_file _project-root &optional _refresh)
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

(ert-deftest compose-preview-refresh-starts-missing-project-model ()
  "A first Preview request actively starts Android project-model sync."
  (let ((buffer-file-name "/tmp/project/First.kt")
        (compose-preview--active-file "/tmp/project/First.kt")
        (compose-preview--work-context nil)
        refreshed status)
    (cl-letf (((symbol-function 'compose-preview--find-project-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'compose-preview--cached-target) #'ignore)
              ((symbol-function 'compose-preview--android-project-model-pending-p)
               (lambda (_root) t))
              ((symbol-function 'android-refresh-project-model)
               (lambda (root &optional _callback) (setq refreshed root)))
              ((symbol-function 'compose-preview--panel-status)
               (lambda (_source _root message &optional _face)
                 (setq status message))))
      (should-error (compose-preview-refresh) :type 'user-error))
    (should (equal refreshed "/tmp/project/"))
    (should (string-match-p "syncing" status))))

(ert-deftest compose-preview-cli-sentinel-consumes-partial-and-cleans-request ()
  "A partial CLI response reaches the UI; temporary request files are removed."
  (let* ((directory (make-temp-file "preview-cli-response" t))
         (file (expand-file-name "result.json" directory))
         (context (list :generation 10 :result-file file :request-directory directory))
         (compose-preview--generation 10)
         consumed)
    (compose-preview--write-json file '(("schemaVersion" . 1) ("status" . "partial")))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'process-get) (lambda (_process _key) context))
              ((symbol-function 'compose-preview--finish-cli-result)
               (lambda (ctx response) (setq consumed (list ctx (compose-preview--json-get response "status"))))))
      (compose-preview--cli-sentinel 'process "exit"))
    (should (equal consumed (list context "partial")))
    (should-not (file-exists-p directory))))

(ert-deftest compose-preview-stale-cli-response-only-cleans-request ()
  "Old CLI completions release their own request without affecting current work."
  (let* ((directory (make-temp-file "preview-cli-stale" t))
         (context (list :generation 3 :request-directory directory))
         (compose-preview--generation 4)
         (compose-preview--process 'current))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-get) (lambda (_process _key) context))
              ((symbol-function 'compose-preview--finish-cli-result)
               (lambda (&rest _) (ert-fail "published stale CLI response"))))
      (compose-preview--cli-sentinel 'old "exit"))
    (should (eq compose-preview--process 'current))
    (should-not (file-exists-p directory))))

(ert-deftest compose-preview-project-model-pending-requires-no-last-known-model ()
  "Preview waits only when Android sync has no usable model."
  (cl-letf (((symbol-function 'android-project-model-status)
             (lambda (_root)
               '(:state syncing :last-model-available-p nil))))
    (should (compose-preview--android-project-model-pending-p "/tmp/project/")))
  (cl-letf (((symbol-function 'android-project-model-status)
             (lambda (_root)
               '(:state syncing :last-model-available-p t))))
    (should-not
     (compose-preview--android-project-model-pending-p "/tmp/project/"))))

(ert-deftest compose-preview-project-model-failure-preserves-results ()
  "A failed Android sync updates status without clearing Preview results."
  (let ((compose-preview-results-buffer-name
         (generate-new-buffer-name " *compose-preview-status-test*"))
        (source (generate-new-buffer " *compose-preview-source-test*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq default-directory "/tmp/project/"))
          (with-current-buffer (get-buffer-create
                                compose-preview-results-buffer-name)
            (compose-preview-results-mode)
            (setq-local compose-preview--source-buffer source)
            (let ((inhibit-read-only t)) (insert "old preview image")))
          (cl-letf (((symbol-function 'compose-preview--panel-visible-for-project-p)
                     (lambda (_root) t))
                    ((symbol-function 'compose-preview--display-panel)
                     #'ignore))
            (compose-preview--android-project-model-state-changed
             "/tmp/project/" '(:state failed :diagnostic "Gradle failed")))
          (with-current-buffer compose-preview-results-buffer-name
            (should (equal (buffer-string) "old preview image"))
            (should (string-match-p "Gradle failed" compose-preview--status))
            (should (eq compose-preview--status-face 'error))))
      (when (buffer-live-p source) (kill-buffer source))
      (when-let* ((buffer (get-buffer compose-preview-results-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest compose-preview-model-update-schedules-open-project-refresh ()
  "A model update invalidates metadata and schedules the open Preview project."
  (let ((compose-preview--target-cache
         '(("/tmp/project" . (:variant "debug"))))
        scheduled)
    (cl-letf (((symbol-function 'compose-preview--schedule-model-update-refresh)
               (lambda (root) (setq scheduled root))))
      (compose-preview--android-project-model-updated "/tmp/project/" nil))
    (should-not compose-preview--target-cache)
    (should (equal scheduled "/tmp/project/"))))

(ert-deftest compose-preview-android-model-update-invalidates-target-state ()
  "A refreshed Android model invalidates project target metadata caches."
  (let ((compose-preview--target-cache
         '(("/tmp/project" . (:variant "androidMain"))
           ("/tmp/other" . (:variant "debug"))))
        (compose-preview--metadata-refresh-roots
         '("/tmp/project/" "/tmp/other/")))
    (compose-preview--android-project-model-updated "/tmp/project/" nil)
    (should-not (assoc "/tmp/project" compose-preview--target-cache))
    (should (assoc "/tmp/other" compose-preview--target-cache))
    (should-not (member "/tmp/project/"
                        compose-preview--metadata-refresh-roots))
    (should (member "/tmp/other/"
                    compose-preview--metadata-refresh-roots))))

(ert-deftest compose-preview-target-refreshes-non-rendering-kmp-metadata ()
  "Stale Android KMP metadata is refreshed before selecting a preview task."
  (let ((refreshed nil))
    (cl-letf (((symbol-function 'compose-preview--find-project-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'android-target-for-source-file)
               (lambda (_file _project-root &optional refresh)
                 (setq refreshed (or refreshed refresh))
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

(ert-deftest compose-preview-target-refreshes-stale-cache-from-android-project ()
  "Android-mode source metadata should replace stale in-memory targets."
  (cl-letf (((symbol-function 'compose-preview--find-project-root)
             (lambda () "/tmp/project/"))
            ((symbol-function 'android-target-for-source-file)
             (lambda (_file _project-root &optional _refresh)
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

(ert-deftest compose-preview-cached-target-upgrades-to-android-project-variant ()
  "Cached module targets should use android-project's real variant metadata."
  (cl-letf (((symbol-function 'compose-preview--find-project-root)
             (lambda () "/tmp/project/"))
            ((symbol-function 'compose-preview--android-flavors-available-p)
             (lambda () t))
            ((symbol-function 'android-project-target)
             (lambda (_module _variant &optional _project-root _refresh)
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
          (buffer-file-name nil))
      (should
       (equal
        (compose-preview--target)
        (list :project-root "/tmp/project/"
              :module-root "/tmp/project/composeApp/"
              :module-path ":composeApp"
              :variant "androidMain"
              :preview-task "assembleAndroidMain"))))))

(ert-deftest compose-preview-force-prompt-uses-android-project-module-root ()
  "Prompted android-project modules keep their Gradle metadata module root."
  (cl-letf (((symbol-function 'compose-preview--find-project-root)
             (lambda () "/tmp/project/"))
            ((symbol-function 'compose-preview--find-module-root)
             (lambda () "/tmp/project/current/file/module/"))
            ((symbol-function 'compose-preview--android-flavors-available-p)
             (lambda () t))
            ((symbol-function 'android-current-target)
             (lambda (&optional _prompt _file _project-root)
               (list :module-path ":demo-android"
                     :module-name "demo-android"
                     :module-root "/tmp/project/app/demo-android"
                     :variant "debug"
                     :application-id "com.example.demo"
                     :source-roots '("src/main/java")
                     :preview-task "testDebugUnitTest"))))
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

(ert-deftest compose-preview-size-command-rejects-invalid-dimensions ()
  "Invalid resize values cannot start rendering or mutate source."
  (dolist (size '(0 -1 10001 3.5))
    (should-error (compose-preview-set-size size 640) :type 'user-error)))

(ert-deftest compose-preview-unified-component-tree-preserves-details-and-identity ()
  "Consume current Studio component schema, with strict card identity checks."
  (let* ((root (make-temp-file "preview-components" t))
         (file (expand-file-name "card.json" root))
         (node '(("name" . "Button")
                 ("bounds" . (("left" . 0) ("top" . 0) ("right" . 100) ("bottom" . 40)))
                 ("sourceLocation" . (("fileName" . "Card.kt") ("lineNumber" . 7)
                                      ("packageHash" . 123)))
                 ("semantics" . (("text" . "Click")))
                 ("modifiers" . (("clickable" . "true")))
                 ("parameters" . (("enabled" . "true")))))
         (tree `(("previewId" . "preview") ("methodFQN" . "demo.CardKt.Card")
                 ("width" . 100) ("height" . 40) ("components" . [,node])))
         (result '(("previewId" . "preview") ("methodFQN" . "demo.CardKt.Card")
                   ("imagePath" . "card.png") ("componentTreePath" . "card.json"))))
    (unwind-protect
        (progn
          (compose-preview--write-json file tree)
          (let* ((items (compose-preview--result-items (list result) root))
                 (item (car items))
                 (component (car (compose-preview-item-bounds item))))
            (should (compose-preview-item-component-tree item))
            (should (equal (compose-preview--json-get component "fileName") "Card.kt"))
            (should (equal (compose-preview--json-get component "semantics") '(("text" . "Click"))))
            (should (equal (compose-preview--json-get component "modifiers") '(("clickable" . "true")))))
          (setf (alist-get "previewId" tree nil nil #'equal) "other")
          (compose-preview--write-json file tree)
          (should-not (compose-preview--read-component-tree root "card.png" result))
          (should-not (compose-preview--read-component-tree
                       root "card.png" '(("componentTreePath" . "../outside.json"))))
          (setf (alist-get "previewId" tree nil nil #'equal) "preview"
                (alist-get "components" tree nil nil #'equal)
                [(("name" . "Malformed") ("bounds" . (("left" . "bad"))))])
          (compose-preview--write-json file tree)
          (should-not (compose-preview--read-component-tree root "card.png" result)))
      (delete-directory root t))))

(ert-deftest compose-preview-empty-image-path-is-not-an-image ()
  "Inflate-only protocol output must not turn the output directory into a PNG."
  (let* ((result '(("methodFQN" . "demo.Card") ("previewId" . "card") ("imagePath" . "")))
         (item (car (compose-preview--result-items (list result) "/tmp/output/"))))
    (should-not (compose-preview-item-files item))))

(ert-deftest compose-preview-unified-component-tree-allows-no-source-location ()
  "Runtime nodes without source must still be inspectable, not navigable."
  (let ((nodes (compose-preview--normalize-components
                '((("name" . "Layout")
                   ("bounds" . (("left" . 0) ("top" . 0) ("right" . 20) ("bottom" . 30))))))))
    (should (compose-preview--valid-bounds-tree-p nodes))
    (should-error (compose-preview--visit-component (car nodes) nil) :type 'user-error)))

(ert-deftest compose-preview-bounds-read-and-hit-test ()
  "Official companion JSON enables deepest-node physical-pixel hit testing."
  (let* ((root (make-temp-file "preview-bounds" t))
         (child '(("name" . "Button") ("fileName" . "A.kt") ("lineNumber" . 4)
                  ("packageHash" . -1) ("bounds" . (("left" . 10) ("top" . 20)
                                                    ("right" . 100) ("bottom" . 80)))
                  ("children" . nil)))
         (parent `(("name" . "Column") ("fileName" . "A.kt") ("lineNumber" . 2)
                   ("packageHash" . -1) ("bounds" . (("left" . 0) ("top" . 0)
                                                     ("right" . 200) ("bottom" . 400)))
                   ("children" . (,child)))))
    (unwind-protect
        (progn
          (compose-preview--write-json (expand-file-name "A.bounds.json" root) (vector parent))
          (let* ((nodes (compose-preview--read-bounds root "A.png"))
                 (hit (compose-preview--bounds-hit nodes 40 40)))
            (should (equal (compose-preview--json-get hit "name") "Button"))
            (should-not (compose-preview--bounds-hit nodes 300 500)))
          (should-not (compose-preview--read-bounds root "missing.png"))
          (with-temp-file (expand-file-name "A.bounds.json" root) (insert "invalid JSON"))
          (should-not (compose-preview--read-bounds root "A.png")))
      (delete-directory root t))))

(ert-deftest compose-preview-component-inspection-reports-missing-capability ()
  "Pinned renderer without bounds must not fabricate component data."
  (cl-letf (((symbol-function 'compose-preview--configuration-item)
             (lambda () (make-compose-preview-item :id "preview"))))
    (should-error (compose-preview-inspect-components) :type 'user-error)))

(ert-deftest compose-preview-source-folding-requires-parser ()
  "Missing Kotlin tree-sitter support is explicit and does not hide text."
  (cl-letf (((symbol-function 'treesit-parser-list) (lambda () nil)))
    (should-error (compose-preview-fold-source) :type 'user-error)))

(ert-deftest compose-preview-source-folding-recognizes-import-aliases ()
  "Folding respects annotation imports, ignores ordinary and nested functions."
  (skip-unless (and (fboundp 'treesit-language-available-p)
                    (treesit-language-available-p 'kotlin)))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/A.kt")
    (insert "import androidx.compose.runtime.Composable as C\n"
            "import androidx.compose.ui.tooling.preview.Preview as P\n"
            "@P\n@C\nfun Card() {\n Text(\"preview\")\n}\n"
            "fun PreviewHelper() {\n println(\"normal\")\n}\n"
            "fun Outer() {\n @P @C fun Nested() {\n Text(\"nested\")\n }\n}\n")
    (treesit-parser-create 'kotlin)
    (cl-letf (((symbol-function 'compose-preview--compiled-preview-methods) (lambda () nil)))
      (compose-preview-fold-source))
    (should (= (length compose-preview--source-folds) 1))
    (goto-char (point-max))
    (insert "\n")
    (should-not compose-preview--source-folds)
    (compose-preview-unfold-source)))

(ert-deftest compose-preview-bounds-path-cannot-escape-output ()
  "Companion bounds outside the renderer output directory are rejected."
  (let* ((parent (make-temp-file "preview-bounds-path" t))
         (root (expand-file-name "output" parent)))
    (unwind-protect
        (progn
          (make-directory root)
          (with-temp-file (expand-file-name "outside.bounds.json" parent) (insert "[]"))
          (should-not (compose-preview--read-bounds root "../outside.png")))
      (delete-directory parent t))))

(ert-deftest compose-preview-source-folding-uses-compiled-multipreview-discovery ()
  "Custom MultiPreview names are recognized through exact compiled method IDs."
  (skip-unless (and (fboundp 'treesit-language-available-p)
                    (treesit-language-available-p 'kotlin)))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/A.kt")
    (insert "package demo\n@MyDevices\n@Composable\nfun Card() {\n Text(\"preview\")\n}\n"
            "// @Preview @Composable\nfun FakePreview() {\n Text(\"normal\")\n}\n")
    (treesit-parser-create 'kotlin)
    (cl-letf (((symbol-function 'compose-preview--compiled-preview-methods)
               (lambda () '("demo.AKt.Card"))))
      (compose-preview-fold-source))
    (should (= (length compose-preview--source-folds) 1))
    (compose-preview-unfold-source)))

(ert-deftest compose-preview-configuration-command-is-render-only ()
  "Changing dimensions preserves the render-only contract and annotation ID."
  (let ((source (generate-new-buffer " *preview-config-source*"))
        (compose-preview--sessions (make-hash-table :test #'equal))
        (compose-preview--work-context nil)
        (compose-preview--source-buffer nil)
        (item (make-compose-preview-item :preview-id "preview" :configuration nil))
        rendered)
    (unwind-protect
        (progn
          (with-current-buffer source (setq buffer-file-name "/tmp/A.kt"))
          (setq compose-preview--source-buffer source)
          (let ((session (compose-preview--session "/tmp/A.kt")))
            (setf (plist-get session :target) '(:project-root "/tmp/")
                  (plist-get session :stale) nil)
            (cl-letf (((symbol-function 'compose-preview--configuration-item) (lambda () item))
                      ((symbol-function 'compose-preview--save-session-view) #'ignore)
                      ((symbol-function 'compose-preview-refresh)
                       (lambda (&rest _)
                         (setq rendered (list compose-preview--render-only
                                              compose-preview--refresh-all-in-file (current-buffer))))))
              (compose-preview-set-size 320 480))
            (should (equal rendered (list t t source)))
            (should (= (cdr (assoc "widthDp" (plist-get
                                              (gethash "preview" (plist-get session :overrides)) :values)))
                       320))))
      (kill-buffer source))))

(ert-deftest compose-preview-init-script-configures-layoutlib-model ()
  "Init script collects Studio renderer inputs without snapshot frameworks."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "gradle/preview.init.gradle"))
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
     (expand-file-name "gradle/adapters/agp-9.3-kmp.init.gradle"))
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
    (insert-file-contents (expand-file-name "renderer/ComposePreviewRenderLauncher.java"))
    (let ((source (buffer-string)))
      (should (string-match-p "RenderEnvironmentBootstrapper" source))
      (should (string-match-p "readStrings(settings, \"rClassJars\")" source))
      (should (string-match-p "displayName" source))
      (should (string-match-p "instanceId" source))))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "cli/src/main/kotlin/cat/preview/Main.kt"))
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

(ert-deftest compose-preview-fallback-target-cache-does-not-cross-modules ()
  "Without android-project, a project cache cannot redirect another module."
  (let ((compose-preview-use-android-project-flavors nil)
        (compose-preview--target-cache
         '(("/tmp/project" . (:project-root "/tmp/project/"
					    :module-root "/tmp/project/a/"
					    :module-path ":a" :variant "debug")))))
    (cl-letf (((symbol-function 'compose-preview--find-project-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'compose-preview--find-module-root)
               (lambda () "/tmp/project/b/")))
      (should (equal (plist-get (compose-preview--target) :module-path) ":b")))))

(ert-deftest compose-preview-image-measurement-supports-headless-emacs ()
  "Emacs builds without image-size use the existing layout fallback."
  (let ((original (and (fboundp 'image-size) (symbol-function 'image-size))))
    (unwind-protect
        (progn
          (fmakunbound 'image-size)
          (should-not (compose-preview--image-width 'image))
          (should-not (compose-preview--actual-image-size "/tmp/unused.png" 160)))
      (when original (fset 'image-size original)))))

(ert-deftest compose-preview-file-session-restores-valid-cache ()
  "Reactivating a fresh file restores its surface without building."
  (let* ((root (file-name-as-directory (make-temp-file "preview-cache-project" t)))
         (source (generate-new-buffer " *preview-cache-source*"))
         (compose-preview--sessions (make-hash-table :test #'equal))
         (compose-preview--project-input-signatures (make-hash-table :test #'equal))
         (compose-preview--input-watch-timer nil)
         (compose-preview--active-file nil)
         (compose-preview--work-context nil)
         (target (list :module-root root :project-root root))
         shown)
    (unwind-protect
        (with-current-buffer source
          (setq buffer-file-name (expand-file-name "Cached.kt" root))
          (let ((session (compose-preview--session buffer-file-name)))
            (setf (plist-get session :target) target
                  (plist-get session :stamp) (compose-preview--source-stamp source)
                  (plist-get session :stale) nil)
            (cl-letf (((symbol-function 'compose-preview--target) (lambda (&rest _) target))
                      ((symbol-function 'compose-preview--save-session-view) #'ignore)
                      ((symbol-function 'compose-preview--show-session)
                       (lambda (cached _buffer) (setq shown cached))))
              (should (compose-preview--activate-file source))
              (should (eq shown session))
              (insert "changed")
              (should-not (compose-preview--activate-file source)))))
      (when (timerp compose-preview--input-watch-timer)
        (cancel-timer compose-preview--input-watch-timer))
      (kill-buffer source)
      (delete-directory root t))))

(ert-deftest compose-preview-background-render-caches-without-replacing-panel ()
  "An inactive file completion is cached and never paints the active file."
  (let ((source (generate-new-buffer " *preview-background-source*"))
        (compose-preview--sessions (make-hash-table :test #'equal))
        (compose-preview--active-file "/tmp/B.kt")
        (compose-preview--work-context '(:generation 1))
        (item (make-compose-preview-item :id "a"))
        painted)
    (unwind-protect
        (progn
          (with-current-buffer source (setq buffer-file-name "/tmp/A.kt"))
          (cl-letf (((symbol-function 'compose-preview--read-json)
                     (lambda (_) '(("screenshotResults" . nil))))
                    ((symbol-function 'compose-preview--result-items)
                     (lambda (&rest _) (list item)))
                    ((symbol-function 'compose-preview--render-results)
                     (lambda (&rest _) (setq painted t)))
                    ((symbol-function 'compose-preview--complete-work) #'ignore)
                    ((symbol-function 'compose-preview--log) #'ignore))
            (compose-preview--finish-cli-result
             (list :generation 1 :source-buffer source :source-file "/tmp/A.kt"
                   :stamp (compose-preview--source-stamp source)
                   :target '(:module-root "/tmp/" :project-root "/tmp/"))
             '(("outputDirectory" . "/tmp/") ("results" . nil) ("status" . "ready"))))
          (should-not painted)
          (should (equal (plist-get (gethash "/tmp/A.kt" compose-preview--sessions)
                                    :items)
                         (list item))))
      (kill-buffer source))))

(ert-deftest compose-preview-busy-chain-queues-latest-file ()
  "Switch requests do not cancel work and only the latest file is queued."
  (let ((source (generate-new-buffer " *preview-queue-source*"))
        (compose-preview--active-file "/tmp/B.kt")
        (compose-preview--work-context '(:source-file "/tmp/A.kt" :generation 1))
        (compose-preview--queued-request nil)
        (compose-preview--follow-refresh t))
    (unwind-protect
        (with-current-buffer source
          (setq buffer-file-name "/tmp/B.kt")
          (cl-letf (((symbol-function 'compose-preview--panel-status) #'ignore)
                    ((symbol-function 'compose-preview--start-refresh)
                     (lambda (&rest _) (ert-fail "concurrent chain"))))
            (compose-preview-refresh)
            (should (eq (plist-get compose-preview--queued-request :buffer) source))
            (should (equal (plist-get compose-preview--work-context :source-file)
                           "/tmp/A.kt"))))
      (kill-buffer source))))

(ert-deftest compose-preview-file-session-preserves-independent-view ()
  "A and B retain separate filters, zoom, folds, and focus settings."
  (let ((a (generate-new-buffer " *preview-view-a*"))
        (b (generate-new-buffer " *preview-view-b*"))
        (compose-preview-results-buffer-name " *preview-view-panel*")
        (compose-preview--sessions (make-hash-table :test #'equal)))
    (unwind-protect
        (cl-letf (((symbol-function 'compose-preview--display-panel) #'ignore))
          (with-current-buffer a (setq buffer-file-name "/tmp/A.kt"))
          (with-current-buffer b (setq buffer-file-name "/tmp/B.kt"))
          (compose-preview--show-session (compose-preview--session "/tmp/A.kt") a)
          (with-current-buffer compose-preview-results-buffer-name
            (setq compose-preview--search-query "Card"
                  compose-preview--view-mode 'focus
                  compose-preview--image-zoom 2.0)
            (puthash "section-a" t compose-preview--collapsed-groups))
          (compose-preview--save-session-view)
          (compose-preview--show-session (compose-preview--session "/tmp/B.kt") b)
          (with-current-buffer compose-preview-results-buffer-name
            (should-not compose-preview--search-query)
            (should (eq compose-preview--view-mode 'grid))
            (should (= (hash-table-count compose-preview--collapsed-groups) 0)))
          (compose-preview--save-session-view)
          (compose-preview--show-session (compose-preview--session "/tmp/A.kt") a)
          (with-current-buffer compose-preview-results-buffer-name
            (should (equal compose-preview--search-query "Card"))
            (should (eq compose-preview--view-mode 'focus))
            (should (= compose-preview--image-zoom 2.0))
            (should (gethash "section-a" compose-preview--collapsed-groups))))
      (kill-buffer a)
      (kill-buffer b)
      (when-let* ((panel (get-buffer compose-preview-results-buffer-name)))
        (kill-buffer panel)))))

(ert-deftest compose-preview-session-invalidation-protects-in-flight-results ()
  "Project edits invalidate file sessions including running snapshots."
  (let ((compose-preview--sessions (make-hash-table :test #'equal)))
    (let ((session (compose-preview--session "/tmp/A.kt")))
      (setf (plist-get session :target) '(:project-root "/tmp/project/")
            (plist-get session :stale) nil)
      (compose-preview--invalidate-project-sessions "/tmp/project/")
      (should (plist-get session :stale))
      (should (= (plist-get session :revision) 1)))))

(ert-deftest compose-preview-hidden-session-status-does-not-open-panel ()
  "Background progress on a deactivated file cannot reopen its panel."
  (let ((source (generate-new-buffer " *preview-inactive-source*"))
        (compose-preview--sessions (make-hash-table :test #'equal))
        (compose-preview--active-file nil)
        (compose-preview--work-context '(:generation 1)))
    (unwind-protect
        (progn
          (with-current-buffer source (setq buffer-file-name "/tmp/A.kt"))
          (cl-letf (((symbol-function 'compose-preview--display-panel)
                     (lambda (&rest _) (ert-fail "reopened inactive panel"))))
            (compose-preview--panel-status source "/tmp/" "rendering"))
          (should (equal (plist-get (compose-preview--session "/tmp/A.kt") :status)
                         "rendering")))
      (kill-buffer source))))

(ert-deftest compose-preview-session-cache-is-lru-bounded ()
  "Cache eviction keeps the active and rendering file sessions."
  (let ((compose-preview--sessions (make-hash-table :test #'equal))
        (compose-preview-session-cache-size 2)
        (compose-preview--active-file "/tmp/C.kt")
        (compose-preview--work-context '(:source-file "/tmp/B.kt")))
    (dolist (file '("/tmp/A.kt" "/tmp/B.kt" "/tmp/C.kt"))
      (compose-preview--session file))
    (compose-preview--evict-sessions)
    (should-not (gethash "/tmp/A.kt" compose-preview--sessions))
    (should (= (hash-table-count compose-preview--sessions) 2))))

(ert-deftest compose-preview-completion-starts-latest-waiting-file ()
  "A completed render releases the chain before starting the queued file."
  (let ((source (generate-new-buffer " *preview-drain-source*"))
        (compose-preview--work-context '(:generation 7))
        (compose-preview--active-file "/tmp/B.kt")
        (compose-preview--queued-request nil)
        started)
    (unwind-protect
        (progn
          (with-current-buffer source (setq buffer-file-name "/tmp/B.kt"))
          (setq compose-preview--queued-request (list :buffer source :all t :follow t))
          (cl-letf (((symbol-function 'compose-preview--evict-sessions) #'ignore)
                    ((symbol-function 'compose-preview--start-refresh)
                     (lambda (&rest _)
                       (should-not compose-preview--work-context)
                       (setq started (current-buffer)))))
            (compose-preview--complete-work '(:generation 7)))
          (should (eq started source))
          (should-not compose-preview--queued-request))
      (kill-buffer source))))

(ert-deftest compose-preview-input-signature-ignores-docs-and-build-output ()
  "Only source/resource/build inputs invalidate cached Preview results."
  (let ((root (file-name-as-directory (make-temp-file "preview-inputs" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "src/main" root) t)
          (make-directory (expand-file-name "build" root) t)
          (with-temp-file (expand-file-name "src/main/A.kt" root) (insert "fun A() {}"))
          (let ((before (compose-preview--input-signature root)))
            (with-temp-file (expand-file-name "README.md" root) (insert "docs"))
            (with-temp-file (expand-file-name "build/A.kt" root) (insert "generated"))
            (should (equal before (compose-preview--input-signature root)))
            (with-temp-file (expand-file-name "src/main/A.kt" root) (insert "fun Changed() {}"))
            (should-not (equal before (compose-preview--input-signature root)))))
      (delete-directory root t))))

(ert-deftest compose-preview-session-status-reports-unsaved-and-stale ()
  "Cached images must not masquerade as fresh results after source changes."
  (let ((source (generate-new-buffer " *preview-status-unsaved*")))
    (unwind-protect
        (with-current-buffer source
          (insert "unsaved")
          (should (string-match-p "unsaved"
                                  (compose-preview--session-status '(:status "ready") source)))
          (set-buffer-modified-p nil)
          (should (string-match-p "out of date"
                                  (compose-preview--session-status '(:stale t :items (image)) source))))
      (kill-buffer source))))

(ert-deftest compose-preview-anchor-follows-item-id-after-layout-change ()
  "Restored navigation uses card identity rather than a stale character offset."
  (with-temp-buffer
    (let ((old (make-compose-preview-item :id "card"))
          (new (make-compose-preview-item :id "card")))
      (insert "new layout prefix\n")
      (let ((position (point)))
        (insert (propertize "Card" 'compose-preview-item new))
        (should (= position (compose-preview--anchor-position old)))))))

(ert-deftest compose-preview-inactive-monitor-does-not-scan-projects ()
  "Hidden or closed Preview surfaces must not repeatedly scan the project."
  (let ((compose-preview--project-input-signatures (make-hash-table :test #'equal))
        (compose-preview--active-file nil)
        (compose-preview--work-context nil))
    (puthash "/tmp/project/" 'old compose-preview--project-input-signatures)
    (cl-letf (((symbol-function 'compose-preview--input-signature)
               (lambda (_root) (ert-fail "inactive Preview scanned project"))))
      (compose-preview--watch-inputs))))

(ert-deftest compose-preview-monitor-throttles-visible-project ()
  "Repeated idle callbacks scan only the current root at the configured interval."
  (let* ((root "/tmp/project/")
         (compose-preview--sessions (make-hash-table :test #'equal))
         (compose-preview--project-input-signatures (make-hash-table :test #'equal))
         (compose-preview--last-input-check (make-hash-table :test #'equal))
         (compose-preview--active-file "/tmp/project/A.kt")
         (compose-preview--work-context nil)
         (compose-preview-results-buffer-name " *preview-monitor-throttle*")
         (clock 100.0)
         (scans 0))
    (unwind-protect
        (progn
          (get-buffer-create compose-preview-results-buffer-name)
          (let ((session (compose-preview--session compose-preview--active-file)))
            (setf (plist-get session :target) (list :project-root root)))
          (puthash root 'unchanged compose-preview--project-input-signatures)
          (puthash "/tmp/inactive/" 'other compose-preview--project-input-signatures)
          (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t))
                    ((symbol-function 'float-time) (lambda (&rest _) clock))
                    ((symbol-function 'compose-preview--input-signature)
                     (lambda (project)
                       (should (equal project root))
                       (cl-incf scans)
                       'unchanged)))
            (compose-preview--watch-inputs)
            (setq clock 105.0)
            (compose-preview--watch-inputs)
            (should (= scans 1))
            (setq clock 131.0)
            (compose-preview--watch-inputs)
            (should (= scans 2))
            (let ((compose-preview--work-context '(:generation 1)))
              (setq clock 200.0)
              (compose-preview--watch-inputs)
              (should (= scans 2)))))
      (kill-buffer compose-preview-results-buffer-name))))

(ert-deftest compose-preview-input-validation-is-scoped-to-operation ()
  "Repeated validation scans once per operation, never across later operations."
  (let ((scans 0))
    (cl-letf (((symbol-function 'compose-preview--scan-input-signature)
               (lambda (_root) (list (cl-incf scans)))))
      (let ((compose-preview--input-validation-cache (make-hash-table :test #'equal)))
        (should (equal (compose-preview--input-signature "/project/") '(1)))
        (should (equal (compose-preview--input-signature "/project/") '(1))))
      (should (equal (compose-preview--input-signature "/project/") '(2))))))

(ert-deftest compose-preview-panel-disposal-releases-owned-work-and-monitoring ()
  "Killing the Preview panel stops its work without touching shared daemons."
  (let ((compose-preview--active-file "/tmp/A.kt")
        (compose-preview--follow-active t)
        (compose-preview--follow-buffer 'source)
        (post-command-hook '(compose-preview--follow-selected-buffer))
        paused cancelled)
    (cl-letf (((symbol-function 'compose-preview--pause-input-monitor)
               (lambda () (setq paused t)))
              ((symbol-function 'compose-preview--cancel-follow-timer) #'ignore)
              ((symbol-function 'compose-preview--cancel-process)
               (lambda () (setq cancelled t))))
      (compose-preview--panel-disposed)
      (should paused)
      (should cancelled)
      (should-not compose-preview--active-file)
      (should-not compose-preview--follow-active)
      (should-not (memq #'compose-preview--follow-selected-buffer post-command-hook)))))

(ert-deftest compose-preview-input-validation-memoizes-empty-projects ()
  "Empty signatures are cached too, but never outside the current operation."
  (let ((compose-preview--input-validation-cache (make-hash-table :test #'equal))
        (count 0))
    (cl-letf (((symbol-function 'compose-preview--scan-input-signature)
               (lambda (_) (cl-incf count) nil)))
      (compose-preview--input-signature "/project/")
      (compose-preview--input-signature "/project/")
      (should (= count 1)))))

(ert-deftest compose-preview-launcher-cleanup-is-bounded ()
  "Run the launcher's actual cleanup method against a blocking Java action."
  (let ((javac (executable-find "javac"))
        (java (executable-find "java")))
    (skip-unless (and javac java))
    (let ((directory (make-temp-file "preview-cleanup-java" t))
          (launcher (expand-file-name "renderer/ComposePreviewRenderLauncher.java")))
      (unwind-protect
          (let* ((source (with-temp-buffer
                           (insert-file-contents launcher)
                           (goto-char (point-min))
                           (search-forward "    static void runCleanup")
                           (let ((start (match-beginning 0)))
                             (search-forward "    // Layoutlib leaves non-daemon threads")
                             (buffer-substring-no-properties start (match-beginning 0)))))
                 (probe (expand-file-name "CleanupProbe.java" directory))
                 (output (get-buffer-create " *preview-cleanup-java-output*")))
            (with-temp-file probe
              (insert "public class CleanupProbe {\n" source
                      "public static void main(String[] args) {\n"
                      "long start = System.nanoTime();\n"
                      "runCleanup(() -> { while (true) { try { Thread.sleep(1000); } catch (InterruptedException e) {} } }, 100, \"blocked\");\n"
                      "long millis = (System.nanoTime() - start) / 1000000;\n"
                      "if (millis > 2000) throw new AssertionError(\"Unbounded cleanup: \" + millis);\n"
                      "System.out.println(\"CLEANUP-OK\");\n}\n}\n"))
            (should (= 0 (call-process javac nil output nil probe)))
            (let ((process (make-process :name "preview-cleanup-probe" :buffer output
                                         :command (list java "-cp" directory "CleanupProbe")
                                         :noquery t :sentinel #'ignore))
                  (deadline (+ (float-time) 5)))
              (unwind-protect
                  (progn
                    (while (and (process-live-p process) (< (float-time) deadline))
                      (accept-process-output process 0.05))
                    (should-not (process-live-p process))
                    (should (= 0 (process-exit-status process)))
                    (when (process-live-p process) (delete-process process))))
              (with-current-buffer output
		(should (string-match-p "CLEANUP-OK" (buffer-string)))))
            (when-let* ((output (get-buffer " *preview-cleanup-java-output*")))
              (kill-buffer output))
            (delete-directory directory t))))))

(ert-deftest compose-preview-idle-monitor-invalidates-external-source-change ()
  "External source edits invalidate both file and module model caches."
  (let* ((root (file-name-as-directory (make-temp-file "preview-watch" t)))
         (file (expand-file-name "A.kt" root))
         (compose-preview--sessions (make-hash-table :test #'equal))
         (compose-preview--project-input-signatures (make-hash-table :test #'equal))
         (compose-preview--active-file file)
         (compose-preview--last-input-check (make-hash-table :test #'equal))
         (compose-preview--work-context nil)
         (compose-preview-results-buffer-name (generate-new-buffer-name " *preview-watch*"))
         (target (list :project-root root :module-root root)))
    (unwind-protect
        (progn
          (get-buffer-create compose-preview-results-buffer-name)
          (with-temp-file file (insert "fun A() {}"))
          (let ((session (compose-preview--session file)))
            (setf (plist-get session :target) target
                  (plist-get session :stale) nil)
            (puthash root (compose-preview--input-signature root)
                     compose-preview--project-input-signatures)
            (with-temp-file file (insert "fun ChangedExternally() {}"))
            (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t)))
              (compose-preview--watch-inputs))
            (should (plist-get session :stale))))
      (kill-buffer compose-preview-results-buffer-name)
      (delete-directory root t))))

(ert-deftest compose-preview-log-command-uses-source-session ()
  "The panel log command opens its own file log rather than the latest build."
  (let ((source (generate-new-buffer " *preview-log-source*"))
        (log (generate-new-buffer " *preview-own-log*"))
        (compose-preview--sessions (make-hash-table :test #'equal))
        displayed)
    (unwind-protect
        (with-current-buffer source
          (setq buffer-file-name "/tmp/A.kt")
          (let ((session (compose-preview--session buffer-file-name)))
            (setf (plist-get session :log) log))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (buffer &rest _) (setq displayed buffer))))
            (compose-preview-open-log))
          (should (eq displayed log)))
      (kill-buffer source)
      (kill-buffer log))))

(ert-deftest compose-preview-missing-cached-png-forces-refresh ()
  "A missing PNG prevents reactivation from treating a session as fresh."
  (let ((source (generate-new-buffer " *preview-missing-png*"))
        (compose-preview--sessions (make-hash-table :test #'equal))
        (compose-preview--module-models (make-hash-table :test #'equal))
        (target '(:project-root "/tmp/" :module-root "/tmp/")))
    (unwind-protect
        (with-current-buffer source
          (setq buffer-file-name "/tmp/A.kt")
          (let ((session (compose-preview--session buffer-file-name)))
            (setf (plist-get session :target) target
                  (plist-get session :stamp) (compose-preview--source-stamp source)
                  (plist-get session :stale) nil
                  (plist-get session :images) '("/missing-preview-file.png"))
            (cl-letf (((symbol-function 'compose-preview--target) (lambda (&rest _) target))
                      ((symbol-function 'compose-preview--track-inputs) #'ignore)
                      ((symbol-function 'compose-preview--save-session-view) #'ignore)
                      ((symbol-function 'compose-preview--show-session) #'ignore))
              (should-not (compose-preview--activate-file source)))))
      (kill-buffer source))))

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
          (should-not cancelled)
          (should (equal scheduled
                         (list #'compose-preview--follow-refresh-buffer source))))
      (kill-buffer source))))

(ert-deftest compose-preview-following-hides-files-without-previews ()
  "Following a Kotlin file without Preview declarations hides the panel."
  (let (hidden failed)
    (cl-letf (((symbol-function 'compose-preview--read-json)
               (lambda (_file) '(("previews"))))
              ((symbol-function 'compose-preview--hide-panel)
               (lambda () (setq hidden t)))
              ((symbol-function 'compose-preview--fail)
               (lambda (&rest _) (setq failed t)))
              ((symbol-function 'compose-preview--log) #'ignore))
      (let ((compose-preview--active-file "/tmp/Plain.kt"))
        (compose-preview--finish-cli-result
         (list :source-buffer (current-buffer) :source-file "/tmp/Plain.kt"
               :follow-refresh t :target '(:module-path ":app"))
         '(("outputDirectory" . "/tmp/") ("results" . nil) ("status" . "ready"))))
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
          (should-not cancelled)
          (should hidden))
      (kill-buffer other))))

(ert-deftest compose-preview-panel-quit-stops-file-following ()
  "Manually closing Preview stops automatic file following."
  (let ((compose-preview--follow-active t)
        (compose-preview--follow-buffer 'source)
        cancelled timer-cancelled removed quit)
    (cl-letf (((symbol-function 'compose-preview--cancel-follow-timer) #'ignore)
              ((symbol-function 'compose-preview--cancel-process)
               (lambda () (setq cancelled t)))
              ((symbol-function 'compose-preview--source-project-root)
               (lambda (_source) "/tmp/project/"))
              ((symbol-function 'compose-preview--cancel-model-refresh-timer)
               (lambda (root) (setq timer-cancelled root)))
              ((symbol-function 'remove-hook) (lambda (&rest _) (setq removed t)))
              ((symbol-function 'quit-window) (lambda (&rest _) (setq quit t))))
      (compose-preview-panel-quit)
      (should-not compose-preview--follow-active)
      (should-not compose-preview--follow-buffer)
      (should cancelled)
      (should removed)
      (should (equal timer-cancelled "/tmp/project/"))
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

(provide 'compose-preview-tests)

;;; compose-preview-tests.el ends here
