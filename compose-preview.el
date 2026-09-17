;;; compose-preview.el --- Android Studio Compose previews -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.3.0"))
;; URL: https://github.com/cat-emacs/compose-preview
;; Keywords: tools android kotlin compose

;;; Commentary:

;; Discover and render Compose @Preview functions with Android Studio's
;; standalone layoutlib renderer, then show the resulting images in Emacs.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'android-mode nil t)

(defconst compose-preview--package-directory
  (file-name-directory
   (or load-file-name
       (locate-library "compose-preview")
       buffer-file-name
       default-directory))
  "Directory containing compose-preview package files.")

(declare-function android--flavor-variants "android-mode" (module))
(declare-function android--select-module "android-mode" ())
(declare-function android--target-for-source-file "android-mode" (file project-root))

(defgroup compose-preview nil
  "Preview Jetpack Compose @Preview functions with layoutlib."
  :group 'tools
  :prefix "compose-preview-")

(defcustom compose-preview-default-variant "debug"
  "Android build variant used for preview rendering."
  :type 'string
  :group 'compose-preview)

(defcustom compose-preview-layoutlib-version "16.1.0-jdk17"
  "Version of the Android Studio layoutlib artifacts."
  :type 'string
  :group 'compose-preview)

(defcustom compose-preview-renderer-version "0.0.1-alpha16"
  "Version of Android Studio's standalone Compose preview renderer."
  :type 'string
  :group 'compose-preview)

(defcustom compose-preview-detector-version "32.5.0-alpha05"
  "Version of Android Studio's Compose preview detector."
  :type 'string
  :group 'compose-preview)

(defcustom compose-preview-image-width 420
  "Pixel width used for images in the Compose preview panel."
  :type 'integer
  :group 'compose-preview)

(defcustom compose-preview-panel-width 0.4
  "Width of the Compose preview side window.
A float means a fraction of the frame width; an integer means columns."
  :type '(choice (float :tag "Frame fraction")
                 (integer :tag "Columns"))
  :group 'compose-preview)

(defcustom compose-preview-auto-refresh-delay 0.75
  "Seconds to debounce preview rendering after saving a source buffer."
  :type 'number
  :group 'compose-preview)

(defcustom compose-preview-use-android-mode-flavors t
  "Whether to reuse android-mode's module and variant discovery."
  :type 'boolean
  :group 'compose-preview)

(defcustom compose-preview-force-clean-build nil
  "Whether preview preparation should disable incremental build caches."
  :type 'boolean
  :group 'compose-preview)

(defcustom compose-preview-cache-directory
  (expand-file-name "compose-preview/"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache/" "~")))
  "Directory used for the compiled renderer launcher."
  :type 'directory
  :group 'compose-preview)

(defvar compose-preview-results-buffer-name "*compose-preview-results*")
(defvar compose-preview-log-buffer-name "*compose-preview-log*"
  "Buffer name used for background compose-preview Gradle output.")
(defvar compose-preview--last-results-directory nil
  "Directory containing the most recently rendered preview images.")

(defvar compose-preview--last-result-items nil
  "Items from the most recent preview render.")

(defvar compose-preview--last-source-buffer nil
  "Source buffer associated with the most recent preview render.")

(defvar compose-preview--process nil
  "Current asynchronous Compose preview process.")

(defvar compose-preview--generation 0
  "Generation used to ignore stale asynchronous process sentinels.")

(defvar-local compose-preview--source-buffer nil
  "Source buffer associated with a Compose preview results buffer.")

(defvar-local compose-preview--refresh-timer nil
  "Pending automatic refresh timer for this source buffer.")

(defvar-local compose-preview-auto-refresh-mode nil
  "Non-nil when automatic Compose preview refresh is enabled.")

(defvar compose-preview--refresh-all-in-file nil
  "When non-nil, do not narrow rendering to the preview at point.")

(defvar compose-preview--target-cache nil
  "Project-level target cache.
Each entry is (PROJECT-ROOT . TARGET), where TARGET is a plist containing
:project-root, :module-root, :module-path and :variant.")

(defvar compose-preview--metadata-refresh-roots nil
  "Project roots whose stale Android preview metadata was refreshed.")

(defun compose-preview--log (format-string &rest args)
  "Log compose-preview message FORMAT-STRING with ARGS."
  (let ((line (apply #'format (concat "compose-preview: " format-string) args)))
    (message "%s" line)
    (when-let* ((buffer (get-buffer compose-preview-log-buffer-name)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert line "\n"))))))

(cl-defstruct compose-preview-item
  id
  declaring-class
  method
  name
  preview-name
  group
  source-file
  files)

(defvar compose-preview-results-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'compose-preview-panel-refresh)
    (define-key map (kbd "l") #'compose-preview-open-log)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `compose-preview-results-mode'.")

(define-derived-mode compose-preview-results-mode special-mode "ComposePreview"
  "Major mode for browsing Compose preview images."
  :group 'compose-preview)

(defun compose-preview-open-log ()
  "Show the Compose preview build and renderer log."
  (interactive)
  (display-buffer (get-buffer-create compose-preview-log-buffer-name)))

(defun compose-preview-panel-refresh ()
  "Refresh previews from the source buffer associated with this panel."
  (interactive)
  (let ((source compose-preview--source-buffer))
    (unless (buffer-live-p source)
      (user-error "The Compose preview source buffer is no longer available"))
    (with-current-buffer source
      (compose-preview-refresh))))

(defun compose-preview--cancel-refresh-timer ()
  "Cancel the current buffer's pending automatic preview refresh."
  (when (timerp compose-preview--refresh-timer)
    (cancel-timer compose-preview--refresh-timer))
  (setq compose-preview--refresh-timer nil))

(defun compose-preview--auto-refresh-buffer (buffer)
  "Refresh previews for source BUFFER when it is still eligible."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq compose-preview--refresh-timer nil)
      (when compose-preview-auto-refresh-mode
        (let ((compose-preview--refresh-all-in-file t))
          (compose-preview-refresh))))))

(defun compose-preview--schedule-auto-refresh ()
  "Schedule a debounced refresh after saving the current source buffer."
  (compose-preview--cancel-refresh-timer)
  (let ((buffer (current-buffer)))
    (setq compose-preview--refresh-timer
          (run-with-timer compose-preview-auto-refresh-delay nil
                          #'compose-preview--auto-refresh-buffer buffer))))

;;;###autoload
(define-minor-mode compose-preview-auto-refresh-mode
  "Automatically refresh the Compose preview panel after saving this buffer."
  :lighter " Preview"
  (if compose-preview-auto-refresh-mode
      (add-hook 'after-save-hook #'compose-preview--schedule-auto-refresh nil t)
    (remove-hook 'after-save-hook #'compose-preview--schedule-auto-refresh t)
    (compose-preview--cancel-refresh-timer)))

(defun compose-preview-read-variant ()
  "Read an Android variant name for preview rendering."
  (read-string "Compose preview variant: " compose-preview-default-variant))

(defun compose-preview--find-project-root ()
  "Return the current Gradle project root."
  (when-let* ((root (locate-dominating-file default-directory "gradlew")))
    (file-name-as-directory (expand-file-name root))))

(defun compose-preview--gradle-build-file-p (dir)
  "Return non-nil when DIR has a Gradle build file."
  (or (file-exists-p (expand-file-name "build.gradle" dir))
      (file-exists-p (expand-file-name "build.gradle.kts" dir))))

(defun compose-preview--find-module-root ()
  "Return the nearest Gradle module root for `default-directory'."
  (when-let* ((root (locate-dominating-file
                    default-directory
                    (lambda (dir)
                      (compose-preview--gradle-build-file-p dir)))))
    (file-name-as-directory (expand-file-name root))))

(defun compose-preview--module-path (project-root module-root)
  "Return Gradle project path for MODULE-ROOT under PROJECT-ROOT."
  (let ((relative (file-relative-name module-root project-root)))
    (if (or (string= relative "./") (string= relative "."))
        ":"
      (concat ":" (string-join (split-string (directory-file-name relative) "/" t)
                               ":")))))

(defun compose-preview--module-name (module-path)
  "Return android-mode module name for MODULE-PATH."
  (string-remove-prefix ":" module-path))

(defun compose-preview--module-root-from-name (project-root module-name)
  "Return module root under PROJECT-ROOT for android-mode MODULE-NAME."
  (file-name-as-directory
   (expand-file-name
    (replace-regexp-in-string ":" "/" module-name)
    project-root)))

(defun compose-preview--target-from-android-mode (project-root)
  "Return current source target from android-mode metadata under PROJECT-ROOT."
  (when (and compose-preview-use-android-mode-flavors
             buffer-file-name
             (fboundp 'android--target-for-source-file))
    (when-let* ((target (ignore-errors
                         (android--target-for-source-file
                          buffer-file-name project-root))))
      (list :project-root project-root
            :module-root (file-name-as-directory
                          (plist-get target :module-root))
            :module-path (plist-get target :module-path)
            :variant (plist-get target :variant)
            :preview-task (plist-get target :preview-task)))))

(defun compose-preview--refresh-stale-kmp-target (project-root target)
  "Refresh stale Android KMP TARGET metadata under PROJECT-ROOT once."
  (if (and target
           (string= (plist-get target :variant) "androidMain")
           (not (string= (plist-get target :preview-task) "desktopTest"))
           (fboundp 'android--get-flavors)
           (not (member project-root compose-preview--metadata-refresh-roots)))
      (progn
        (push project-root compose-preview--metadata-refresh-roots)
        (compose-preview--log
         "refreshing stale Android KMP preview metadata for %s" project-root)
        (ignore-errors
          (let ((default-directory project-root))
            (android--get-flavors t)))
        (or (compose-preview--target-from-android-mode project-root) target))
    target))

(defun compose-preview--sanitize (value)
  "Return Gradle-side sanitized VALUE."
  (replace-regexp-in-string "[^A-Za-z0-9_]" "_" value))

(defun compose-preview--cache-key (project-root)
  "Return normalized cache key for PROJECT-ROOT."
  (directory-file-name (expand-file-name project-root)))

(defun compose-preview--cached-target (project-root)
  "Return cached preview target for PROJECT-ROOT."
  (cdr (assoc (compose-preview--cache-key project-root)
              compose-preview--target-cache)))

(defun compose-preview--cache-target (target)
  "Cache TARGET for its project root and return TARGET."
  (let* ((project-root (plist-get target :project-root))
         (key (compose-preview--cache-key project-root))
         (entry (assoc key compose-preview--target-cache)))
    (if entry
        (setcdr entry target)
      (push (cons key target) compose-preview--target-cache))
    target))

(defun compose-preview--capitalize-variant (variant)
  "Return VARIANT with the first character upper-cased for Gradle task names."
  (concat (upcase (substring variant 0 1)) (substring variant 1)))

(defun compose-preview--uncapitalize-variant (variant)
  "Return VARIANT with the first character lower-cased."
  (concat (downcase (substring variant 0 1)) (substring variant 1)))

(defun compose-preview--get-init-script ()
  "Return the absolute path to the layoutlib Gradle init script."
  (expand-file-name "preview.init.gradle" compose-preview--package-directory))

(defun compose-preview--gradle-executable (project-root)
  "Return the Gradle executable for PROJECT-ROOT."
  (let ((wrapper (expand-file-name "gradlew" project-root)))
    (if (file-executable-p wrapper)
        wrapper
      "gradle")))

(defun compose-preview--task-path (module-path task-name)
  "Return a Gradle task path for MODULE-PATH and TASK-NAME."
  (if (string= module-path ":")
      task-name
    (concat module-path ":" task-name)))

(defun compose-preview--current-package ()
  "Return Kotlin package name in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           "^[[:space:]]*package[[:space:]]+\\([A-Za-z_][A-Za-z0-9_.]*\\)"
           nil t)
      (match-string-no-properties 1))))

(defun compose-preview--current-buffer-class-prefix ()
  "Return scanner declaring class prefix for the current Kotlin buffer."
  (when-let* ((file buffer-file-name)
              ((string-match-p "\\.kt\\'" file)))
    (let ((package (compose-preview--current-package))
          (facade (concat (file-name-base file) "Kt")))
      (if (and package (not (string-empty-p package)))
          (concat package "." facade)
        facade))))

(defun compose-preview--source-file-class-prefix (file)
  "Return scanner declaring class prefix for Kotlin source FILE."
  (when (and file (file-readable-p file) (string-match-p "\\.kt\\'" file))
    (with-temp-buffer
      (insert-file-contents file)
      (setq-local buffer-file-name file)
      (compose-preview--current-buffer-class-prefix))))

(defun compose-preview--looking-at-preview-annotation-p ()
  "Return non-nil when point is at a Compose @Preview annotation."
  (looking-at-p
   "[[:space:]]*@\\(?:[A-Za-z_][A-Za-z0-9_.]*\\.\\)?Preview\\(?:[[:space:]]*(\\|\\_>\\)"))

(defconst compose-preview--kotlin-function-regexp
  "^[[:space:]]*\\(?:\\(?:private\\|internal\\|public\\)[[:space:]]+\\)?fun[[:space:]]+\\([A-Za-z_][A-Za-z0-9_]*\\)[[:space:]]*("
  "Regexp matching a Kotlin function declaration.")

(defun compose-preview--function-has-preview-annotation-p (function-start)
  "Return non-nil when FUNCTION-START is preceded by @Preview."
  (save-excursion
    (goto-char function-start)
    (let ((continue t)
          found)
      (while continue
        (forward-line -1)
        (cond
         ((compose-preview--looking-at-preview-annotation-p)
          (setq found t
                continue nil))
         ((looking-at-p "[[:space:]]*@")
          nil)
         ((looking-at-p "[[:space:]]*$")
          nil)
         (t
          (setq continue nil))))
      found)))

(defun compose-preview--kotlin-owner-in-region (start end)
  "Return Kotlin owner declaration between START and END."
  (save-excursion
    (goto-char start)
    (let (owner)
      (while (re-search-forward
              "\\_<\\(companion[[:space:]]+object\\|class\\|interface\\|object\\)\\_>\\(?:[[:space:]]+\\([A-Za-z_][A-Za-z0-9_]*\\)\\)?"
              end t)
        (setq owner
              (if (string= (match-string-no-properties 1) "companion object")
                  (or (match-string-no-properties 2) "Companion")
                (match-string-no-properties 2))))
      owner)))

(defun compose-preview--enclosing-kotlin-owners (position)
  "Return JVM owner names enclosing Kotlin source POSITION."
  (save-excursion
    (goto-char (point-min))
    (let ((segment-start (point-min))
          stack)
      (while (re-search-forward "[{}]" position t)
        (let* ((brace (match-beginning 0))
               (state (save-excursion (syntax-ppss brace))))
          (unless (or (nth 3 state) (nth 4 state))
            (if (eq (char-after brace) ?{)
                (push (compose-preview--kotlin-owner-in-region
                       segment-start brace)
                      stack)
              (when stack
                (pop stack)))
            (setq segment-start (1+ brace)))))
      (nreverse (delq nil stack)))))

(defun compose-preview--current-preview-method-fqn ()
  "Return fully qualified JVM name of the Compose Preview at point."
  (when (and buffer-file-name (string-match-p "\\.kt\\'" buffer-file-name))
    (save-excursion
      (end-of-line)
      (when (re-search-backward compose-preview--kotlin-function-regexp nil t)
        (let ((function-start (point))
              (method (match-string-no-properties 1)))
          (when (compose-preview--function-has-preview-annotation-p function-start)
            (let* ((package (compose-preview--current-package))
                   (owners (compose-preview--enclosing-kotlin-owners function-start))
                   (declaring-class
                    (if owners
                        (string-join owners "$")
                      (concat (file-name-base buffer-file-name) "Kt"))))
              (string-join (delq nil (list package declaring-class method)) "."))))))))

(defun compose-preview--current-preview-method ()
  "Return the containing Compose @Preview function name at point."
  (when (and buffer-file-name (string-match-p "\\.kt\\'" buffer-file-name))
    (save-excursion
      (end-of-line)
      (when (re-search-backward compose-preview--kotlin-function-regexp nil t)
        (let ((function-start (point))
              (name (match-string-no-properties 1)))
          (when (compose-preview--function-has-preview-annotation-p
                 function-start)
            name))))))

(defun compose-preview--android-flavors-available-p ()
  "Return non-nil when android-mode flavor helpers are available."
  (and compose-preview-use-android-mode-flavors
       (fboundp 'android--get-flavors)
       (fboundp 'android--select-module)
       (fboundp 'android--select-variant)))

(defun compose-preview--android-variants (module)
  "Return android-mode variants for MODULE, or nil."
  (when (and (compose-preview--android-flavors-available-p)
             (fboundp 'android--flavor-variants))
    (ignore-errors
      (android--flavor-variants module))))

(defun compose-preview--android-target-for-module (project-root module variant)
  "Return android-mode target metadata for PROJECT-ROOT, MODULE and VARIANT."
  (when (and (compose-preview--android-flavors-available-p)
             (fboundp 'android--get-flavors))
    (let* ((entries (ignore-errors
                      (let ((default-directory project-root))
                        (android--get-flavors))))
           (module-entries
            (seq-filter
             (lambda (candidate)
               (and (keywordp (car-safe candidate))
                    (string= (plist-get candidate :module-name) module)))
             entries)))
      (when-let* ((entry (or (seq-find
                             (lambda (candidate)
                               (string= (plist-get candidate :variant) variant))
                             module-entries)
                            (car module-entries))))
        (list :project-root project-root
              :module-root (file-name-as-directory
                            (plist-get entry :module-root))
              :module-path (plist-get entry :module-path)
              :variant (plist-get entry :variant)
              :preview-task (plist-get entry :preview-task))))))

(defun compose-preview--read-variant-for-module (module force-prompt)
  "Return a variant for MODULE.
When FORCE-PROMPT is non-nil, prompt with android-mode when possible."
  (if noninteractive
      compose-preview-default-variant
    (if (compose-preview--android-flavors-available-p)
      (let ((variants (compose-preview--android-variants module)))
        (cond
         ((and (not force-prompt)
               (member compose-preview-default-variant variants))
          compose-preview-default-variant)
         ((and variants (= (length variants) 1))
          (car variants))
         (variants
          (completing-read (format "Variant (%s): " module)
                           variants nil t nil nil
                           (or (car variants) compose-preview-default-variant)))
         (t
          (compose-preview-read-variant))))
      (compose-preview-read-variant))))

(defun compose-preview--target (&optional force-prompt)
  "Return plist describing the preview target.
When FORCE-PROMPT is non-nil, prompt for module and variant via android-mode."
  (let* ((project-root (or (compose-preview--find-project-root)
                           (user-error "Could not find project root: no gradlew")))
         (metadata-target
          (and (not force-prompt)
               (compose-preview--refresh-stale-kmp-target
                project-root
                (compose-preview--target-from-android-mode project-root))))
         (cached (compose-preview--cached-target project-root)))
    (if metadata-target
        (progn
          (compose-preview--log
           "selected target from android-mode module=%s variant=%s module-root=%s project-root=%s"
           (plist-get metadata-target :module-path)
           (plist-get metadata-target :variant)
           (plist-get metadata-target :module-root)
           project-root)
          (compose-preview--cache-target metadata-target))
      (if (and cached (not force-prompt))
          (let* ((module-name (compose-preview--module-name
                               (plist-get cached :module-path)))
                 (android-target
                  (compose-preview--android-target-for-module
                   project-root module-name (plist-get cached :variant))))
            (if android-target
                (progn
                  (compose-preview--log
                   "using android-mode target module=%s variant=%s module-root=%s root=%s"
                   (plist-get android-target :module-path)
                   (plist-get android-target :variant)
                   (plist-get android-target :module-root)
                   project-root)
                  (compose-preview--cache-target android-target))
              (compose-preview--log "using cached target module=%s variant=%s root=%s"
                                    (plist-get cached :module-path)
                                    (plist-get cached :variant)
                                    project-root)
              cached))
        (let* ((module-root (or (compose-preview--find-module-root)
                                (user-error "Could not find module root: no build.gradle(.kts)")))
               (module-path (compose-preview--module-path project-root module-root))
               (module-name (compose-preview--module-name module-path))
               variant)
          (when (and force-prompt (compose-preview--android-flavors-available-p))
            (setq module-name (android--select-module)
                  module-path (concat ":" module-name)))
          (setq variant (compose-preview--read-variant-for-module
                         module-name force-prompt))
          (or (when-let* ((android-target
                          (compose-preview--android-target-for-module
                           project-root module-name variant)))
                (compose-preview--log
                 "selected target from android-mode module=%s variant=%s module-root=%s project-root=%s"
                 (plist-get android-target :module-path)
                 (plist-get android-target :variant)
                 (plist-get android-target :module-root)
                 project-root)
                (compose-preview--cache-target android-target))
              (progn
                (when force-prompt
                  (setq module-root (compose-preview--module-root-from-name
                                     project-root module-name)))
                (compose-preview--log "selected target module=%s module-root=%s project-root=%s"
                                      module-path module-root project-root)
                (compose-preview--cache-target
                 (list :project-root project-root
                       :module-root module-root
                       :module-path module-path
                       :variant variant)))))))))

(defun compose-preview--json-get (object key)
  "Return KEY from JSON alist OBJECT."
  (alist-get key object nil nil #'string=))

(defun compose-preview--read-json (file)
  "Read JSON FILE as alists and lists."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'string)
        (json-false nil))
    (json-read-file file)))

(defun compose-preview--write-json (file object)
  "Write OBJECT as JSON to FILE."
  (make-directory (file-name-directory file) t)
  (let ((json-encoding-pretty-print t))
    (with-temp-file file
      (insert (json-encode object)))))

(defun compose-preview--work-directory (target)
  "Return generated preview directory for TARGET."
  (expand-file-name "build/compose-preview/emacs/"
                    (plist-get target :module-root)))

(defun compose-preview--model-file (target &optional generation)
  "Return model file for TARGET and optional GENERATION."
  (expand-file-name (if generation
                        (format "model-%s.json" generation)
                      "model.json")
                    (compose-preview--work-directory target)))

(defun compose-preview--source-file-package (file)
  "Return Kotlin package declared in FILE."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (compose-preview--current-package))))

(defun compose-preview--function-names-in-file (file)
  "Return Kotlin function names declared in FILE."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let (names)
        (goto-char (point-min))
        (while (re-search-forward compose-preview--kotlin-function-regexp nil t)
          (push (match-string-no-properties 1) names))
        (delete-dups names)))))

(defun compose-preview--source-declaring-prefixes (file)
  "Return possible JVM declaring class prefixes for Kotlin source FILE."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (setq-local buffer-file-name file)
      (let* ((package (compose-preview--current-package))
             (qualify (lambda (name)
                        (if (and package (not (string-empty-p package)))
                            (concat package "." name)
                          name)))
             (prefixes (list (compose-preview--current-buffer-class-prefix))))
        (goto-char (point-min))
        (while (re-search-forward
                "^[[:space:]]*\\(?:[[:word:]]+[[:space:]]+\\)*\\(?:class\\|interface\\|object\\)[[:space:]]+\\([A-Za-z_][A-Za-z0-9_]*\\)"
                nil t)
          (push (funcall qualify (match-string-no-properties 1)) prefixes))
        (delete-dups (delq nil prefixes))))))

(defun compose-preview--preview-method-name (preview)
  "Return method name from model PREVIEW."
  (car (last (split-string (compose-preview--json-get preview "methodFQN") "\\." t))))

(defun compose-preview--select-model-previews (model source-file method)
  "Select MODEL previews for SOURCE-FILE and optional METHOD.
METHOD may be an unqualified name or a full JVM method name."
  (let* ((previews (compose-preview--json-get model "previews"))
         (source-name (and source-file (file-name-nondirectory source-file)))
         (package (compose-preview--source-file-package source-file))
         (prefixes (compose-preview--source-declaring-prefixes source-file))
         (names (compose-preview--function-names-in-file source-file)))
    (seq-filter
     (lambda (preview)
       (let ((fqn (compose-preview--json-get preview "methodFQN"))
             (model-source (compose-preview--json-get preview "sourceFile"))
             (name (compose-preview--preview-method-name preview)))
         (and (or (null package)
                  (string-prefix-p (concat package ".") fqn))
              (or (null source-name)
                  (and model-source (string= model-source source-name))
                  (and (null model-source)
                       (seq-some (lambda (prefix)
                                   (string-prefix-p (concat prefix ".") fqn))
                                 prefixes)))
              (or (null names) (member name names))
              (or (null method)
                  (if (string-match-p "\\." method)
                      (string= fqn method)
                    (string= name method))))))
     previews)))

(defun compose-preview--library-directory ()
  "Return directory containing compose-preview package files."
  compose-preview--package-directory)

(defun compose-preview--launcher-directory ()
  "Return cache directory for the compiled renderer launcher."
  (expand-file-name (concat "launcher-" compose-preview-renderer-version "/")
                    compose-preview-cache-directory))

(defun compose-preview--launcher-spec (model)
  "Return launcher compilation and cache details for MODEL."
  (let* ((source (expand-file-name "ComposePreviewRenderLauncher.java"
                                   (compose-preview--library-directory)))
         (directory (compose-preview--launcher-directory))
         (class-file (expand-file-name "ComposePreviewRenderLauncher.class" directory))
         (java (compose-preview--json-get model "javaExecutable"))
         (javac (expand-file-name "javac" (file-name-directory java)))
         (classpath (string-join
                     (compose-preview--json-get model "rendererClassPath")
                     path-separator)))
    (list :source source :directory directory :class-file class-file
          :javac javac :classpath classpath
          :current (and (file-readable-p class-file)
                        (file-newer-than-file-p class-file source)))))

(defun compose-preview--preview-id (preview annotation index)
  "Return stable id for PREVIEW ANNOTATION at INDEX."
  (let ((name (compose-preview--json-get annotation "name")))
    (concat (compose-preview--json-get preview "methodFQN") "_"
            (compose-preview--sanitize (or name (number-to-string index))))))

(defun compose-preview--render-settings (model previews target &optional generation)
  "Write renderer settings for MODEL PREVIEWS and TARGET.
Use GENERATION to isolate concurrent or superseded render attempts."
  (let* ((root (compose-preview--work-directory target))
         (suffix (if generation (format "-%s" generation) ""))
         (output (expand-file-name (format "rendered%s/" suffix) root))
         (settings-file (expand-file-name (format "settings%s.json" suffix) root))
         (results-file (expand-file-name (format "results%s.json" suffix) root))
         screenshots)
    (when (file-directory-p output)
      (delete-directory output t))
    (make-directory output t)
    (dolist (preview previews)
      (cl-loop for annotation in (compose-preview--json-get preview "annotations")
               for index from 0
               do (let ((entry
                         `(("previewType" . "COMPOSE")
                           ("methodFQN" . ,(compose-preview--json-get preview "methodFQN"))
                           ("previewId" . ,(compose-preview--preview-id preview annotation index))
                           ("methodParams" . ,(vconcat (compose-preview--json-get preview "methodParams")))
                           ("previewParams" . ,(or annotation
                                                    (make-hash-table :test #'equal))))))
                    (when-let* ((wrapper (compose-preview--json-get preview "previewWrapperFQN")))
                      (push (cons "previewWrapperFqn" wrapper) entry))
                    (push entry screenshots))))
    (compose-preview--write-json
     settings-file
     `(("layoutlibPath" . ,(compose-preview--json-get model "layoutlibPath"))
       ("fontsPath" . ,(compose-preview--json-get model "fontsPath"))
       ("outputFolder" . ,output)
       ("metaDataFolder" . ,(expand-file-name "metadata/" root))
       ("classPath" . ,(vconcat (compose-preview--json-get model "classPath")))
       ("projectClassPath" . ,(vconcat (compose-preview--json-get model "projectClassPath")))
       ("rClassJars" . ,(vconcat (compose-preview--json-get model "rClassJars")))
       ("resourceDirs" . [])
       ("namespace" . ,(compose-preview--json-get model "namespace"))
       ("resourceApkPath" . ,(compose-preview--json-get model "resourceApkPath"))
       ("resultsFilePath" . ,results-file)
       ("screenshots" . ,(vconcat (nreverse screenshots)))))
    (list :settings settings-file :results results-file :output output)))

(defun compose-preview--insert-image (file)
  "Insert FILE as an image preview when Emacs can display it."
  (if (and (display-images-p)
           (image-type-available-p 'png))
      (condition-case err
          (insert-image
           (create-image file 'png nil :width compose-preview-image-width))
        (error
         (insert (format "Could not render image: %s" (error-message-string err)))))
    (insert "Image display is not available in this Emacs session.")))

(defun compose-preview--display-panel (buffer)
  "Display BUFFER in the Compose preview side window."
  (display-buffer-in-side-window
   buffer
   `((side . right)
     (slot . 0)
     (window-width . ,compose-preview-panel-width))))

(defun compose-preview--panel-status (source-buffer module-root status &optional face)
  "Show STATUS for SOURCE-BUFFER and MODULE-ROOT in the preview panel."
  (let ((buffer (get-buffer-create compose-preview-results-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'compose-preview-results-mode)
        (compose-preview-results-mode))
      (setq-local compose-preview--source-buffer source-buffer
                  default-directory module-root
                  header-line-format (propertize (concat " Compose Preview: " status)
                                                  'face (or face 'mode-line-emphasis)))
      (when (= (buffer-size) 0)
        (let ((inhibit-read-only t))
          (insert "Compose Preview\n\nWaiting for the first render...\n"))))
    (compose-preview--display-panel buffer)))

(defun compose-preview--render-results (module-root images &optional previews source-buffer)
  "Render IMAGES and PREVIEWS for MODULE-ROOT in the preview panel."
  (let ((buffer (get-buffer-create compose-preview-results-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (compose-preview-results-mode)
        (setq-local compose-preview--source-buffer source-buffer
                    default-directory module-root
                    header-line-format (propertize " Compose Preview: ready"
                                                    'face 'success))
        (insert (format "Compose Preview  %s\n\n" module-root))
        (dolist (preview previews)
          (when-let* ((files (compose-preview-item-files preview)))
            (insert (propertize (compose-preview-item-name preview) 'face 'bold) "\n")
            (dolist (file files)
              (insert-button "open image" 'follow-link t
                             'action (lambda (_button) (find-file file)))
              (insert "\n")
              (compose-preview--insert-image file)
              (insert "\n"))
            (insert "\n")))
        (unless previews
          (dolist (file images)
            (insert (file-relative-name file module-root) "\n")
            (compose-preview--insert-image file)
            (insert "\n\n")))))
    (compose-preview--display-panel buffer)))

(defun compose-preview-open-results (&optional module-root previews _source-file)
  "Open the most recently rendered Compose previews.
MODULE-ROOT and PREVIEWS are accepted for compatibility with older callers."
  (interactive)
  (let ((root (or module-root
                  (compose-preview--find-module-root)
                  default-directory))
        (items (or previews compose-preview--last-result-items)))
    (if items
        (compose-preview--render-results
         root
         (apply #'append (mapcar #'compose-preview-item-files items))
         items compose-preview--last-source-buffer)
      (user-error "No Compose preview results are available"))))

(defun compose-preview--active-generation-p (generation)
  "Return non-nil when GENERATION is the current refresh."
  (= generation compose-preview--generation))

(defun compose-preview--fail (context format-string &rest args)
  "Report a preview failure described by CONTEXT.
FORMAT-STRING and ARGS are passed to `format'."
  (let* ((source (plist-get context :source-buffer))
         (target (plist-get context :target))
         (message (apply #'format format-string args)))
    (compose-preview--panel-status source (plist-get target :module-root)
                                   (concat "failed — " message) 'error)
    (compose-preview--log "%s" message)))

(defun compose-preview--result-items (results output)
  "Convert renderer RESULTS into preview items rooted at OUTPUT."
  (mapcar
   (lambda (result)
     (let* ((fqn (compose-preview--json-get result "methodFQN"))
            (path (compose-preview--json-get result "imagePath"))
            (id (compose-preview--json-get result "previewId"))
            (suffix (string-remove-prefix (concat fqn "_") id))
            (name (car (last (split-string fqn "\\." t))))
            (label (if (string-match-p "\\`[0-9]+\\'" suffix)
                       name
                     (format "%s - %s" name
                             (replace-regexp-in-string "_+" " " suffix)))))
       (make-compose-preview-item
        :id id :name label
        :declaring-class (string-join (butlast (split-string fqn "\\." t)) ".")
        :method name
        :files (and path (list (expand-file-name path output))))))
   results))

(defun compose-preview--finish-render (context)
  "Read renderer output and update the panel for CONTEXT."
  (let* ((render (plist-get context :render))
         (results (compose-preview--read-json (plist-get render :results)))
         (global-error (compose-preview--json-get results "globalError"))
         (result-list (compose-preview--json-get results "screenshotResults"))
         (failed (seq-filter
                  (lambda (result) (compose-preview--json-get result "error"))
                  result-list)))
    (cond
     (global-error
      (compose-preview--fail context "renderer failed: %s" global-error))
     (failed
      (compose-preview--fail context "%d preview images failed; press l for the log"
                             (length failed)))
     (t
      (let* ((target (plist-get context :target))
             (source (plist-get context :source-buffer))
             (items (compose-preview--result-items
                     result-list (plist-get render :output))))
        (setq compose-preview--last-results-directory (plist-get render :output)
              compose-preview--last-result-items items
              compose-preview--last-source-buffer source)
        (compose-preview--render-results
         (plist-get target :module-root)
         (apply #'append (mapcar #'compose-preview-item-files items))
         items source)
        (compose-preview--log "rendered %d preview images" (length result-list)))))))

(defun compose-preview--render-sentinel (process _event)
  "Handle completion of asynchronous renderer PROCESS."
  (when (memq (process-status process) '(exit signal))
    (let* ((context (process-get process 'compose-preview-context))
           (generation (plist-get context :generation)))
      (when (compose-preview--active-generation-p generation)
        (setq compose-preview--process nil)
        (if (zerop (process-exit-status process))
            (condition-case err
                (compose-preview--finish-render context)
              (error (compose-preview--fail context "%s" (error-message-string err))))
          (compose-preview--fail context "renderer process exited with status %d"
                                 (process-exit-status process)))))))

(defun compose-preview--launch-renderer (context)
  "Launch the layoutlib renderer described by CONTEXT."
  (let* ((model (plist-get context :model))
         (previews (plist-get context :previews))
         (render (plist-get context :render))
         (launcher (plist-get context :launcher))
         (target (plist-get context :target))
         (log-buffer (plist-get context :log-buffer))
         (java (compose-preview--json-get model "javaExecutable"))
         (renderer-cp (compose-preview--json-get model "rendererClassPath"))
         (classpath (string-join
                     (cons (plist-get launcher :directory) renderer-cp)
                     path-separator))
         (java-home (file-name-directory
                     (directory-file-name (file-name-directory java))))
         (process-environment
          (cons (concat "JAVA_HOME=" java-home) process-environment))
         (default-directory (plist-get target :project-root))
         (process
          (make-process
           :name "compose-preview-renderer"
           :buffer log-buffer :stderr log-buffer :noquery t
           :command (list java "-Dlayoutlib.thread.profile.timeoutms=10000"
                          "-cp" classpath "ComposePreviewRenderLauncher"
                          (plist-get render :settings))
           :sentinel #'ignore)))
    (setq compose-preview--process process)
    (process-put process 'compose-preview-context context)
    (set-process-sentinel process #'compose-preview--render-sentinel)
    (compose-preview--panel-status
     (plist-get context :source-buffer) (plist-get target :module-root)
     (format "rendering %d declarations…" (length previews)))))

(defun compose-preview--launcher-sentinel (process _event)
  "Continue rendering after asynchronous launcher compiler PROCESS."
  (when (memq (process-status process) '(exit signal))
    (let* ((context (process-get process 'compose-preview-context))
           (generation (plist-get context :generation)))
      (when (compose-preview--active-generation-p generation)
        (setq compose-preview--process nil)
        (if (zerop (process-exit-status process))
            (compose-preview--launch-renderer context)
          (compose-preview--fail context "launcher compiler exited with status %d"
                                 (process-exit-status process)))))))

(defun compose-preview--compile-launcher (context)
  "Compile the renderer launcher asynchronously for CONTEXT."
  (let* ((launcher (plist-get context :launcher))
         (target (plist-get context :target))
         (log-buffer (plist-get context :log-buffer))
         (directory (plist-get launcher :directory))
         (default-directory (plist-get target :project-root)))
    (make-directory directory t)
    (with-current-buffer log-buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n$ %s -cp %s -d %s %s\n"
                        (plist-get launcher :javac)
                        (plist-get launcher :classpath)
                        directory (plist-get launcher :source)))))
    (let ((process
           (make-process
            :name "compose-preview-launcher-compiler"
            :buffer log-buffer :stderr log-buffer :noquery t
            :command (list (plist-get launcher :javac) "-nowarn"
                           "-cp" (plist-get launcher :classpath)
                           "-d" directory (plist-get launcher :source))
            :sentinel #'ignore)))
      (setq compose-preview--process process)
      (process-put process 'compose-preview-context context)
      (set-process-sentinel process #'compose-preview--launcher-sentinel)
      (compose-preview--panel-status
       (plist-get context :source-buffer) (plist-get target :module-root)
       "compiling renderer launcher…"))))

(defun compose-preview--start-render (context)
  "Prepare and start renderer work described by CONTEXT."
  (let* ((model (compose-preview--read-json (plist-get context :model-file)))
         (source-file (plist-get context :source-file))
         (method (plist-get context :preview-method))
         (previews (compose-preview--select-model-previews model source-file method))
         (target (plist-get context :target)))
    (if (null previews)
        (compose-preview--fail context "no previews found for %s"
                               (or (and source-file (file-name-nondirectory source-file))
                                   (plist-get target :module-path)))
      (condition-case err
          (let ((launcher (compose-preview--launcher-spec model))
                (render (compose-preview--render-settings
                         model previews target (plist-get context :generation))))
            (setq context (plist-put context :model model)
                  context (plist-put context :previews previews)
                  context (plist-put context :render render)
                  context (plist-put context :launcher launcher))
            (if (plist-get launcher :current)
                (compose-preview--launch-renderer context)
              (compose-preview--compile-launcher context)))
        (error (compose-preview--fail context "%s" (error-message-string err)))))))

(defun compose-preview--gradle-failure-message (context status)
  "Return the most useful Gradle failure message for CONTEXT and STATUS."
  (let ((buffer (plist-get context :log-buffer)))
    (or (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (save-excursion
                 (goto-char (point-max))
                 (when (re-search-backward
                        "^[[:space:]]*>[[:space:]]+\\(compose-preview: .+\\)$"
                        nil t)
                   (match-string-no-properties 1)))))
        (format "Gradle preparation exited with status %d" status))))

(defun compose-preview--gradle-sentinel (process _event)
  "Start rendering after asynchronous Gradle PROCESS succeeds."
  (when (memq (process-status process) '(exit signal))
    (let* ((context (process-get process 'compose-preview-context))
           (generation (plist-get context :generation)))
      (when (compose-preview--active-generation-p generation)
        (setq compose-preview--process nil)
        (if (zerop (process-exit-status process))
            (compose-preview--start-render context)
          (compose-preview--fail
           context "%s"
           (compose-preview--gradle-failure-message
            context (process-exit-status process))))))))

;;;###autoload
(defun compose-preview-refresh (&optional variant)
  "Asynchronously build and render previews for the current Android module.
VARIANT defaults to the selected android-mode variant.  With a prefix argument,
prompt for the module and full variant name."
  (interactive)
  (let* ((source-buffer (current-buffer))
         (target (compose-preview--target current-prefix-arg))
         (variant (or variant (plist-get target :variant)))
         (source-file buffer-file-name)
         (preview-method (unless compose-preview--refresh-all-in-file
                           (compose-preview--current-preview-method-fqn)))
         (generation (cl-incf compose-preview--generation))
         (model-file (compose-preview--model-file target generation))
         (project-root (plist-get target :project-root))
         (module-path (plist-get target :module-path))
         (task-path (compose-preview--task-path module-path "composePreviewModel"))
         (gradle (compose-preview--gradle-executable project-root))
         (init-script (compose-preview--get-init-script))
         (log-buffer (get-buffer-create compose-preview-log-buffer-name))
         (process-environment
          (append
           (list (concat "COMPOSE_PREVIEW_MODULE_PATH=" module-path)
                 (concat "COMPOSE_PREVIEW_VARIANT=" variant)
                 (concat "COMPOSE_PREVIEW_MODEL_FILE=" model-file)
                 (concat "COMPOSE_PREVIEW_LAYOUTLIB_VERSION=" compose-preview-layoutlib-version)
                 (concat "COMPOSE_PREVIEW_RENDERER_VERSION=" compose-preview-renderer-version)
                 (concat "COMPOSE_PREVIEW_DETECTOR_VERSION=" compose-preview-detector-version))
           process-environment))
         (default-directory project-root)
         (gradle-args (append
                       (list task-path "--init-script" init-script)
                       (when compose-preview-force-clean-build
                         (list "--no-build-cache" "--no-parallel"))))
         context process)
    (setq target (compose-preview--cache-target (plist-put target :variant variant)))
    (when (process-live-p compose-preview--process)
      (delete-process compose-preview--process))
    (with-current-buffer log-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ %s %s\n\n" gradle (string-join gradle-args " ")))))
    (setq context (list :generation generation :target target
                        :source-buffer source-buffer :source-file source-file
                        :preview-method preview-method :model-file model-file
                        :log-buffer log-buffer)
          process (make-process
                   :name "compose-preview-gradle"
                   :buffer log-buffer :stderr log-buffer :noquery t
                   :command (cons gradle gradle-args)
                   :sentinel #'ignore)
          compose-preview--process process)
    (process-put process 'compose-preview-context context)
    (set-process-sentinel process #'compose-preview--gradle-sentinel)
    (compose-preview--panel-status source-buffer (plist-get target :module-root)
                                   (format "building %s…" variant))
    (compose-preview--log "preparing module=%s variant=%s" module-path variant)
    process))


;;;###autoload
(defun compose-preview-set-variant (variant)
  "Make VARIANT the default for future preview refreshes."
  (interactive
   (list (plist-get (compose-preview--target t) :variant)))
  (setq compose-preview-default-variant variant)
  (compose-preview--log "default variant set to %s" variant))

;; Autoload a plain command instead of the expanded prefix definition, which
;; would need `transient-prefix' at autoload evaluation time.
;;;###autoload (autoload 'compose-preview "compose-preview" nil t)
(transient-define-prefix compose-preview ()
  "Manage Jetpack Compose previews."
  ["Preview"
   ("p" "Refresh" compose-preview-refresh)
   ("P" "Open panel" compose-preview-open-results)
   ("a" "Auto refresh" compose-preview-auto-refresh-mode)
   ("l" "Open log" compose-preview-open-log)
   ("v" "Set variant" compose-preview-set-variant)])

(provide 'compose-preview)
;;; compose-preview.el ends here
