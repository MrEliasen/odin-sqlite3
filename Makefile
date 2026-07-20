SHELL := /bin/sh

PYTHON ?= python3
ODIN ?= odin
QUALIFICATION_SQLITE_LIBRARY ?=
SQLITE_FEATURE_PROFILE ?= default

ifeq ($(OS),Windows_NT)
PINNED_SQLITE_LIBRARY = $(OUT_DIR)/ci-sqlite/sqlite3.lib
else
PINNED_SQLITE_LIBRARY = $(OUT_DIR)/ci-sqlite/libsqlite3.a
endif

DEPS_DIR := deps
DEPS_BIN_DIR := $(DEPS_DIR)/bin
BINDGEN_DIR := $(DEPS_DIR)/odin-c-bindgen
BINDGEN_BIN := $(DEPS_BIN_DIR)/bindgen
BINDGEN_COMMIT := 408a6f4e3c35a17e4517dc374c5c7edd19081e9f

INPUT_DIR := input
SQLITE_HEADER := $(INPUT_DIR)/sqlite3.h

RAW_GENERATED_DIR := sqlite/raw/generated

OUT_DIR := out
PACKAGE_DIR := $(OUT_DIR)/odin-sqlite-package
PACKAGE_ZIP := $(OUT_DIR)/odin-sqlite-package.zip

.PHONY: help
help:
	@echo "Targets:"
	@echo "  install-build-deps  Install build deps for macOS or Linux"
	@echo "  bindgen             Clone and build odin-c-bindgen into deps/bin"
	@echo "  download-sqlite     Download sqlite3.h into input/"
	@echo "  build-ci-sqlite     Build the pinned all-feature SQLite qualification library"
	@echo "  generate            Generate raw bindings into sqlite/raw/generated"
	@echo "  postgen-patch       Apply deterministic post-generation patches to raw bindings"
	@echo "  verify-raw-abi      Compare generated Odin layouts with both C headers"
	@echo "  regenerate          Regenerate raw bindings and apply post-generation patches"
	@echo "  package             Create release-friendly package directory in out/"
	@echo "  package-dir         Create package directory (legacy alias)"
	@echo "  package-check       Type-check the packaged wrapper and rewritten examples"
	@echo "  package-zip         Zip the release package"
	@echo "  clean-generated     Remove generated raw bindings"
	@echo "  clean-out           Remove out/"
	@echo "  clean-deps          Remove deps/"
	@echo "  clean               Remove generated, out, and deps"
	@echo "  test                Run all checks, tests, and examples natively"
	@echo "  test-features       Build pinned SQLite and run all SQLite feature contracts"
	@echo "  cross-check         Compile-only raw/wrapper checks for 64-bit macOS/Linux/Windows"
	@echo "  test-sanitize       Run all tests and examples natively under AddressSanitizer"
	@echo "  test-features-sanitize  Run all SQLite feature contracts under AddressSanitizer"
	@echo "  test-orchestration  Negative self-test for fail-fast qualification"
	@echo "  check-feature-contracts  Enforce SQLite feature-test methodology comments"
	@echo "  check-example-memory  Enforce the fail-closed example allocator harness"
	@echo "  verify-optional-link  Run optional-symbol link/reference probe (requires QUALIFICATION_SQLITE_LIBRARY)"

.PHONY: install-build-deps
install-build-deps:
	@set -eu; \
	OS="$$(uname -s)"; \
	if [ "$$OS" = "Darwin" ]; then \
		if ! command -v brew >/dev/null 2>&1; then \
			echo "Homebrew is required on macOS: https://brew.sh"; \
			exit 1; \
		fi; \
		brew install llvm; \
		echo ""; \
		echo "Add this to your shell profile if needed:"; \
		echo '  export PATH="$$(brew --prefix llvm)/bin:$$PATH"'; \
		echo '  export LIBCLANG_PATH="$$(brew --prefix llvm)/lib"'; \
	elif [ "$$OS" = "Linux" ]; then \
		if command -v apt-get >/dev/null 2>&1; then \
			sudo apt-get update; \
			sudo apt-get install -y build-essential pkg-config libclang-dev llvm-dev clang curl unzip zip git; \
		else \
			echo "Unsupported Linux package manager for this Makefile."; \
			echo "Install these manually: clang, llvm, libclang-dev, curl, unzip, zip, git"; \
			exit 1; \
		fi; \
	else \
		echo "Unsupported OS: $$OS"; \
		exit 1; \
	fi

$(DEPS_BIN_DIR):
	mkdir -p "$(DEPS_BIN_DIR)"

$(BINDGEN_DIR):
	git clone https://github.com/karl-zylinski/odin-c-bindgen.git "$(BINDGEN_DIR)"; \
	cd "$(BINDGEN_DIR)" && git checkout "$(BINDGEN_COMMIT)"

