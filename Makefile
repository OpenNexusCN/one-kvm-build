SHELL := /bin/bash
BOARD ?= fmx1-pro
BOARDS ?= all

.PHONY: help validate list matrix plan build build-all check test clean

help:
	@echo "Targets:"
	@echo "  make validate        Validate boards/*.conf"
	@echo "  make list            List configured boards"
	@echo "  make matrix          Print the selected board matrix (BOARDS=all|id,...)"
	@echo "  make plan            Resolve base images, kernel and One-KVM releases"
	@echo "  make build           Build one board (BOARD=fmx1-pro), needs sudo"
	@echo "  make build-all       Build every enabled board, needs sudo"
	@echo "  make check           Syntax-check shell and Python helpers"
	@echo "  make test            Run offline tooling tests"
	@echo "  make clean           Remove work/ and out/"

validate:
	bash scripts/validate-boards.sh

list:
	bash scripts/list-boards.sh

matrix:
	bash scripts/prepare-matrix.sh --boards "$(BOARDS)"

plan:
	bash scripts/plan-build.sh --boards "$(BOARDS)"

build:
	sudo -E bash scripts/build-image.sh \
		--board "$(BOARD)" \
		--output-dir "$(CURDIR)/out" \
		--work-dir "$(CURDIR)/work"

build-all:
	@for board in $$(bash scripts/prepare-matrix.sh --boards "$(BOARDS)" | jq -r '.[].board'); do \
		echo "==> $$board"; \
		sudo -E bash scripts/build-image.sh --board "$$board" \
			--output-dir "$(CURDIR)/out" --work-dir "$(CURDIR)/work" || exit 1; \
	done

check:
	@set -e; \
	for f in $$(find scripts -type f -name '*.sh'); do bash -n "$$f"; done; \
	python3 -m py_compile scripts/lib/release_tool.py scripts/lib/extlinux_patch.py; \
	echo "syntax checks passed"

test:
	bash tests/run-tests.sh

clean:
	rm -rf work out
