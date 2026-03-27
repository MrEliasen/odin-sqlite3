SHELL := /bin/sh

SQLITE_VERSION ?= 3510300
SQLITE_AMALGAMATION_ZIP := sqlite-amalgamation-$(SQLITE_VERSION).zip
SQLITE_AMALGAMATION_URL := https://sqlite.org/2026/$(SQLITE_AMALGAMATION_ZIP)

DEPS_DIR := deps
DEPS_BIN_DIR := $(DEPS_DIR)/bin
BINDGEN_DIR := $(DEPS_DIR)/odin-c-bindgen
BINDGEN_BIN := $(DEPS_BIN_DIR)/bindgen

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
	@echo "  generate            Generate raw bindings into sqlite/raw/generated"
	@echo "  postgen-patch       Apply deterministic post-generation patches to raw bindings"
	@echo "  regenerate          Regenerate raw bindings and apply post-generation patches"
	@echo "  package-dir         Create release-friendly package directory in out/"
	@echo "  package-zip         Zip the release package"
	@echo "  clean-generated     Remove generated raw bindings"
	@echo "  clean-out           Remove out/"
	@echo "  clean-deps          Remove deps/"
	@echo "  clean               Remove generated, out, and deps"
	@echo "  test                Runs odin checks and tests"

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
	cd "$(BINDGEN_DIR)" && git checkout 408a6f4e

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
	TMP_ZIP="$(OUT_DIR)/$(SQLITE_AMALGAMATION_ZIP)"; \
	TMP_DIR="$(OUT_DIR)/sqlite-amalgamation-$(SQLITE_VERSION)"; \
	mkdir -p "$(OUT_DIR)"; \
	curl -L "$(SQLITE_AMALGAMATION_URL)" -o "$$TMP_ZIP"; \
	rm -rf "$$TMP_DIR"; \
	unzip -q "$$TMP_ZIP" -d "$(OUT_DIR)"; \
	cp "$$TMP_DIR/sqlite3.h" "$(SQLITE_HEADER)"; \
	echo "Wrote $(SQLITE_HEADER)"

.PHONY: download-sqlite
download-sqlite: $(SQLITE_HEADER)

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
	python3 packaging/apply_postgen_patches.py

.PHONY: regenerate
regenerate: generate postgen-patch

.PHONY: package-dir
package-dir:
	@set -eu; \
	rm -rf "$(PACKAGE_DIR)"; \
	mkdir -p "$(PACKAGE_DIR)"; \
	cp -R sqlite "$(PACKAGE_DIR)/sqlite"; \
	if [ -f LICENSE ]; then cp LICENSE "$(PACKAGE_DIR)/"; fi; \
	echo "Wrote $(PACKAGE_DIR)"

.PHONY: package-zip
package-zip: package-dir
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
	odin check sqlite/package.odin -file; \
	odin check tests; \
	find packaging/examples -name main.odin -exec dirname {} \; | sort | while read d; do odin check "$$d" || exit 1; done; \
	odin run tests; \
	find packaging/examples -name main.odin -exec dirname {} \; | sort | while read d; do echo "Running example $$d"; odin run "$$d" || exit 1; done;

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