$(BINDGEN_BIN): | $(DEPS_BIN_DIR) $(BINDGEN_DIR)
	@set -eu; \
	OS="$$(uname -s)"; \
	if [ "$$OS" = "Darwin" ]; then \
		LLVM_PREFIX="$$(brew --prefix llvm)"; \
		cd "$(BINDGEN_DIR)" && \
		CPATH="$$LLVM_PREFIX/include:$${CPATH:-}" \
		LIBRARY_PATH="$$LLVM_PREFIX/lib:$${LIBRARY_PATH:-}" \
		odin build src -out:../../$(BINDGEN_BIN) \
			-extra-linker-flags:"-L$$LLVM_PREFIX/lib -Wl,-rpath,$$LLVM_PREFIX/lib"; \
	elif [ "$$OS" = "Linux" ]; then \
		LLVM_LIBDIR=""; \
		if command -v llvm-config >/dev/null 2>&1; then \
			LLVM_LIBDIR="$$(llvm-config --libdir)"; \
		else \
			for d in /usr/lib/llvm-*/lib /usr/lib64/llvm*/lib /usr/lib/x86_64-linux-gnu; do \
				if [ -d "$$d" ] && [ -e "$$d/libclang.so" -o -e "$$d/libclang.so.1" ]; then \
					LLVM_LIBDIR="$$d"; \
					break; \
				fi; \
			done; \
		fi; \
		if [ -z "$$LLVM_LIBDIR" ]; then \
			echo "Could not determine LLVM libdir containing libclang"; \
			exit 1; \
		fi; \
		cd "$(BINDGEN_DIR)" && \
		LIBRARY_PATH="$$LLVM_LIBDIR:$${LIBRARY_PATH:-}" \
		LD_LIBRARY_PATH="$$LLVM_LIBDIR:$${LD_LIBRARY_PATH:-}" \
		odin build src -out:../../$(BINDGEN_BIN) \
			-extra-linker-flags:"-L$$LLVM_LIBDIR -Wl,-rpath,$$LLVM_LIBDIR -lclang"; \
	else \
		cd "$(BINDGEN_DIR)" && odin build src -out:../../$(BINDGEN_BIN); \
	fi

.PHONY: bindgen
bindgen: $(BINDGEN_BIN)

$(INPUT_DIR):
	mkdir -p "$(INPUT_DIR)"

$(SQLITE_HEADER): | $(INPUT_DIR)
	@set -eu; \
	$(PYTHON) ci/build_sqlite.py \
		--output "$(OUT_DIR)/sqlite-source" \
		--header-output "$(SQLITE_HEADER)" \
		--header-only

.PHONY: download-sqlite
download-sqlite: $(SQLITE_HEADER)

.PHONY: build-ci-sqlite
build-ci-sqlite:
	@set -eu; \
	$(PYTHON) ci/build_sqlite.py --output "$(OUT_DIR)/ci-sqlite"

.PHONY: generate
generate: $(BINDGEN_BIN) $(SQLITE_HEADER)
	@set -eu; \
	rm -rf "$(RAW_GENERATED_DIR)"; \
	OS="$$(uname -s)"; \
	if [ "$$OS" = "Darwin" ]; then \
		LLVM_PREFIX="$$(brew --prefix llvm)"; \
		SDKROOT="$$(xcrun --sdk macosx --show-sdk-path)"; \
		CLANG_RESOURCE_DIR="$$(ls -d "$$LLVM_PREFIX"/lib/clang/* | sort -V | tail -n1)"; \
		PATH="$$LLVM_PREFIX/bin:$$PATH" \
		SDKROOT="$$SDKROOT" \
		CPATH="$$CLANG_RESOURCE_DIR/include:$$SDKROOT/usr/include:$${CPATH:-}" \
		C_INCLUDE_PATH="$$CLANG_RESOURCE_DIR/include:$$SDKROOT/usr/include:$${C_INCLUDE_PATH:-}" \
		"$(BINDGEN_BIN)" .; \
	else \
		"$(BINDGEN_BIN)" .; \
	fi

.PHONY: postgen-patch
postgen-patch:
	@set -eu; \
	$(PYTHON) packaging/apply_postgen_patches.py

.PHONY: verify-raw-abi
verify-raw-abi:
	@set -eu; \
	$(PYTHON) packaging/apply_postgen_patches.py --verify-abi

.PHONY: regenerate
regenerate: generate postgen-patch

.PHONY: package
package: package-dir

.PHONY: package-dir
package-dir:
	@set -eu; \
	rm -rf "$(PACKAGE_DIR)"; \
	mkdir -p "$(PACKAGE_DIR)"; \
	cp -R sqlite "$(PACKAGE_DIR)/sqlite"; \
	cp LICENSE README.md packaging/README.package.md "$(PACKAGE_DIR)/"; \
	cp -R packaging/examples "$(PACKAGE_DIR)/examples"; \
	find "$(PACKAGE_DIR)/examples" -name main.odin | while IFS= read -r file; do \
		sed \
			-e 's|import sqlite "../../../sqlite"|import sqlite "../../sqlite"|' \
			-e 's|import sqlite "../../../../sqlite"|import sqlite "../../../sqlite"|' \
			"$$file" > "$$file.tmp"; \
		mv "$$file.tmp" "$$file"; \
	done; \
	echo "Wrote $(PACKAGE_DIR)"

