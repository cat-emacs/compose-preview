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
    (search-forward "Helper")
    (should-not (compose-preview--current-preview-method))))

(ert-deftest compose-preview-gradle-context-includes-preview-method ()
  "Gradle context exports a selected preview method when the target has one."
  (cl-letf (((symbol-function 'compose-preview--get-init-script)
             (lambda () "/tmp/compose-preview/preview.init.gradle"))
            ((symbol-function 'compose-preview--gradle-executable)
             (lambda (_project-root) "/tmp/project/gradlew")))
    (let* ((target (list :project-root "/tmp/project/"
                         :module-root "/tmp/project/app/"
                         :module-path ":app"
                         :source-file "/tmp/project/app/src/main/java/example/Foo.kt"
                         :preview-method "MainPreview"))
           (context (compose-preview--gradle-context
                     "testDebugUnitTest" "debug" target)))
      (should (member "COMPOSE_PREVIEW_METHOD=MainPreview"
                      (plist-get context :env))))))

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

(ert-deftest compose-preview-preview-task-uses-desktop-test-for-kmp ()
  "KMP AndroidMain variants use a desktop test renderer when available."
  (should (equal (compose-preview--preview-task
                  "androidMain"
                  (list :variant "androidMain"
                        :preview-task "desktopTest"))
                 "desktopTest"))
  (should (equal (compose-preview--preview-task
                  "debug"
                  (list :variant "debug"))
                 "testDebugUnitTest"))
  (should (equal (compose-preview--preview-task
                  "androidMain"
                  (list :variant "androidMain"
                        :preview-task "compileAndroidMain"))
                 "compileAndroidMain")))

(ert-deftest compose-preview-preview-task-ignores-empty-metadata ()
  "Missing preview task metadata should fall back to the variant task shape."
  (should (equal (compose-preview--preview-task
                  "debug"
                  (list :variant "debug"
                        :preview-task ""))
                 "testDebugUnitTest")))

(ert-deftest compose-preview-preview-task-rendering-p-detects-test-task ()
  "Only preview test tasks are expected to produce screenshots."
  (should (compose-preview--preview-task-rendering-p "testDebugUnitTest"))
  (should (compose-preview--preview-task-rendering-p "desktopTest"))
  (should-not (compose-preview--preview-task-rendering-p "assembleAndroidMain"))
  (should-not (compose-preview--preview-task-rendering-p "compileAndroidMain")))

(ert-deftest compose-preview-image-files-include-kmp-render-output ()
  "KMP desktop renderer PNGs are discovered with Android outputs."
  (let* ((root (make-temp-file "compose-preview-module" t))
         (image (expand-file-name "build/compose-preview/foo.png" root)))
    (make-directory (file-name-directory image) t)
    (with-temp-file image
      (insert "png"))
    (should (equal (compose-preview--image-files root) (list image)))))

(ert-deftest compose-preview-init-script-configures-kmp-desktop-renderer ()
  "AGP KMP Android modules render through desktopTest with Roborazzi."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "preview.init.gradle"))
    (let ((script (buffer-string)))
      (should (string-match-p "com.android.kotlin.multiplatform.library" script))
      (should (string-match-p "generateComposePreviewDesktopTest" script))
      (should (string-match-p "platformType == \"jvm\"" script))
      (should (string-match-p "jvmTestSourceSetName" script))
      (should (string-match-p "actualJvmTestTaskName" script))
      (should (string-match-p "project.tasks.register(\"desktopTest\")" script))
      (should (string-match-p "roborazzi-compose-desktop" script))
      (should (string-match-p "runDesktopComposeUiTest" script))
      (should-not (string-match-p "ImageComposeScene" script)))))

(provide 'compose-preview-tests)

;;; compose-preview-tests.el ends here
