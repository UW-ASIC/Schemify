# Schemify Plugin — Rust demo
#
# Build native: make
# Build WASM:   make web
# Install:      make install

PLUGIN_NAME = rust-demo

.PHONY: all native web clean install

all: native

native:
	cargo build --release
	cp target/release/librust_demo.so $(PLUGIN_NAME).so 2>/dev/null || \
	cp target/release/librust_demo.dylib $(PLUGIN_NAME).dylib 2>/dev/null || true

web:
	cargo build --release --target wasm32-unknown-unknown
	cp target/wasm32-unknown-unknown/release/rust_demo.wasm $(PLUGIN_NAME).wasm

install: native
	mkdir -p "$(HOME)/.config/Schemify/$(PLUGIN_NAME)"
	cp $(PLUGIN_NAME).so "$(HOME)/.config/Schemify/$(PLUGIN_NAME)/" 2>/dev/null || \
	cp $(PLUGIN_NAME).dylib "$(HOME)/.config/Schemify/$(PLUGIN_NAME)/" 2>/dev/null || true

clean:
	cargo clean
	rm -f $(PLUGIN_NAME).so $(PLUGIN_NAME).dylib $(PLUGIN_NAME).wasm