.PHONY: package-check
package-check: package-dir
	@set -eu; \
	$(ODIN) check "$(PACKAGE_DIR)/sqlite" -no-entry-point; \
	find "$(PACKAGE_DIR)/examples" -name main.odin -exec dirname {} \; | sort | while IFS= read -r directory; do \
		$(ODIN) check "$$directory" || exit 1; \
	done; \
	echo "Packaged wrapper and examples type-check successfully"

.PHONY: package-zip
package-zip: package-check
	@set -eu; \
	rm -f "$(PACKAGE_ZIP)"; \
	cd "$(OUT_DIR)" && zip -qr "$$(basename "$(PACKAGE_ZIP)")" "$$(basename "$(PACKAGE_DIR)")"; \
	echo "Wrote $(PACKAGE_ZIP)"

.PHONY: clean-generated
clean-generated:
	rm -rf "$(RAW_GENERATED_DIR)"

.PHONY: clean-out
clean-out:
	rm -rf "$(OUT_DIR)"

.PHONY: clean-deps
clean-deps:
	rm -rf "$(DEPS_DIR)"

.PHONY: clean
clean: clean-generated clean-out clean-deps

.PHONY: test
test:
	@set -eu; \
	$(PYTHON) ci/qualify.py --odin "$(ODIN)" native \
		$(if $(strip $(QUALIFICATION_SQLITE_LIBRARY)),--sqlite-library "$(QUALIFICATION_SQLITE_LIBRARY)") \
		--feature-profile "$(SQLITE_FEATURE_PROFILE)"

.PHONY: check-feature-contracts
check-feature-contracts:
	@set -eu; \
	$(PYTHON) ci/check_feature_test_contracts.py

.PHONY: check-example-memory
check-example-memory:
	@set -eu; \
	$(PYTHON) ci/check_example_memory_harness.py

.PHONY: test-features
test-features: build-ci-sqlite
	@set -eu; \
	$(PYTHON) ci/qualify.py --odin "$(ODIN)" native \
		--sqlite-library "$(PINNED_SQLITE_LIBRARY)" \
		--feature-profile all

.PHONY: test-features-sanitize
test-features-sanitize: build-ci-sqlite
	@set -eu; \
	$(PYTHON) ci/qualify.py --odin "$(ODIN)" sanitize \
		--sqlite-library "$(PINNED_SQLITE_LIBRARY)" \
		--feature-profile all

.PHONY: cross-check
cross-check:
	@set -eu; \
	$(PYTHON) ci/qualify.py --odin "$(ODIN)" cross-check

.PHONY: test-sanitize
test-sanitize:
	@set -eu; \
	$(PYTHON) ci/qualify.py --odin "$(ODIN)" sanitize \
		$(if $(strip $(QUALIFICATION_SQLITE_LIBRARY)),--sqlite-library "$(QUALIFICATION_SQLITE_LIBRARY)") \
		--feature-profile "$(SQLITE_FEATURE_PROFILE)"

.PHONY: test-orchestration
test-orchestration:
	@set -eu; \
	$(PYTHON) ci/qualify.py self-test

.PHONY: verify-optional-link
verify-optional-link:
	@set -eu; \
	if [ -z "$(strip $(QUALIFICATION_SQLITE_LIBRARY))" ]; then \
		echo "QUALIFICATION_SQLITE_LIBRARY must name the SQLite library to verify"; \
		exit 2; \
	fi; \
	$(PYTHON) packaging/apply_postgen_patches.py \
		--verify-optional-link "$(QUALIFICATION_SQLITE_LIBRARY)" \
		--feature-profile "$(SQLITE_FEATURE_PROFILE)"

.PHONY: publish
publish:
	@set -e; \
	printf "Version (e.g. 0.1.0): " ; \
	read ver; \
	if [ -z "$$ver" ]; then echo "Version is required"; exit 1; fi; \
	ver=$${ver#v}; \
	tag="$$ver"; \
	git diff --quiet || (echo "Working tree is dirty. Commit or stash changes before publishing."; exit 1); \
	git fetch --tags origin >/dev/null 2>&1 || true; \
	if git rev-parse -q --verify "refs/tags/$$tag" >/dev/null; then \
		if git ls-remote --exit-code --tags origin "refs/tags/$$tag" >/dev/null 2>&1; then \
			echo "Tag already exists on origin: $$tag"; \
			exit 1; \
		fi; \
		echo "Tag exists locally but not on origin; deleting local tag $$tag"; \
		git tag -d "$$tag" >/dev/null; \
	fi; \
	if git ls-remote --exit-code --tags origin "refs/tags/$$tag" >/dev/null 2>&1; then \
		echo "Tag already exists on origin: $$tag"; \
		exit 1; \
	fi; \
	git tag "$$tag"; \
	git push origin "refs/tags/$$tag:refs/tags/$$tag"; \
	echo "Pushed tag $$tag (GitHub Actions will build and create the release)."
