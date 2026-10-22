EMACS ?= emacs
BATCH = $(EMACS) --batch --quick
TEST_DEPS_DIR ?= .test-deps
PACKAGE_USER_DIR ?= $(abspath $(TEST_DEPS_DIR)/elpa)
ANDROID_PROJECT_DIR ?= $(abspath $(TEST_DEPS_DIR)/android-project)
LOAD_PATH = -L lisp -L "$(ANDROID_PROJECT_DIR)"
PREFIX ?= $(HOME)/.local

ARCHIVES = --eval "(setq package-user-dir \"$(PACKAGE_USER_DIR)\")" \
           --eval "(require 'package)" \
           --eval "(add-to-list 'package-archives '(\"gnu\" . \"https://elpa.gnu.org/packages/\") t)" \
           --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
           --eval "(package-initialize)"

.PHONY: help install-deps lint build test cli-build cli-test install-local clean
help:
	@echo "lint/build/test: Emacs frontend; cli-build/cli-test: Kotlin backend"
	@echo "install-local: install distribution under PREFIX=$(PREFIX)"
install-deps:
	mkdir -p "$(TEST_DEPS_DIR)"
	$(BATCH) $(ARCHIVES) --eval "(package-refresh-contents)" --eval "(package-install 'package-lint)"
	test -d "$(ANDROID_PROJECT_DIR)/.git" || git clone --depth 1 https://github.com/cat-emacs/android-project "$(ANDROID_PROJECT_DIR)"
	$(BATCH) $(ARCHIVES) --eval "(require 'package-vc)" \
	  --eval "(unless (package-installed-p 'android-project) (package-vc-install-from-checkout \"$(ANDROID_PROJECT_DIR)\" \"android-project\"))"
lint:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) --eval "(require 'package-lint)" --eval "(package-lint-batch-and-exit)" lisp/compose-preview.el
	$(BATCH) $(LOAD_PATH) --eval "(checkdoc-file \"lisp/compose-preview.el\")"
build:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile lisp/compose-preview.el
test:
	test -f "$(ANDROID_PROJECT_DIR)/android-project.el"
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) -l "$(ANDROID_PROJECT_DIR)/android-project.el" \
	  -l lisp/compose-preview.el -l lisp/compose-preview-tests.el -f ert-run-tests-batch-and-exit
cli-build:
	./gradlew :cli:installDist
cli-test:
	./gradlew :cli:test
install-local: cli-build
	mkdir -p "$(PREFIX)/lib/compose-preview" "$(PREFIX)/bin"
	cp -R cli/build/install/compose-preview/. "$(PREFIX)/lib/compose-preview/"
	printf '%s\n' '#!/bin/sh' 'exec "$(PREFIX)/lib/compose-preview/bin/compose-preview" "$$@"' > "$(PREFIX)/bin/compose-preview"
	chmod +x "$(PREFIX)/bin/compose-preview"
clean:
	rm -f *.elc lisp/*.elc
