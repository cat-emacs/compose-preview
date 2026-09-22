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
(require 'button)
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

(declare-function android-current-target "android-mode"
                  (&optional prompt file project-root))
(declare-function android-project-target "android-mode"
                  (module &optional variant project-root refresh))
(declare-function android-project-targets "android-mode"
                  (&optional project-root refresh))
(declare-function android-project-variants "android-mode"
                  (&optional project-root refresh))
(declare-function android-target-for-source-file "android-mode"
                  (file &optional project-root refresh))

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

(defcustom compose-preview-panel-width 0.3
  "Width of the Compose preview side window.
A float means a fraction of the frame width; an integer means columns."
  :type '(choice (float :tag "Frame fraction")
                 (integer :tag "Columns"))
  :group 'compose-preview)

(defcustom compose-preview-show-key-hints t
  "Whether to show keybinding hints at the top of the Preview panel."
  :type 'boolean
  :group 'compose-preview)

(defcustom compose-preview-auto-refresh-delay 0.75
  "Seconds to debounce preview rendering after saving a source buffer."
  :type 'number
  :group 'compose-preview)

(defcustom compose-preview-file-switch-delay 0.25
  "Seconds to debounce preview refreshes after selecting another file."
  :type 'number
  :group 'compose-preview)

(defcustom compose-preview-follow-current-file t
  "Whether an active Preview panel should follow the selected Kotlin file."
  :type 'boolean
  :group 'compose-preview)

(defcustom compose-preview-use-android-mode-flavors t
  "Whether to reuse android-mode's module and variant discovery."
  :type 'boolean
  :group 'compose-preview)

(defcustom compose-preview-force-clean-build nil
  "Whether preview preparation should disable incremental build caches."
  :type 'boolean
  :group 'compose-preview)

(defcustom compose-preview-use-gradle-daemon t
  "Whether preview preparation should reuse a persistent Gradle daemon."
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

(defvar compose-preview--follow-active nil
  "Non-nil while the Preview panel follows selected source files.")

(defvar compose-preview--follow-buffer nil
  "Last selected source buffer observed by Preview file following.")

(defvar compose-preview--follow-timer nil
  "Pending timer for a Preview refresh after switching files.")

(defvar compose-preview--follow-refresh nil
  "Non-nil while refreshing because the selected file changed.")

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
  method-fqn
  name
  preview-name
  group
  source-file
  density-dpi
  parameter-index
  parameter-count
  parameter-name
  files
  error)

(defface compose-preview-section-heading
  '((t :inherit font-lock-function-name-face :weight bold :extend t))
  "Face for Compose Preview section headings."
  :group 'compose-preview)

(defface compose-preview-section-highlight
  '((((class color) (background light))
     :background "grey95" :extend t)
    (((class color) (background dark))
     :background "grey20" :extend t))
  "Face for the current Compose Preview section heading."
  :group 'compose-preview)

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'compose-preview-fringe>
    [#b01100000
     #b00110000
     #b00011000
     #b00001100
     #b00011000
     #b00110000
     #b01100000
     #b00000000])
  (define-fringe-bitmap 'compose-preview-fringev
    [#b00000000
     #b10000010
     #b11000110
     #b01101100
     #b00111000
     #b00010000
     #b00000000
     #b00000000]))

(defconst compose-preview--default-group "Default"
  "Display name for Preview annotations without an explicit group.")

(defvar-local compose-preview--collapsed-groups nil
  "Hash table of collapsed Preview group names in the results buffer.")

(defvar-local compose-preview--group-names nil
  "Ordered Preview group names currently rendered in the results buffer.")

(defvar-local compose-preview--group-overlays nil
  "Hash table of Preview group body overlays in the results buffer.")

(defvar-local compose-preview--group-header-overlays nil
  "Hash table of Preview group heading overlays in the results buffer.")

(defvar-local compose-preview--section-highlight-overlay nil
  "Overlay highlighting the Preview section at point.")

(defvar-local compose-preview--item-highlight-overlay nil
  "Overlay highlighting the Preview card title at point.")

(defvar-local compose-preview--items nil
  "All items available to the current Preview panel.")

(defvar-local compose-preview--module-root nil
  "Module root associated with the current Preview panel.")

(defvar-local compose-preview--status nil
  "Status text shown in the Preview panel header line.")

(defvar-local compose-preview--status-face nil
  "Face for `compose-preview--status'.")

(defvar-local compose-preview--legacy-images nil
  "Images supplied without Preview metadata to the current panel.")

(defvar-local compose-preview--view-mode 'grid
  "Current Preview panel view, either `grid' or `focus'.")
(setq-default compose-preview--view-mode 'grid)

(defvar-local compose-preview--focus-id nil
  "Stable id of the currently focused Preview item.")

(defvar-local compose-preview--search-query nil
  "Case-insensitive name filter applied to Preview items.")

(defvar-local compose-preview--group-filter nil
  "Preview group to display, or nil to display every group.")

(defvar-local compose-preview--fit-images nil
  "Non-nil when Preview images use a shared Zoom to Fit scale.")

(defvar-local compose-preview--fit-scale 1.0
  "Shared image scale computed by Zoom to Fit.")

(defvar-local compose-preview--last-layout-size nil
  "Panel pixel size used for the most recent layout.")

(defvar-local compose-preview--image-zoom 1.0
  "Image scale used when `compose-preview--fit-images' is nil.")

(defun compose-preview--grid-gap (scale)
  "Return Android Studio's responsive Grid card gap for SCALE."
  (truncate
   (cond
    ((<= scale 0.2) 5)
    ((>= scale 1.0) 15)
    (t (+ 5 (* (/ (- scale 0.2) 0.8) 10))))))

(defun compose-preview--current-image-scale ()
  "Return the scale currently applied to Preview images."
  (if compose-preview--fit-images
      compose-preview--fit-scale
    compose-preview--image-zoom))

(defvar compose-preview-results-mode-map (make-sparse-keymap)
  "Keymap for `compose-preview-results-mode'.")

(defvar compose-preview-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [tab] #'compose-preview-toggle-group)
    (define-key map (kbd "TAB") #'compose-preview-toggle-group)
    (define-key map [backtab] #'compose-preview-toggle-all-groups)
    (define-key map (kbd "<backtab>") #'compose-preview-toggle-all-groups)
    (define-key map (kbd "RET") #'compose-preview-toggle-group)
    (define-key map [mouse-1] #'compose-preview-mouse-toggle-group)
    map)
  "Keymap for Preview section headings.")

(defvar compose-preview-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map [tab] #'compose-preview-toggle-group)
    (define-key map (kbd "TAB") #'compose-preview-toggle-group)
    (define-key map [backtab] #'compose-preview-toggle-all-groups)
    (define-key map (kbd "<backtab>") #'compose-preview-toggle-all-groups)
    (define-key map (kbd "w") #'compose-preview-copy-image)
    map)
  "Button map that keeps TAB as section toggle.")

(dolist (binding
         `(([tab] . compose-preview-toggle-group)
           (,(kbd "TAB") . compose-preview-toggle-group)
           ([backtab] . compose-preview-toggle-all-groups)
           (,(kbd "<backtab>") . compose-preview-toggle-all-groups)
           (,(kbd "RET") . compose-preview-toggle-group)
           (,(kbd "o") . compose-preview-goto-source)
           (,(kbd "w") . compose-preview-copy-image)
           (,(kbd "g") . compose-preview-panel-refresh)
           (,(kbd "l") . compose-preview-open-log)
           (,(kbd "v") . compose-preview-toggle-view)
           (,(kbd "/") . compose-preview-search)
           (,(kbd "G") . compose-preview-filter-group)
           (,(kbd "n") . compose-preview-next)
           (,(kbd "p") . compose-preview-previous)
           (,(kbd "f") . compose-preview-fit)
           (,(kbd "0") . compose-preview-original-size)
           (,(kbd "+") . compose-preview-zoom-in)
           (,(kbd "=") . compose-preview-zoom-in)
           (,(kbd "-") . compose-preview-zoom-out)
           (,(kbd "q") . compose-preview-panel-quit)))
  (define-key compose-preview-results-mode-map (car binding) (cdr binding)))

(define-derived-mode compose-preview-results-mode special-mode "ComposePreview"
  "Major mode for browsing Compose preview images."
  :group 'compose-preview
  (unless (hash-table-p compose-preview--collapsed-groups)
    (setq-local compose-preview--collapsed-groups (make-hash-table :test #'equal)))
  (setq-local left-fringe-width 8
              right-fringe-width 0
              compose-preview--group-overlays (make-hash-table :test #'equal)
              compose-preview--group-header-overlays
              (make-hash-table :test #'equal))
  (add-to-invisibility-spec 'compose-preview-fold)
  (add-hook 'post-command-hook #'compose-preview--highlight-section nil t)
  (add-hook 'window-state-change-functions
            #'compose-preview--window-state-change nil t))

(defun compose-preview--cancel-follow-timer ()
  "Cancel a pending Preview refresh caused by switching files."
  (when (timerp compose-preview--follow-timer)
    (cancel-timer compose-preview--follow-timer))
  (setq compose-preview--follow-timer nil))

(defun compose-preview--kotlin-source-buffer-p (buffer)
  "Return non-nil when BUFFER visits a Kotlin source file."
  (and (buffer-live-p buffer)
       (buffer-local-value 'buffer-file-name buffer)
       (string-match-p "\\.kt\\'" (buffer-local-value 'buffer-file-name buffer))))

(defun compose-preview--hide-panel ()
  "Hide the Preview side window without ending its follow session.
Preserve the selected window because this can run from `post-command-hook'."
  (save-selected-window
    (when-let* ((window (get-buffer-window compose-preview-results-buffer-name t)))
      (quit-window nil window))))

(defun compose-preview--cancel-process ()
  "Cancel active Preview work and invalidate its sentinels."
  (cl-incf compose-preview--generation)
  (when (process-live-p compose-preview--process)
    (delete-process compose-preview--process))
  (setq compose-preview--process nil))

(defun compose-preview--follow-refresh-buffer (buffer)
  "Refresh Preview for selected Kotlin BUFFER when still current."
  (setq compose-preview--follow-timer nil)
  (when (and compose-preview--follow-active
             (eq buffer (window-buffer (selected-window)))
             (compose-preview--kotlin-source-buffer-p buffer))
    (with-current-buffer buffer
      (let ((compose-preview--follow-refresh t)
            (compose-preview--refresh-all-in-file t))
        (compose-preview-refresh)))))

(defun compose-preview--follow-selected-buffer ()
  "Update an active Preview session for the selected buffer."
  (when (and compose-preview--follow-active
             compose-preview-follow-current-file
             (not (minibufferp)))
    (let ((buffer (window-buffer (selected-window))))
      (unless (or (eq buffer compose-preview--follow-buffer)
                  (eq buffer (get-buffer compose-preview-results-buffer-name))
                  (eq buffer (get-buffer compose-preview-log-buffer-name)))
        (setq compose-preview--follow-buffer buffer)
        (compose-preview--cancel-follow-timer)
        (compose-preview--cancel-process)
        (if (compose-preview--kotlin-source-buffer-p buffer)
            (setq compose-preview--follow-timer
                  (run-with-timer compose-preview-file-switch-delay nil
                                  #'compose-preview--follow-refresh-buffer buffer))
          (compose-preview--cancel-process)
          (compose-preview--hide-panel))))))

(defun compose-preview--start-following (source-buffer)
  "Start the Preview follow session at SOURCE-BUFFER."
  (when compose-preview-follow-current-file
    (setq compose-preview--follow-active t
          compose-preview--follow-buffer source-buffer)
    (add-hook 'post-command-hook #'compose-preview--follow-selected-buffer)))

(defun compose-preview-panel-quit ()
  "Close the Preview panel and stop following selected files."
  (interactive)
  (setq compose-preview--follow-active nil
        compose-preview--follow-buffer nil)
  (compose-preview--cancel-follow-timer)
  (compose-preview--cancel-process)
  (remove-hook 'post-command-hook #'compose-preview--follow-selected-buffer)
  (quit-window))

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

(defun compose-preview--target-from-android-entry (project-root entry)
  "Return a preview target under PROJECT-ROOT from Android target ENTRY."
  (when entry
    (list :project-root project-root
          :module-root (file-name-as-directory (plist-get entry :module-root))
          :module-path (plist-get entry :module-path)
          :variant (plist-get entry :variant)
          :preview-task (plist-get entry :preview-task))))

(defun compose-preview--target-from-android-mode (project-root &optional refresh)
  "Return current source target from android-mode under PROJECT-ROOT.
With REFRESH non-nil, refresh Android project metadata first."
  (when (and compose-preview-use-android-mode-flavors
             buffer-file-name
             (fboundp 'android-target-for-source-file))
    (compose-preview--target-from-android-entry
     project-root
     (ignore-errors
       (android-target-for-source-file
        buffer-file-name project-root refresh)))))

(defun compose-preview--prompt-android-target (project-root)
  "Prompt for an Android target under PROJECT-ROOT through android-mode."
  (when (compose-preview--android-flavors-available-p)
    (compose-preview--target-from-android-entry
     project-root
     (ignore-errors
       (android-current-target t buffer-file-name project-root)))))

(defun compose-preview--refresh-stale-kmp-target (project-root target)
  "Refresh stale Android KMP TARGET metadata under PROJECT-ROOT once."
  (if (and target
           (string= (plist-get target :variant) "androidMain")
           (not (string= (plist-get target :preview-task) "desktopTest"))
           (fboundp 'android-target-for-source-file)
           (not (member project-root compose-preview--metadata-refresh-roots)))
      (progn
        (push project-root compose-preview--metadata-refresh-roots)
        (compose-preview--log
         "refreshing stale Android KMP preview metadata for %s" project-root)
        (or (compose-preview--target-from-android-mode project-root t) target))
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
      (let ((buffer-file-name file))
        (compose-preview--current-buffer-class-prefix)))))

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

(defun compose-preview--kotlin-method-fqn (function-start method)
  "Return JVM FQN for METHOD declared at FUNCTION-START."
  (let* ((package (compose-preview--current-package))
         (owners (compose-preview--enclosing-kotlin-owners function-start))
         (declaring-class
          (if owners
              (string-join owners "$")
            (concat (file-name-base buffer-file-name) "Kt"))))
    (string-join (delq nil (list package declaring-class method)) ".")))

(defun compose-preview--current-preview-method-fqn ()
  "Return fully qualified JVM name of the Compose Preview at point."
  (when (and buffer-file-name (string-match-p "\\.kt\\'" buffer-file-name))
    (save-excursion
      (end-of-line)
      (when (re-search-backward compose-preview--kotlin-function-regexp nil t)
        (let ((function-start (point))
              (method (match-string-no-properties 1)))
          (when (compose-preview--function-has-preview-annotation-p function-start)
            (compose-preview--kotlin-method-fqn function-start method)))))))

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

(defun compose-preview--source-buffer-for-item (preview)
  "Return the source buffer associated with PREVIEW."
  (let ((source compose-preview--source-buffer)
        (name (compose-preview-item-source-file preview)))
    (cond
     ((and (buffer-live-p source)
           (or (null name)
               (when-let* ((file (buffer-local-value 'buffer-file-name source)))
                 (equal name (file-name-nondirectory file)))))
      source)
     ((and name
           (seq-find (lambda (buffer)
                       (when-let* ((file (buffer-local-value 'buffer-file-name buffer)))
                         (and (equal name (file-name-nondirectory file))
                              (file-in-directory-p file default-directory))))
                     (buffer-list))))
     (name
      (when-let* ((matches (directory-files-recursively
                            default-directory
                            (concat "/" (regexp-quote name) "\\'") nil))
                  (file (or (seq-find (lambda (candidate)
                                       (string-match-p "/src/" candidate))
                                     matches)
                            (car matches))))
        (find-file-noselect file))))))

(defun compose-preview--goto-preview-method (preview)
  "Move point to the declaration represented by PREVIEW."
  (let ((fqn (compose-preview-item-method-fqn preview))
        (method (compose-preview-item-method preview))
        found)
    (goto-char (point-min))
    (while (and (not found)
                (re-search-forward compose-preview--kotlin-function-regexp nil t))
      (let ((start (match-beginning 0))
            (name (match-string-no-properties 1)))
        (when (and (equal name method)
                   (equal fqn (compose-preview--kotlin-method-fqn start name)))
          (setq found start))))
    (when found
      (goto-char found)
      (back-to-indentation))
    found))

(defun compose-preview--android-flavors-available-p ()
  "Return non-nil when public android-mode target APIs are available."
  (and compose-preview-use-android-mode-flavors
       (fboundp 'android-project-variants)
       (fboundp 'android-project-target)
       (fboundp 'android-current-target)))

(defun compose-preview--android-variants (project-root module)
  "Return android-mode variants under PROJECT-ROOT for MODULE, or nil."
  (when (compose-preview--android-flavors-available-p)
    (ignore-errors
      (delete-dups
       (mapcar
        (lambda (entry) (plist-get entry :variant))
        (seq-filter
         (lambda (entry)
           (string= (plist-get entry :module-name) module))
         (android-project-variants project-root)))))))

(defun compose-preview--android-target-for-module (project-root module variant)
  "Return android-mode target metadata for PROJECT-ROOT, MODULE and VARIANT."
  (when (compose-preview--android-flavors-available-p)
    (compose-preview--target-from-android-entry
     project-root
     (ignore-errors
       (android-project-target module variant project-root)))))

(defun compose-preview--read-variant-for-module (project-root module force-prompt)
  "Return a variant under PROJECT-ROOT for MODULE.
When FORCE-PROMPT is non-nil, prompt with android-mode when possible."
  (if noninteractive
      compose-preview-default-variant
    (if (compose-preview--android-flavors-available-p)
      (let ((variants (compose-preview--android-variants project-root module)))
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
        (or (and force-prompt
                 (when-let* ((android-target
                              (compose-preview--prompt-android-target
                               project-root)))
                   (compose-preview--log
                    "selected prompted Android target module=%s variant=%s module-root=%s project-root=%s"
                    (plist-get android-target :module-path)
                    (plist-get android-target :variant)
                    (plist-get android-target :module-root)
                    project-root)
                   (compose-preview--cache-target android-target)))
            (let* ((module-root
                    (or (compose-preview--find-module-root)
                        (user-error
                         "Could not find module root: no build.gradle(.kts)")))
                   (module-path
                    (compose-preview--module-path project-root module-root))
                   (module-name (compose-preview--module-name module-path))
                   (variant (compose-preview--read-variant-for-module
                             project-root module-name force-prompt)))
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
                    (compose-preview--log
                     "selected target module=%s module-root=%s project-root=%s"
                     module-path module-root project-root)
                    (compose-preview--cache-target
                     (list :project-root project-root
                           :module-root module-root
                           :module-path module-path
                           :variant variant))))))))))

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
  "Return model file for TARGET, isolated by GENERATION when non-nil."
  (let ((variant (compose-preview--sanitize
                  (or (plist-get target :variant) "default"))))
    (expand-file-name (if generation
                          (format "model-%s-%s.json" variant generation)
                        (format "model-%s.json" variant))
                      (compose-preview--work-directory target))))

(defun compose-preview--snapshot-model (context)
  "Copy CONTEXT's stable Gradle model to its generation-specific file."
  (let ((source (plist-get context :gradle-model-file))
        (destination (plist-get context :model-file)))
    (copy-file source destination t)))

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
      (let* ((buffer-file-name file)
             (package (compose-preview--current-package))
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
  (expand-file-name (concat "launcher-v4-" compose-preview-renderer-version "/")
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
         (metadata (make-hash-table :test #'equal))
         screenshots)
    (when (file-directory-p output)
      (delete-directory output t))
    (make-directory output t)
    (dolist (preview previews)
      (cl-loop for annotation in (compose-preview--json-get preview "annotations")
               for index from 0
               do (let* ((id (compose-preview--preview-id preview annotation index))
                         (entry
                          `(("previewType" . "COMPOSE")
                            ("methodFQN" . ,(compose-preview--json-get preview "methodFQN"))
                            ("previewId" . ,id)
                            ("methodParams" . ,(vconcat (compose-preview--json-get preview "methodParams")))
                            ("previewParams" . ,(or annotation
                                                     (make-hash-table :test #'equal))))))
                    (puthash id
                             (list :preview-name (compose-preview--json-get annotation "name")
                                   :group (compose-preview--json-get annotation "group")
                                   :source-file (compose-preview--json-get preview "sourceFile")
                                   :parameter-name
                                   (seq-find #'stringp
                                             (compose-preview--json-get
                                              preview "parameterNames")))
                             metadata)
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
    (list :settings settings-file :results results-file :output output
          :metadata metadata)))

(defun compose-preview--fit-width ()
  "Return the available pixel width of the current Preview surface."
  (car (compose-preview--available-size)))

(defun compose-preview--available-size ()
  "Return available Preview surface size in logical pixels."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (cons (max 64 (- (window-body-width window t) 32))
            (max 64 (- (window-body-height window t) 32)))
    (cons compose-preview-image-width compose-preview-image-width)))

(defun compose-preview--string-pixel-width (string)
  "Return the pixel width of STRING in the current Preview panel."
  (if (fboundp 'string-pixel-width)
      (string-pixel-width string)
    (* (string-width string) (frame-char-width))))

(defun compose-preview--image-width (image)
  "Return pixel width of IMAGE, or nil when it cannot be measured."
  (condition-case nil
      (car (image-size image t))
    (error nil)))

(defun compose-preview--frame-scale-factor ()
  "Return the current frame's physical-to-logical pixel scale."
  (if (fboundp 'frame-scale-factor)
      (float (frame-scale-factor
              (window-frame (or (get-buffer-window (current-buffer) t)
                                (selected-window)))))
    1.0))

(defun compose-preview--actual-image-width (image density-dpi)
  "Return IMAGE width at Studio-style actual size for DENSITY-DPI."
  (when-let* ((width (compose-preview--image-width image)))
    (if (and density-dpi (> density-dpi 0))
        (round (/ (* width 160.0)
                  density-dpi
                  (max 1.0 (compose-preview--frame-scale-factor))))
      width)))

(defun compose-preview--actual-image-size (file density-dpi)
  "Return FILE size at Studio-style actual size for DENSITY-DPI."
  (condition-case nil
      (let* ((image (create-image file 'png nil))
             (size (image-size image t))
             (factor (if (and density-dpi (> density-dpi 0))
                         (/ 160.0 density-dpi
                            (max 1.0 (compose-preview--frame-scale-factor)))
                       1.0)))
        (cons (round (* (car size) factor))
              (round (* (cdr size) factor))))
    (error nil)))

(defun compose-preview--image-spec (file &optional density-dpi)
  "Return an image spec for FILE using Android Studio scale semantics.
At actual size, convert renderer pixels to Android dp using DENSITY-DPI and
compensate for the host frame scale, matching Studio's design surface.  Fit
mode uses one scale shared by every visible Preview, like Studio's surface."
  (let* ((original (create-image file 'png nil))
         (width (compose-preview--actual-image-width original density-dpi))
         (scale (if compose-preview--fit-images
                    compose-preview--fit-scale
                  compose-preview--image-zoom))
         (display-width
          (cond
           (width (round (* width scale)))
           ((= scale 1.0) nil)
           (t (round (* compose-preview-image-width scale))))))
    (if display-width
        (create-image file 'png nil :width (max 1 display-width))
      original)))

(defun compose-preview--insert-image (file &optional density-dpi)
  "Insert FILE using Studio-style scale for DENSITY-DPI."
  (if (and (display-images-p)
           (image-type-available-p 'png))
      (condition-case err
          (insert-image (compose-preview--image-spec file density-dpi))
        (error
         (insert (format "Could not render image: %s" (error-message-string err)))))
    (insert "Image display is not available in this Emacs session.")))

(defun compose-preview--display-panel (buffer)
  "Display BUFFER in the Compose preview side window."
  (when-let* ((window (display-buffer-in-side-window
                       buffer
                       `((side . right)
                         (slot . 0)
                         (window-width . ,compose-preview-panel-width)))))
    (set-window-fringes window 8 0)
    window))

(defun compose-preview--panel-status (source-buffer module-root status &optional face)
  "Show STATUS for SOURCE-BUFFER and MODULE-ROOT in the preview panel."
  (let ((buffer (get-buffer-create compose-preview-results-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'compose-preview-results-mode)
        (compose-preview-results-mode))
      (setq-local compose-preview--source-buffer source-buffer
                  default-directory module-root
                  compose-preview--status status
                  compose-preview--status-face (or face 'mode-line-emphasis)
                  header-line-format (propertize (concat " " status)
                                                  'face (or face 'mode-line-emphasis)))
      (when (= (buffer-size) 0)
        (let ((inhibit-read-only t))
          (insert "Waiting for the first render...\n"))))
    (compose-preview--display-panel buffer)))

(defun compose-preview--group-name (preview)
  "Return @Preview(group) name for PREVIEW, or nil when ungrouped."
  (let ((group (compose-preview-item-group preview)))
    (and (stringp group) (not (string-empty-p group)) group)))

(defun compose-preview--annotation-group-names (previews)
  "Return sorted unique @Preview(group) names from PREVIEWS."
  (sort (delete-dups (delq nil (mapcar #'compose-preview--group-name previews)))
        #'string-lessp))

(defun compose-preview--section-id (preview)
  "Return Studio organization-group id for PREVIEW."
  (or (compose-preview-item-method-fqn preview)
      (compose-preview-item-method preview)
      (compose-preview-item-name preview)
      "Preview"))

(defun compose-preview--section-title (preview)
  "Return Studio organization-group title for PREVIEW."
  (or (compose-preview-item-method preview)
      (compose-preview-item-name preview)
      "Preview"))

(defun compose-preview--group-items (previews)
  "Group PREVIEWS by composable method, like Studio organization groups."
  (let ((groups (make-hash-table :test #'equal))
        order)
    (dolist (preview previews)
      (let ((id (compose-preview--section-id preview)))
        (unless (gethash id groups)
          (push id order))
        (puthash id (append (gethash id groups) (list preview)) groups)))
    (mapcar (lambda (id) (cons id (gethash id groups)))
            (nreverse order))))

(defun compose-preview--item-search-text (item)
  "Return searchable display text for Preview ITEM."
  (string-join
   (delq nil (list (compose-preview-item-name item)
                   (compose-preview--card-title item)
                   (compose-preview-item-preview-name item)
                   (compose-preview-item-parameter-name item)
                   (compose-preview-item-method-fqn item)
                   (compose-preview--group-name item)))
   " "))

(defun compose-preview--visible-items ()
  "Return Preview items accepted by the current panel filters."
  (seq-filter
   (lambda (item)
     (and (or (null compose-preview--group-filter)
              (equal compose-preview--group-filter
                     (compose-preview--group-name item)))
          (or (null compose-preview--search-query)
              (string-search (downcase compose-preview--search-query)
                             (downcase (compose-preview--item-search-text item))))))
   compose-preview--items))

(defun compose-preview--focused-item (&optional items)
  "Return the focused item from ITEMS or current visible items."
  (let ((items (or items (compose-preview--visible-items))))
    (or (seq-find (lambda (item)
                    (equal compose-preview--focus-id
                           (compose-preview-item-id item)))
                  items)
        (car items))))

(defun compose-preview--current-item ()
  "Return the Preview item at point, if any."
  (get-text-property (point) 'compose-preview-item))

(defun compose-preview--png-clipboard-method ()
  "Return the backend used to copy PNG data, or nil when unavailable."
  (cond
   ((eq system-type 'darwin)
    (and (executable-find "osascript") 'osascript))
   ((memq system-type '(windows-nt cygwin ms-dos))
    (and (or (executable-find "powershell.exe") (executable-find "pwsh"))
         'powershell))
   ((and (let ((display (getenv "WAYLAND_DISPLAY")))
           (and display (not (string-empty-p display))))
         (executable-find "wl-copy"))
    'wl-copy)
   ((executable-find "xclip") 'xclip)
   ((executable-find "wl-copy") 'wl-copy)))

(defun compose-preview--png-clipboard-unavailable ()
  "Return a user-facing error when no PNG clipboard backend is available."
  (user-error
   (pcase system-type
     ('darwin "Copying Preview images requires osascript")
     ((or 'windows-nt 'cygwin 'ms-dos)
      "Copying Preview images requires PowerShell")
     (_ "Copying Preview images requires wl-copy or xclip"))))

(defun compose-preview--run-clipboard-process (program infile &rest args)
  "Run PROGRAM with ARGS, optionally feeding INFILE on stdin."
  (let ((output (generate-new-buffer " *compose-preview-clipboard*")))
    (unwind-protect
        (let ((status (apply #'call-process program infile output nil args)))
          (unless (and (integerp status) (zerop status))
            (user-error "Could not copy Preview image: %s"
                        (string-trim (with-current-buffer output
                                         (buffer-string))))))
      (kill-buffer output))))

(defun compose-preview--copy-png-osascript (file)
  "Copy PNG FILE to the macOS clipboard as image data."
  (with-temp-buffer
    (insert "on run argv\n"
            "  set imageFile to POSIX file (item 1 of argv)\n"
            "  set the clipboard to (read imageFile as «class PNGf»)\n"
            "end run\n")
    (let ((output (generate-new-buffer " *compose-preview-clipboard*")))
      (unwind-protect
          (let ((status (call-process-region
                         (point-min) (point-max) "osascript" nil output nil
                         "-" file)))
            (unless (and (integerp status) (zerop status))
              (user-error "Could not copy Preview image: %s"
                          (string-trim (with-current-buffer output
                                           (buffer-string))))))
        (kill-buffer output)))))

(defun compose-preview--copy-png-powershell (file)
  "Copy PNG FILE to the Windows clipboard as image data."
  (let ((shell (or (executable-find "powershell.exe") (executable-find "pwsh")))
        (escaped (replace-regexp-in-string "'" "''" file t t)))
    (compose-preview--run-clipboard-process
     shell nil "-NoProfile" "-STA" "-Command"
     (format (concat "Add-Type -AssemblyName System.Windows.Forms; "
                     "Add-Type -AssemblyName System.Drawing; "
                     "$img = [System.Drawing.Image]::FromFile('%s'); "
                     "[System.Windows.Forms.Clipboard]::SetImage($img); "
                     "$img.Dispose()")
             escaped))))

(defun compose-preview--copy-png-to-clipboard (file)
  "Copy PNG FILE data to the system clipboard."
  (let ((file (expand-file-name file))
        (method (compose-preview--png-clipboard-method)))
    (pcase method
      ('osascript (compose-preview--copy-png-osascript file))
      ('wl-copy (compose-preview--run-clipboard-process
                 "wl-copy" file "--type" "image/png"))
      ('xclip (compose-preview--run-clipboard-process
               "xclip" nil "-selection" "clipboard" "-t" "image/png" "-i" file))
      ('powershell (compose-preview--copy-png-powershell file))
      (_ (compose-preview--png-clipboard-unavailable)))))

(defun compose-preview-copy-image (&optional preview)
  "Copy PREVIEW's original PNG image data to the system clipboard.
When PREVIEW is nil, use the Preview card at point."
  (interactive)
  (let ((preview (or preview (compose-preview--current-item))))
    (unless preview
      (user-error "Point is not on a Compose Preview image"))
    (let ((file (seq-find #'file-readable-p
                          (compose-preview-item-files preview))))
      (unless file
        (user-error "This Compose Preview has no image to copy"))
      (compose-preview--copy-png-to-clipboard file)
      (message "Copied Preview image: %s" (file-name-nondirectory file)))))

(defun compose-preview--fit-item-size (item scale)
  "Return ITEM card size at SCALE as a pixel cons cell."
  (let* ((file (seq-find #'file-readable-p (compose-preview-item-files item)))
         (actual (and file (compose-preview--actual-image-size
                            file (compose-preview-item-density-dpi item))))
         (image-width (if actual (* scale (car actual)) 96))
         (image-height (if actual (* scale (cdr actual)) 64))
         (title (compose-preview--card-title item))
         (title-width (if title (compose-preview--string-pixel-width title) 0))
         (line-height (frame-char-height))
         (extra-height (+ (if title line-height 0)
                          (if (compose-preview-item-error item) line-height 0)
                          line-height)))
    (cons (max 96 image-width title-width)
          (+ image-height extra-height))))

(defun compose-preview--fit-grid-size (items scale available-width)
  "Return Grid layout size for ITEMS at SCALE within AVAILABLE-WIDTH."
  (let ((gap (compose-preview--grid-gap scale))
        (line-height (frame-char-height))
        (max-width 0)
        (height 0))
    (dolist (group (compose-preview--group-items items))
      (setq height (+ height line-height))
      (unless (gethash (car group) compose-preview--collapsed-groups)
        (let ((x 0) (row-height 0))
          (dolist (item (cdr group))
            (let* ((size (compose-preview--fit-item-size item scale))
                   (width (car size)))
              (when (and (> x 0) (> (+ x width) available-width))
                (setq max-width (max max-width (- x gap))
                      height (+ height row-height)
                      x 0 row-height 0))
              (setq x (+ x width gap)
                    row-height (max row-height (cdr size)))))
          (setq max-width (max max-width (max 0 (- x gap)))
                height (+ height row-height line-height)))))
    (cons max-width height)))

(defun compose-preview--fit-layout-size (items scale)
  "Return visible Preview layout size for ITEMS at SCALE."
  (let* ((available (compose-preview--available-size))
         (line-height (frame-char-height))
         (hints-height (if compose-preview-show-key-hints (* 2 line-height) 0)))
    (if (eq compose-preview--view-mode 'focus)
        (let* ((item (compose-preview--focused-item items))
               (size (and item (compose-preview--fit-item-size item scale))))
          (cons (if size (car size) 0)
                (+ hints-height (if size (cdr size) 0) (* 2 line-height))))
      (let ((size (compose-preview--fit-grid-size items scale (car available))))
        (cons (car size) (+ hints-height (cdr size)))))))

(defun compose-preview--fit-scale-for-items (items)
  "Return Studio-style shared Zoom to Fit scale for visible ITEMS."
  (if (null items)
      1.0
    (let* ((available (compose-preview--available-size))
           (width (car available))
           (height (cdr available))
           (low 0.01)
           (high 10.0))
      (dotimes (_ 18)
        (let* ((scale (/ (+ low high) 2.0))
               (size (compose-preview--fit-layout-size items scale)))
          (if (and (<= (car size) width) (<= (cdr size) height))
              (setq low scale)
            (setq high scale))))
      low)))

(defun compose-preview--view-description (visible)
  "Return a concise description of current view over VISIBLE items."
  (format "%s · %d/%d · %s%s%s"
          (capitalize (symbol-name compose-preview--view-mode))
          (length visible) (length compose-preview--items)
          (if compose-preview--fit-images
              (format "Fit · %d%%" (round (* 100 compose-preview--fit-scale)))
            (if (= compose-preview--image-zoom 1.0)
                "Actual"
              (format "%d%%" (round (* 100 compose-preview--image-zoom)))))
          (if compose-preview--group-filter
              (format " · %s" compose-preview--group-filter) "")
          (if compose-preview--search-query
              (format " · /%s/" compose-preview--search-query) "")))

(defun compose-preview--delete-section-overlays ()
  "Delete section overlays owned by the current Preview panel."
  (dolist (table (list compose-preview--group-overlays
                       compose-preview--group-header-overlays))
    (when (hash-table-p table)
      (maphash (lambda (_group overlay)
                 (when (overlayp overlay)
                   (delete-overlay overlay)))
               table)))
  (when (overlayp compose-preview--section-highlight-overlay)
    (delete-overlay compose-preview--section-highlight-overlay))
  (when (overlayp compose-preview--item-highlight-overlay)
    (delete-overlay compose-preview--item-highlight-overlay)))

(defun compose-preview--redraw ()
  "Redraw the current Preview panel without rerendering images."
  (let ((inhibit-read-only t)
        (visible (compose-preview--visible-items)))
    (when (eq compose-preview--view-mode 'gallery)
      (setq compose-preview--view-mode 'grid))
    (compose-preview--delete-section-overlays)
    (erase-buffer)
    (setq compose-preview--group-overlays (make-hash-table :test #'equal)
          compose-preview--group-header-overlays (make-hash-table :test #'equal)
          compose-preview--section-highlight-overlay nil
          compose-preview--item-highlight-overlay nil
          compose-preview--group-names
          (mapcar #'car (compose-preview--group-items visible)))
    (setq compose-preview--last-layout-size
          (compose-preview--available-size))
    (when compose-preview--fit-images
      (setq compose-preview--fit-scale
            (compose-preview--fit-scale-for-items visible)))
    (when compose-preview--status
      (setq header-line-format
            (propertize
             (format " %s · %s" compose-preview--status
                     (compose-preview--view-description visible))
             'face (or compose-preview--status-face 'mode-line-emphasis))))
    (when compose-preview-show-key-hints
      (insert (propertize
               "TAB fold  n/p browse  v view  / search  G group  f/0/+/- scale  w copy  o source\n\n"
               'face 'shadow)))
    (cond
     ((and (null visible) compose-preview--items)
      (insert (propertize "No previews match the current filters.\n" 'face 'shadow)))
     ((eq compose-preview--view-mode 'focus)
      (when-let* ((item (compose-preview--focused-item visible)))
        (setq compose-preview--focus-id (compose-preview-item-id item))
        (compose-preview--insert-preview item)))
     (visible
      (dolist (group (compose-preview--group-items visible))
        (compose-preview--insert-group (car group) (cdr group))))
     (t
      (dolist (file compose-preview--legacy-images)
        (insert (file-relative-name file compose-preview--module-root) "\n")
        (compose-preview--insert-image file)
        (insert "\n\n"))))))

(defun compose-preview--group-at-point ()
  "Return the Preview group containing point, like a Magit section."
  (or (get-text-property (point) 'compose-preview-group)
      (get-text-property (point) 'compose-preview-section-group)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'compose-preview-section-group))))

(defun compose-preview--highlight-section ()
  "Highlight the heading of the Preview section containing point."
  (when (overlayp compose-preview--section-highlight-overlay)
    (delete-overlay compose-preview--section-highlight-overlay))
  (when (overlayp compose-preview--item-highlight-overlay)
    (delete-overlay compose-preview--item-highlight-overlay))
  (setq compose-preview--section-highlight-overlay nil
        compose-preview--item-highlight-overlay nil)
  (let ((item (compose-preview--current-item)))
    (unless item
      (when-let* ((group (compose-preview--group-at-point))
                  (header (gethash group compose-preview--group-header-overlays))
                  ((overlay-buffer header)))
        (let ((overlay (make-overlay (overlay-start header) (overlay-end header))))
          (overlay-put overlay 'face 'compose-preview-section-highlight)
          (overlay-put overlay 'priority 10)
          (setq compose-preview--section-highlight-overlay overlay))))
    (when-let* ((start (and item (compose-preview--item-title-position item))))
      (let ((overlay (make-overlay
                      start
                      (or (next-single-property-change
                           start 'compose-preview-item-title nil (point-max))
                          (point-max)))))
        (overlay-put overlay 'face 'highlight)
        (overlay-put overlay 'priority 11)
        (setq compose-preview--item-highlight-overlay overlay)))))

(defun compose-preview--property-position (property value)
  "Return first position whose PROPERTY is equal to VALUE."
  (let ((position (point-min))
        found)
    (while (and (< position (point-max)) (not found))
      (if (equal (get-text-property position property) value)
          (setq found position)
        (setq position (or (next-single-property-change
                            position property nil (point-max))
                           (point-max)))))
    found))

(defun compose-preview--section-indicator (collapsed)
  "Return Magit-style visibility indicator strings for COLLAPSED."
  (if (display-graphic-p)
      (list (propertize " " 'display
                        `(left-fringe
                          ,(if collapsed 'compose-preview-fringe>
                             'compose-preview-fringev)
                          fringe))
            nil)
    (list (propertize (if collapsed "> " "v ") 'face 'shadow) nil)))

(defun compose-preview--set-group-collapsed (group collapsed)
  "Set GROUP visibility according to COLLAPSED in the current panel."
  (puthash group collapsed compose-preview--collapsed-groups)
  (let* ((header-start (compose-preview--property-position
                        'compose-preview-group group))
         (body-start (compose-preview--property-position
                      'compose-preview-group-body group)))
    (when (and header-start body-start)
      (let* ((body-end (or (next-single-property-change
                            body-start 'compose-preview-group-body nil (point-max))
                           (point-max)))
             (existing (gethash group compose-preview--group-overlays))
             (overlay (if (and (overlayp existing) (overlay-buffer existing))
                          existing
                        (make-overlay body-start body-end)))
             (indicator (compose-preview--section-indicator collapsed)))
        (move-overlay overlay body-start body-end)
        (overlay-put overlay 'evaporate t)
        (overlay-put overlay 'invisible (and collapsed 'compose-preview-fold))
        (overlay-put overlay 'isearch-open-invisible #'delete-overlay)
        (puthash group overlay compose-preview--group-overlays)
        (when-let* ((header (gethash group compose-preview--group-header-overlays)))
          (overlay-put header 'before-string (car indicator))
          (overlay-put header 'after-string (cadr indicator)))))))

(defun compose-preview-mouse-toggle-group (event)
  "Toggle the Preview section at the mouse EVENT."
  (interactive "e")
  (let ((window (posn-window (event-start event)))
        (pos (posn-point (event-start event))))
    (when (and (windowp window) pos)
      (select-window window)
      (goto-char pos)
      (compose-preview-toggle-group))))

(defun compose-preview-toggle-group (&optional group)
  "Toggle GROUP or the Preview section containing point."
  (interactive)
  (let* ((group (or group (compose-preview--group-at-point)))
         (collapsed (and group
                         (not (gethash group
                                       compose-preview--collapsed-groups))))
         (header (and group
                      (gethash group compose-preview--group-header-overlays))))
    (unless group
      (user-error "Point is not in a Preview section"))
    (compose-preview--set-group-collapsed group collapsed)
    (if compose-preview--fit-images
        (progn
          (compose-preview--redraw)
          (when-let* ((position (compose-preview--property-position
                                 'compose-preview-group group)))
            (goto-char position)))
      (when (and collapsed (overlayp header) (overlay-buffer header))
        (goto-char (overlay-start header))))))

(defun compose-preview-toggle-all-groups ()
  "Expand all Preview groups, or collapse all when all are expanded."
  (interactive)
  (let* ((groups compose-preview--group-names)
         (collapse (seq-every-p
                    (lambda (group)
                      (not (gethash group compose-preview--collapsed-groups)))
                    groups)))
    (dolist (group groups)
      (compose-preview--set-group-collapsed group collapse))
    (when compose-preview--fit-images
      (compose-preview--redraw))))

(defun compose-preview-toggle-view ()
  "Toggle between Grid and Focus Preview views."
  (interactive)
  (when-let* ((item (compose-preview--current-item)))
    (setq compose-preview--focus-id (compose-preview-item-id item)))
  (setq compose-preview--view-mode
        (if (eq compose-preview--view-mode 'focus) 'grid 'focus))
  (compose-preview--redraw))

(defun compose-preview--navigable-items ()
  "Return visible Preview items whose Grid section is expanded."
  (if (eq compose-preview--view-mode 'grid)
      (seq-filter
       (lambda (item)
         (not (gethash (compose-preview--section-id item)
                       compose-preview--collapsed-groups)))
       (compose-preview--visible-items))
    (compose-preview--visible-items)))

(defun compose-preview--item-title-position (item)
  "Return first title position for ITEM, if it has a Grid label."
  (let ((position (point-min))
        found)
    (while (and (< position (point-max)) (not found))
      (let ((current (get-text-property position 'compose-preview-item-title)))
        (if (and current
                 (equal (compose-preview-item-id current)
                        (compose-preview-item-id item)))
            (setq found position)
          (setq position (or (next-single-property-change
                              position 'compose-preview-item-title nil (point-max))
                             (point-max))))))
    found))

(defun compose-preview--item-position (item)
  "Return first buffer position of ITEM, if any."
  (let ((position (point-min))
        found)
    (while (and (< position (point-max)) (not found))
      (let ((current (get-text-property position 'compose-preview-item)))
        (if (and current
                 (equal (compose-preview-item-id current)
                        (compose-preview-item-id item)))
            (setq found position)
          (setq position (or (next-single-property-change
                              position 'compose-preview-item nil (point-max))
                             (point-max))))))
    found))

(defun compose-preview--goto-item (item)
  "Move point to ITEM in the current Preview panel."
  (when-let* ((position (or (compose-preview--item-title-position item)
                            (compose-preview--item-position item))))
    (goto-char position)))

(defun compose-preview--heading-at-point-p ()
  "Return non-nil when point is on a Preview section heading."
  (get-text-property (point) 'compose-preview-group))

(defun compose-preview--current-target ()
  "Return the Magit-style navigation target at point."
  (cond
   ((compose-preview--heading-at-point-p)
    (cons 'section (get-text-property (point) 'compose-preview-group)))
   ((compose-preview--current-item)
    (cons 'item (compose-preview--current-item)))))

(defun compose-preview--target-equal (left right)
  "Return non-nil when navigation targets LEFT and RIGHT are the same."
  (and left right
       (eq (car left) (car right))
       (if (eq (car left) 'section)
           (equal (cdr left) (cdr right))
         (equal (compose-preview-item-id (cdr left))
                (compose-preview-item-id (cdr right))))))

(defun compose-preview--navigation-targets ()
  "Return Magit-style n/p targets: section headings then visible cards."
  (let (targets)
    (dolist (section (compose-preview--group-items
                      (compose-preview--visible-items)))
      (let ((id (car section))
            (items (cdr section)))
        (push (cons 'section id) targets)
        (unless (gethash id compose-preview--collapsed-groups)
          (dolist (item items)
            (push (cons 'item item) targets)))))
    (nreverse targets)))

(defun compose-preview--goto-target (target)
  "Move point to Magit-style navigation TARGET."
  (pcase (car target)
    ('section
     (when-let* ((position (compose-preview--property-position
                            'compose-preview-group (cdr target))))
       (goto-char position)))
    ('item
     (setq compose-preview--focus-id (compose-preview-item-id (cdr target)))
     (compose-preview--goto-item (cdr target)))))

(defun compose-preview--move-focus-item (step)
  "Move Focus view by STEP among filtered Preview items."
  (let ((items (compose-preview--visible-items)))
    (unless items
      (user-error "No visible Compose Previews"))
    (let* ((current (or (compose-preview--current-item)
                        (compose-preview--focused-item items)))
           (index (or (and current
                           (seq-position
                            items current
                            (lambda (left right)
                              (equal (compose-preview-item-id left)
                                     (compose-preview-item-id right)))))
                      0))
           (next (nth (mod (+ index step) (length items)) items)))
      (setq compose-preview--focus-id (compose-preview-item-id next))
      (compose-preview--redraw)
      (compose-preview--goto-item next))))

(defun compose-preview--move-section (step)
  "Move Grid view by STEP among Magit-style section targets."
  (let ((targets (compose-preview--navigation-targets)))
    (unless targets
      (user-error "No visible Compose Previews"))
    (let* ((current (compose-preview--current-target))
           (index (or (and current
                           (seq-position targets current
                                         #'compose-preview--target-equal))
                      (if (> step 0) -1 (length targets))))
           (next-index (+ index step)))
      (when (or (< next-index 0) (>= next-index (length targets)))
        (user-error (if (> step 0) "No next section" "No previous section")))
      (compose-preview--goto-target (nth next-index targets)))))

(defun compose-preview--move-focus (step)
  "Move to the next Magit-style section or Focus item by STEP."
  (if (eq compose-preview--view-mode 'focus)
      (compose-preview--move-focus-item step)
    (compose-preview--move-section step)))

(defun compose-preview-next ()
  "Move to the next section or Preview.
In Grid view, visit section headings then visible cards, like Magit.
In Focus view, show the next Preview."
  (interactive)
  (compose-preview--move-focus 1))

(defun compose-preview-previous ()
  "Move to the previous section or Preview.
In Grid view, visit section headings then visible cards, like Magit.
In Focus view, show the previous Preview."
  (interactive)
  (compose-preview--move-focus -1))

(defun compose-preview-search (query)
  "Filter Preview items by case-insensitive QUERY.
An empty QUERY clears the current text filter."
  (interactive
   (list (read-string "Filter Compose previews: "
                      compose-preview--search-query)))
  (setq compose-preview--search-query
        (unless (string-empty-p query) query))
  (compose-preview--redraw))

(defun compose-preview-filter-group (group)
  "Display Preview GROUP, or every group when GROUP is nil."
  (interactive
   (let* ((groups (compose-preview--annotation-group-names
                   compose-preview--items))
          (choice (completing-read "Preview group: " (cons "All" groups)
                                   nil t nil nil
                                   (or compose-preview--group-filter "All"))))
     (list (unless (string= choice "All") choice))))
  (setq compose-preview--group-filter group)
  (compose-preview--redraw))

(defun compose-preview-fit ()
  "Scale the visible Preview layout to fit the current panel."
  (interactive)
  (setq compose-preview--fit-images t)
  (compose-preview--redraw))

(defun compose-preview-original-size ()
  "Display Preview images at Android Studio Actual Size."
  (interactive)
  (setq compose-preview--fit-images nil
        compose-preview--image-zoom 1.0)
  (compose-preview--redraw))

(defun compose-preview--zoom (factor)
  "Multiply the current image scale by FACTOR and redraw."
  (when compose-preview--fit-images
    (setq compose-preview--image-zoom compose-preview--fit-scale))
  (setq compose-preview--fit-images nil
        compose-preview--image-zoom
        (min 4.0 (max 0.1 (* compose-preview--image-zoom factor))))
  (compose-preview--redraw))

(defun compose-preview-zoom-in ()
  "Enlarge Preview images by 25 percent."
  (interactive)
  (compose-preview--zoom 1.25))

(defun compose-preview-zoom-out ()
  "Shrink Preview images by 20 percent."
  (interactive)
  (compose-preview--zoom 0.8))

(defun compose-preview--window-state-change (&optional _frame)
  "Reflow and refit the Preview layout after the panel size changes."
  (when (and compose-preview--items
             (get-buffer-window (current-buffer) t)
             (or compose-preview--fit-images
                 (eq compose-preview--view-mode 'grid)))
    (let ((size (compose-preview--available-size)))
      (unless (equal size compose-preview--last-layout-size)
        (compose-preview--redraw)))))

(defun compose-preview-goto-source (&optional preview)
  "Visit the source declaration for PREVIEW or the item at point."
  (interactive)
  (let ((preview (or preview (get-text-property (point) 'compose-preview-item))))
    (unless preview
      (user-error "Point is not on a Compose Preview"))
    (let ((buffer (compose-preview--source-buffer-for-item preview)))
      (unless (buffer-live-p buffer)
        (user-error "Source file for %s was not found"
                    (compose-preview-item-name preview)))
      (pop-to-buffer buffer)
      (unless (compose-preview--goto-preview-method preview)
        (user-error "Source declaration for %s was not found"
                    (compose-preview-item-name preview))))))

(defun compose-preview--error-summary (error)
  "Return a concise user-facing summary for renderer ERROR."
  (or (and-let* ((message (compose-preview--json-get error "message")))
        (unless (string-empty-p message) message))
      (and-let* ((missing (compose-preview--json-get error "missingClasses")))
        (format "Missing class%s: %s" (if (= (length missing) 1) "" "es")
                (string-join missing ", ")))
      (and-let* ((problem (car (compose-preview--json-get error "problems")))
                 (html (compose-preview--json-get problem "html")))
        (string-trim (replace-regexp-in-string "<[^>]+>" " " html)))
      (compose-preview--json-get error "status")
      "Unknown rendering issue"))

(defun compose-preview--insert-preview-title (preview)
  "Insert PREVIEW's source-linked display title."
  (let ((title (if (eq compose-preview--view-mode 'focus)
                   (compose-preview-item-name preview)
                 (compose-preview--card-title preview))))
    (when (and title (not (string-empty-p title)))
      (let ((start (point)))
        (insert-text-button title
                            'face 'bold 'follow-link t
                            'help-echo (or (compose-preview-item-name preview)
                                           "Visit Preview source (o)")
                            'keymap compose-preview-button-map
                            'compose-preview-item preview
                            'action (lambda (button)
                                      (compose-preview-goto-source
                                       (button-get button
                                                   'compose-preview-item))))
        (put-text-property start (point) 'compose-preview-item-title preview)))))

(defun compose-preview--grid-entry (preview)
  "Return measured Grid entry for PREVIEW."
  (let* ((file (seq-find #'file-readable-p
                         (compose-preview-item-files preview)))
         (image (and file (display-images-p) (image-type-available-p 'png)
                     (condition-case nil
                         (compose-preview--image-spec
                          file (compose-preview-item-density-dpi preview))
                       (error nil))))
         (image-width (and image (compose-preview--image-width image)))
         (card-title (compose-preview--card-title preview))
         (title-width (if card-title
                          (compose-preview--string-pixel-width card-title)
                        0))
         (width (max 96 (or image-width 0) title-width)))
    (list :item preview :file file :image image :width width)))

(defun compose-preview--grid-rows (previews)
  "Pack PREVIEWS into Studio-style Grid rows for the current width."
  (let ((available (compose-preview--fit-width))
        (gap (compose-preview--grid-gap
              (compose-preview--current-image-scale)))
        (x 0)
        rows row)
    (dolist (preview previews)
      (let* ((entry (compose-preview--grid-entry preview))
             (width (plist-get entry :width)))
        (when (and row (> (+ x width) available))
          (push (nreverse row) rows)
          (setq row nil x 0))
        (setq entry (plist-put entry :x x))
        (push entry row)
        (setq x (+ x width gap))))
    (when row (push (nreverse row) rows))
    (nreverse rows)))

(defun compose-preview--insert-aligned (x)
  "Insert a pixel spacer that starts the next Grid cell at X."
  (insert (propertize " " 'display `(space :align-to (,x)))))

(defun compose-preview--insert-grid-cell (entry inserter)
  "Insert one Grid cell from ENTRY using INSERTER."
  (let ((start (point))
        (item (plist-get entry :item)))
    (compose-preview--insert-aligned (plist-get entry :x))
    (funcall inserter entry)
    (put-text-property start (point) 'compose-preview-item item)))

(defun compose-preview--insert-grid-row (entries)
  "Insert one Grid row of measured ENTRIES."
  (when (seq-some (lambda (entry)
                    (compose-preview--card-title (plist-get entry :item)))
                  entries)
    (dolist (entry entries)
      (compose-preview--insert-grid-cell
       entry (lambda (cell)
               (compose-preview--insert-preview-title
                (plist-get cell :item)))))
    (insert "\n"))
  (dolist (entry entries)
    (compose-preview--insert-grid-cell
     entry
     (lambda (cell)
       (cond
        ((plist-get cell :image)
         (insert-image (plist-get cell :image)))
        ((plist-get cell :file)
         (insert (propertize "Could not render image." 'face 'error)))
        (t (insert (propertize "No image was produced." 'face 'error)))))))
  (insert "\n")
  (when (seq-some (lambda (entry)
                    (compose-preview-item-error (plist-get entry :item)))
                  entries)
    (dolist (entry entries)
      (when-let* ((error (compose-preview-item-error (plist-get entry :item))))
        (compose-preview--insert-grid-cell
         entry (lambda (_cell)
                 (insert (propertize (compose-preview--error-summary error)
                                     'face 'error))))))
    (insert "\n"))
  (insert "\n"))

(defun compose-preview--insert-preview (preview)
  "Insert PREVIEW image, issue summary, and actions in the results buffer."
  (let ((start (point))
        (files (seq-filter #'file-readable-p
                           (compose-preview-item-files preview)))
        (error (compose-preview-item-error preview)))
    (compose-preview--insert-preview-title preview)
    (insert "\n")
    (dolist (file files)
      (insert-button "open image" 'follow-link t
                     'keymap compose-preview-button-map
                     'action (lambda (_button) (find-file file)))
      (insert "\n")
      (compose-preview--insert-image
       file (compose-preview-item-density-dpi preview))
      (insert "\n"))
    (when error
      (insert (propertize (concat "Issue: " (compose-preview--error-summary error))
                          'face 'error)
              "\n")
      (insert-text-button "open render log" 'follow-link t
                          'keymap compose-preview-button-map
                          'action (lambda (_button) (compose-preview-open-log)))
      (insert "\n"))
    (unless (or files error)
      (insert (propertize "No image was produced." 'face 'error) "\n"))
    (insert "\n")
    (put-text-property start (point) 'compose-preview-item preview)))

(defun compose-preview--insert-group (name previews)
  "Insert Magit-style collapsible section NAME containing PREVIEWS."
  (let ((header-start (point))
        (title (or (and (car previews)
                        (compose-preview--section-title (car previews)))
                   name))
        (collapsed (gethash name compose-preview--collapsed-groups)))
    (insert (propertize (format "%s\n" title)
                        'face 'compose-preview-section-heading
                        'keymap compose-preview-section-map
                        'mouse-face 'highlight
                        'help-echo "Toggle section (TAB or RET)"
                        'compose-preview-group name))
    (let ((header (make-overlay header-start (point))))
      (overlay-put header 'evaporate t)
      (puthash name header compose-preview--group-header-overlays))
    (let ((body-start (point)))
      (dolist (row (compose-preview--grid-rows previews))
        (compose-preview--insert-grid-row row))
      (put-text-property body-start (point) 'compose-preview-group-body name)
      (put-text-property body-start (point) 'compose-preview-section-group name)
      (compose-preview--set-group-collapsed name collapsed))))

(defun compose-preview--render-results (module-root images &optional previews source-buffer)
  "Render IMAGES and PREVIEWS for MODULE-ROOT in the preview panel."
  (let ((buffer (get-buffer-create compose-preview-results-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'compose-preview-results-mode)
        (compose-preview-results-mode))
      (setq-local compose-preview--source-buffer source-buffer
                  compose-preview--module-root module-root
                  compose-preview--legacy-images images
                  compose-preview--items previews
                  default-directory module-root)
      (unless (member compose-preview--group-filter
                      (compose-preview--annotation-group-names previews))
        (setq compose-preview--group-filter nil))
      (let ((issue-count (seq-count #'compose-preview-item-error previews)))
        (setq compose-preview--status
              (if (> issue-count 0)
                  (format "ready — %d issue%s"
                          issue-count (if (= issue-count 1) "" "s"))
                "ready")
              compose-preview--status-face (if (> issue-count 0) 'warning 'success)))
      (compose-preview--redraw))
    (compose-preview--display-panel buffer)
    (with-current-buffer buffer
      (when compose-preview--fit-images
        (compose-preview--window-state-change))
      (goto-char (point-min))
      (when-let* ((window (get-buffer-window buffer t)))
        (set-window-point window (point-min))))))

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
         (message (apply #'format format-string args))
         (message (string-remove-prefix "compose-preview: " message)))
    (compose-preview--panel-status source (plist-get target :module-root)
                                   (concat "failed — " message) 'error)
    (compose-preview--log "%s" message)))

(defun compose-preview--padded-index (index max-index)
  "Return INDEX zero-padded to the width of MAX-INDEX."
  (let ((width (max 1 (length (number-to-string (max 0 max-index))))))
    (format (format "%%0%dd" width) index)))

(defun compose-preview--preview-base-name (method-name preview-name)
  "Return Studio's base Preview name for METHOD-NAME and PREVIEW-NAME."
  (if (and preview-name (not (string-empty-p preview-name)))
      (format "%s - %s" method-name preview-name)
    method-name))

(defun compose-preview--custom-parameter-display-name (renderer-name)
  "Return RENDERER-NAME when it is a provider display name rather than paramN."
  (and (stringp renderer-name)
       (not (string-empty-p renderer-name))
       (not (string-match-p "\\`param[0-9]+ [0-9]+\\'" renderer-name))
       renderer-name))

(defun compose-preview--parameter-display-name (parameter-name index count renderer-name)
  "Format PARAMETER-NAME at INDEX of COUNT, preferring RENDERER-NAME."
  (or (compose-preview--custom-parameter-display-name renderer-name)
      (and parameter-name
           (format "%s %s" parameter-name
                   (compose-preview--padded-index
                    index (max 0 (1- (or count 1))))))
      renderer-name))

(defun compose-preview--studio-parameter-label (preview-name parameter-name index count renderer-name)
  "Build a Grid label from PREVIEW-NAME and PARAMETER-NAME at INDEX of COUNT.
Prefer RENDERER-NAME when the provider supplies a custom display name."
  (let ((instance (and index
                       (compose-preview--parameter-display-name
                        parameter-name index count renderer-name))))
    (cond
     ((and preview-name (not (string-empty-p preview-name)) instance)
      (format "%s - %s" preview-name instance))
     (instance instance)
     ((and preview-name (not (string-empty-p preview-name))) preview-name)
     (t nil))))

(defun compose-preview--studio-item-name (method-name preview-name parameter-name index count renderer-name)
  "Build a full name from METHOD-NAME, PREVIEW-NAME, and PARAMETER-NAME.
INDEX and COUNT identify the provider value; RENDERER-NAME may override it."
  (let ((base (compose-preview--preview-base-name method-name preview-name))
        (param (and index
                    (compose-preview--parameter-display-name
                     parameter-name index count renderer-name))))
    (if param
        (format "%s (%s)" base param)
      base)))

(defun compose-preview--card-title (preview)
  "Return PREVIEW's Grid card title without its organization section name."
  (or (compose-preview--studio-parameter-label
       (compose-preview-item-preview-name preview)
       (compose-preview-item-parameter-name preview)
       (compose-preview-item-parameter-index preview)
       (compose-preview-item-parameter-count preview)
       nil)
      (let ((full (compose-preview-item-name preview))
            (section (compose-preview--section-title preview)))
        (and full (not (string= full section)) full))))

(defun compose-preview--result-items (results output &optional metadata)
  "Convert renderer RESULTS into preview items rooted at OUTPUT.
Use METADATA keyed by preview id to preserve annotation display settings."
  (mapcar
   (lambda (result)
     (let* ((fqn (compose-preview--json-get result "methodFQN"))
            (path (compose-preview--json-get result "imagePath"))
            (preview-id (compose-preview--json-get result "previewId"))
            (instance-id (compose-preview--json-get result "instanceId"))
            (parameter-index (compose-preview--json-get result "parameterIndex"))
            (parameter-count (compose-preview--json-get result "parameterCount"))
            (details (and metadata (gethash preview-id metadata)))
            (method-name (car (last (split-string fqn "\\." t))))
            (parameter-name (or (plist-get details :parameter-name)
                                (compose-preview--json-get result "parameterName")))
            (label (compose-preview--studio-item-name
                    method-name
                    (plist-get details :preview-name)
                    (plist-get details :parameter-name)
                    parameter-index parameter-count
                    (compose-preview--json-get result "parameterName")))
            (id (if instance-id
                    (concat preview-id "#" instance-id)
                  (if parameter-index
                      (format "%s#%d" preview-id parameter-index)
                    preview-id))))
       (make-compose-preview-item
        :id id :name label
        :declaring-class (string-join (butlast (split-string fqn "\\." t)) ".")
        :method method-name
        :method-fqn fqn
        :preview-name (plist-get details :preview-name)
        :group (plist-get details :group)
        :source-file (plist-get details :source-file)
        :density-dpi (compose-preview--json-get result "densityDpi")
        :parameter-index parameter-index
        :parameter-count parameter-count
        :parameter-name parameter-name
        :files (and path (list (expand-file-name path output)))
        :error (compose-preview--json-get result "error"))))
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
     (t
      (let* ((target (plist-get context :target))
             (source (plist-get context :source-buffer))
             (items (compose-preview--result-items
                     result-list (plist-get render :output)
                     (plist-get render :metadata)))
             (failed-count (length failed))
             (rendered-count
              (seq-count (lambda (result)
                           (compose-preview--json-get result "imagePath"))
                         result-list)))
        (setq compose-preview--last-results-directory (plist-get render :output)
              compose-preview--last-result-items items
              compose-preview--last-source-buffer source)
        (compose-preview--render-results
         (plist-get target :module-root)
         (apply #'append (mapcar #'compose-preview-item-files items))
         items source)
        (compose-preview--log
         "rendered %d preview images; %d preview%s reported issues"
         rendered-count failed-count (if (= failed-count 1) "" "s")))))))

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
            :command (list (plist-get launcher :javac) "-nowarn" "--release" "17"
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
        (if (plist-get context :follow-refresh)
            (progn
              (compose-preview--hide-panel)
              (compose-preview--log "no previews found for %s"
                                    (file-name-nondirectory source-file)))
          (compose-preview--fail context "no previews found for %s"
                                 (or (and source-file
                                          (file-name-nondirectory source-file))
                                     (plist-get target :module-path))))
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

(defun compose-preview--gradle-arguments (task-path init-script)
  "Return Gradle arguments for TASK-PATH using INIT-SCRIPT."
  (append (list task-path "--init-script" init-script)
          (when compose-preview-use-gradle-daemon
            (list "--daemon"))
          (when compose-preview-force-clean-build
            (list "--no-build-cache" "--no-parallel"))))

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
            (condition-case err
                (progn
                  (compose-preview--snapshot-model context)
                  (compose-preview--start-render context))
              (error
               (compose-preview--fail context "%s"
                                      (error-message-string err))))
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
         (_ (setq target (plist-put target :variant variant)))
         (gradle-model-file (compose-preview--model-file target))
         (model-file (compose-preview--model-file target generation))
         (project-root (plist-get target :project-root))
         (module-path (plist-get target :module-path))
         (task-path (compose-preview--task-path module-path "composePreviewModel"))
         (gradle (compose-preview--gradle-executable project-root))
         (init-script (compose-preview--get-init-script))
         (adapter-directory (expand-file-name "adapters/"
                                               compose-preview--package-directory))
         (log-buffer (get-buffer-create compose-preview-log-buffer-name))
         (process-environment
          (append
           (list (concat "COMPOSE_PREVIEW_MODULE_PATH=" module-path)
                 (concat "COMPOSE_PREVIEW_VARIANT=" variant)
                 (concat "COMPOSE_PREVIEW_MODEL_FILE=" gradle-model-file)
                 (concat "COMPOSE_PREVIEW_ADAPTER_DIRECTORY=" adapter-directory)
                 (concat "COMPOSE_PREVIEW_LAYOUTLIB_VERSION=" compose-preview-layoutlib-version)
                 (concat "COMPOSE_PREVIEW_RENDERER_VERSION=" compose-preview-renderer-version)
                 (concat "COMPOSE_PREVIEW_DETECTOR_VERSION=" compose-preview-detector-version))
           process-environment))
         (default-directory project-root)
         (gradle-args (compose-preview--gradle-arguments task-path init-script))
         context process)
    (unless compose-preview--follow-refresh
      (compose-preview--start-following source-buffer))
    (setq target (compose-preview--cache-target target))
    (when (process-live-p compose-preview--process)
      (delete-process compose-preview--process))
    (with-current-buffer log-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ %s %s\n\n" gradle (string-join gradle-args " ")))))
    (setq context (list :generation generation :target target
                        :source-buffer source-buffer :source-file source-file
                        :preview-method preview-method
                        :follow-refresh compose-preview--follow-refresh
                        :gradle-model-file gradle-model-file
                        :model-file model-file :log-buffer log-buffer)
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
