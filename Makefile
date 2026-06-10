EMACS ?= emacs
BATCH = $(EMACS) --batch --quick
LOAD_PATH = -L . -L ../android-mode

ARCHIVES = --eval "(require 'package)" \
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
	$(BATCH) $(ARCHIVES) \
	  --eval "(package-refresh-contents)" \
	  --eval "(package-install 'package-lint)"

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
	  --eval "(byte-compile-file \"compose-preview.el\")"

test:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  -l ../android-mode/android-mode.el \
	  -l compose-preview.el \
	  -l compose-preview-tests.el \
	  --eval "(ert-run-tests-batch-and-exit)"

clean:
	rm -f *.elc
