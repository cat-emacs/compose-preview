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
             (lambda () "/tmp/emacs-studio/compose-preview/preview.init.gradle"))
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
                     :variant "demoDebug"
                     :application-id "com.example"
                     :source-roots '("src/commonMain/kotlin")))))
    (let ((compose-preview--target-cache nil)
          (buffer-file-name
           "/tmp/project/composeApp/src/commonMain/kotlin/example/Foo.kt"))
      (should
       (equal
        (compose-preview--target)
        (list :project-root "/tmp/project/"
              :module-root "/tmp/project/composeApp/"
              :module-path ":composeApp"
              :variant "demoDebug"))))))

(provide 'compose-preview-tests)

;;; compose-preview-tests.el ends here
