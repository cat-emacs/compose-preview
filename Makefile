EMACS ?= emacs
BATCH = $(EMACS) --batch --quick
TEST_DEPS_DIR ?= .test-deps
PACKAGE_USER_DIR ?= $(abspath $(TEST_DEPS_DIR)/elpa)
ANDROID_PROJECT_DIR ?= $(abspath $(TEST_DEPS_DIR)/android-project)
LOAD_PATH = -L . -L "$(ANDROID_PROJECT_DIR)"

ARCHIVES = --eval "(setq package-user-dir \"$(PACKAGE_USER_DIR)\")" \
           --eval "(require 'package)" \
           --eval "(add-to-list 'package-archives '(\"gnu\" . \"https://elpa.gnu.org/packages/\") t)" \
           --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
           --eval "(package-initialize)"

.PHONY: help install-deps lint build test clean

help:
	@echo "Targets:"
	@echo "  install-deps  - Install package-lint"
	@echo "  lint          - Run package-lint and checkdoc"
	@echo "  build         - Byte-compile compose-preview"
	@echo "  test          - Run compose-preview ERT tests"
	@echo "  clean         - Remove .elc files"

install-deps:
	mkdir -p "$(TEST_DEPS_DIR)"
	$(BATCH) $(ARCHIVES) \
	  --eval "(package-refresh-contents)" \
	  --eval "(package-install 'package-lint)"
	test -d "$(ANDROID_PROJECT_DIR)/.git" || \
	  git clone --depth 1 https://github.com/cat-emacs/android-project \
	  "$(ANDROID_PROJECT_DIR)"
	$(BATCH) $(ARCHIVES) \
	  --eval "(require 'package-vc)" \
	  --eval "(unless (package-installed-p 'android-project) (package-vc-install-from-checkout \"$(ANDROID_PROJECT_DIR)\" \"android-project\"))"

lint:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  --eval "(require 'package-lint)" \
	  --eval "(package-lint-batch-and-exit)" \
	  compose-preview.el
	$(BATCH) $(LOAD_PATH) \
	  --eval "(checkdoc-file \"compose-preview.el\")"

build:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile compose-preview.el

test:
	test -f "$(ANDROID_PROJECT_DIR)/android-project.el"
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  -l "$(ANDROID_PROJECT_DIR)/android-project.el" \
	  -l compose-preview.el \
	  -l compose-preview-tests.el \
	  --eval "(ert-run-tests-batch-and-exit)"

clean:
	rm -f *.elc
