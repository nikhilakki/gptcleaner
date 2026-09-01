.DEFAULT_GOAL := help
SHELL := /bin/bash

PY      := python3
NODE    := node
CLI     := skills/gptcleaner/scripts/gptcleaner.py
WEB     := skills/gptcleaner/web
APP     := macos/build/GPTCleaner.app
PORT    ?= 8000

.PHONY: help test test-py test-js test-parity check lint serve open \
        app app-run app-install app-clean install install-dry uninstall \
        detect demo clean dist tree

## ---------------------------------------------------------------- help ----

help:  ## Show this help
	@echo ""
	@echo "  gptcleaner - strip the ghosts out of AI text"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables:  PORT=$(PORT)   FILE=path/to/file.txt"
	@echo ""

## ---------------------------------------------------------------- tests ---

test: test-py test-js test-parity  ## Run every test suite

test-py:  ## Python engine tests (stdlib unittest)
	@$(PY) tests/test_gptcleaner.py

test-js:  ## JavaScript engine tests
	@$(NODE) tests/test_cleaner.mjs

test-parity:  ## Assert both engines produce identical output
	@$(PY) tests/test_parity.py

check: lint test  ## What CI runs: lint, then all tests

lint:  ## Syntax-check Python, JavaScript and shell sources
	@$(PY) -m py_compile $(CLI) tests/*.py && echo "ok - python syntax"
	@$(NODE) --check $(WEB)/cleaner.js && $(NODE) --check $(WEB)/app.js && echo "ok - javascript syntax"
	@bash -n install.sh && bash -n macos/build.sh && echo "ok - shell syntax"
	@$(PY) -c "import json; json.load(open('tests/cases.json')); print('ok - cases.json parses')"
	@$(PY) -c "import pathlib,sys; p=pathlib.Path('tests/cases.json').read_text(); \
		bad=[hex(ord(c)) for c in p if ord(c) in (0x200b,0xfeff,0x00ad,0x2060,0x200d)]; \
		sys.exit('literal invisible chars in fixtures: '+str(bad)) if bad else print('ok - fixtures escaped')"

## ------------------------------------------------------------------ web ---

serve:  ## Serve the web app on $(PORT)
	@$(PY) $(CLI) --serve --port $(PORT)

open: ## Serve and open a browser
	@($(PY) $(CLI) --serve --port $(PORT) &) && sleep 1 && open http://localhost:$(PORT)

dist:  ## Inline the web app into one self-contained HTML file (dist/gptcleaner.html)
	@mkdir -p dist
	@$(PY) tools/bundle.py > dist/gptcleaner.html
	@echo "wrote dist/gptcleaner.html ($$(wc -c < dist/gptcleaner.html) bytes)"

## ---------------------------------------------------------------- macOS ---

app:  ## Build GPTCleaner.app (universal binary)
	@./macos/build.sh

app-run:  ## Build and launch the macOS app
	@./macos/build.sh --run

app-install:  ## Build and move the app to /Applications
	@./macos/build.sh --install

app-clean:  ## Remove the macOS build output
	@rm -rf macos/build && echo "removed macos/build"

## --------------------------------------------------------------- skills ---

install:  ## Install the skills into every AI harness on this machine
	@./install.sh

install-dry:  ## Show what `make install` would change
	@./install.sh --dry-run

uninstall:  ## Remove the skills from every harness
	@./install.sh --uninstall

## ------------------------------------------------------------------ use ---

detect:  ## Report hidden characters in FILE=path/to/file.txt
	@test -n "$(FILE)" || { echo "usage: make detect FILE=notes.txt" >&2; exit 2; }
	@$(PY) $(CLI) "$(FILE)" --detect

demo:  ## Clean a deliberately haunted sample and show the report
	@$(PY) -c "import sys; sys.stdout.write('\ufeffHere\u2019s the \u201cfinal\u201d draft \u2014 with a zero\u200bwidth space, a soft\u00adhyphen and hidden tags.\U000e0057\U000e0054\u2060\n')" \
		| $(PY) $(CLI) --detect
	@echo ""
	@$(PY) -c "import sys; sys.stdout.write('\ufeffHere\u2019s the \u201cfinal\u201d draft \u2014 with a zero\u200bwidth space, a soft\u00adhyphen and hidden tags.\U000e0057\U000e0054\u2060\n')" \
		| $(PY) $(CLI) -s

## ---------------------------------------------------------------- chores --

clean: app-clean  ## Remove all build output and caches
	@rm -rf dist __pycache__ **/__pycache__ .pytest_cache
	@find . -name '*.pyc' -delete
	@echo "clean"

tree:  ## Show what would be published
	@git ls-files 2>/dev/null | head -40 || find . -path ./.git -prune -o -type f -print | sort
