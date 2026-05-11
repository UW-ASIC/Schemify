# EasyImport — Schemify Zig plugin
#
# Build native: make
# Install:      make install
# Run:          make run

PLUGIN_NAME = EasyImport
SCHEMIFY_ROOT  ?= $(realpath ../..)
SCHEMIFY_BIN   ?= $(SCHEMIFY_ROOT)/zig-out/bin/schemify

.PHONY: all native clean install run

all: native

native:
	zig build

install: native
	mkdir -p "$(HOME)/.config/Schemify/$(PLUGIN_NAME)"
	cp zig-out/lib/*.so "$(HOME)/.config/Schemify/$(PLUGIN_NAME)/" 2>/dev/null || true
	@if [ -f plugin.toml ]; then cp plugin.toml "$(HOME)/.config/Schemify/$(PLUGIN_NAME)/"; fi

run: native
	@config="$(HOME)/.config/Schemify"; \
	backup="$$config.run-bak"; \
	rm -rf "$$backup"; \
	cleanup() { rm -rf "$$config"; [ -d "$$backup" ] && mv "$$backup" "$$config"; }; \
	trap cleanup EXIT; \
	[ -d "$$config" ] && mv "$$config" "$$backup"; \
	$(MAKE) install && \
	if [ ! -x "$(SCHEMIFY_BIN)" ]; then \
		echo "Building Schemify..."; \
		(cd "$(SCHEMIFY_ROOT)" && nix develop --command zig build); \
	fi && \
	"$(SCHEMIFY_BIN)"

clean:
	rm -rf zig-out zig-cache .zig-cache
