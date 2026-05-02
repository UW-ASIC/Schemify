# Schemify Plugin — Go demo
#
# Build native: make
# Build WASM:   make wasm
# Install:      make install

.PHONY: all native wasm clean install

all: native

native:
	cd src && CGO_ENABLED=1 go build -buildmode=c-shared -o ../go-demo.so .

wasm:
	cd src && tinygo build -o ../go-demo.wasm -target wasm .

install: native
	mkdir -p "$(HOME)/.config/Schemify/go-demo"
	cp go-demo.so "$(HOME)/.config/Schemify/go-demo/"

clean:
	rm -f go-demo.so go-demo.wasm go-demo.h
