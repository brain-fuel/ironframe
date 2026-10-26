# Ironframe's front door: make and a verb runs the stack, npm, OpenTofu, podman and canon commands
# the docs name. Every check runs locally. ref:DEC-haskell-wasm-core

# | The canon checkout whose grammars and binary check this repository. ref:DEC-vetting-deferred
CANON_HOME ?= ../canon

# | The podman binary, as Ironframe itself finds it. ref:DEC-podman-compose
PODMAN ?= $(shell command -v podman || echo /opt/podman/bin/podman)

# | The OpenTofu modules, each validated and tested on its own. ref:DEC-opentofu
MODULES = $(wildcard modules/*)

# | Every JavaScript file of the npm package and its tests. ref:DEC-haskell-wasm-core
NPM_SOURCES = $(wildcard npm/*.mjs npm/bin/*.mjs npm/clouds/*.mjs npm/test/*.mjs)

.DEFAULT_GOAL := help
.PHONY: help build wasm test e2e e2e-calm lint integrity tofu-check canon check config-service-image clean

# | What you can ask for, read from the help lines of the rules below.
help: ## what you can ask for
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | awk -F'\t' '{ printf "  %-22s %s\n", $$1, $$2 }'

# | Build the core natively, then the WASM core the npm package runs. ref:DEC-haskell-wasm-core
build: ## build the core natively and to WASM
	stack build --no-terminal
	tools/wasm.sh

# | Build npm/core.wasm and npm/core_jsffi.js with ghc-wasm-meta and record their fingerprints in
# | npm/build.json. ref:DEC-haskell-wasm-core
wasm: ## build the WASM core into npm/
	tools/wasm.sh

# | Run the core's tests natively, the corpus included, then the npm package's tests over the WASM
# | core. ref:REQ-manifest-validation
test: ## run the Haskell and npm tests
	stack test --no-terminal
	cd npm && npm test

# | Bring both examples up against LawTwin's real images in podman, run each app, attest and take
# | everything down; needs podman and the images. ref:REQ-end-to-end-with-twins
e2e: ## run the end-to-end test against LawTwin's images in podman
	IRONFRAME_E2E=1 node --test npm/test/e2e.test.mjs

# | Run the calm-shop example's laws against real, twin and mixed bindings resolved from its CALM
# | architecture, with faults, resets and replay; needs podman, Go, npm, LawTwin's images and the
# | real products' images. ref:REQ-calm-end-to-end
e2e-calm: ## run the CALM end-to-end test: real, twin and mixed bindings
	IRONFRAME_E2E=1 node --test npm/test/e2e-calm.test.mjs

# | The core built with warnings as errors, and every JavaScript file parsed. ref:DEC-haskell-wasm-core
lint: ## build with -Werror and check the JavaScript parses
	stack build --no-terminal --ghc-options=-Werror
	@for file in $(NPM_SOURCES); do node --check $$file || exit 1; done

# | npm/build.json matches the core's sources and the WASM artifacts built from them.
# | ref:DEC-haskell-wasm-core
integrity: ## check the npm package's fingerprints
	stack --no-terminal run ironframe-dev -- integrity

# | Validate and test every OpenTofu module against mocked providers. ref:REQ-modules-plan
tofu-check: ## validate and test the OpenTofu modules
	@for module in $(MODULES); do \
		echo "== $$module"; \
		tofu -chdir=$$module fmt -check -recursive && \
		tofu -chdir=$$module init -backend=false -input=false >/dev/null && \
		tofu -chdir=$$module validate && \
		tofu -chdir=$$module test || exit 1; \
	done

# | Link .canon to the canon checkout and check the repository with it. ref:DEC-vetting-deferred
canon: ## check the repository with canon
	ln -sfn $(abspath $(CANON_HOME)) .canon
	cd $(CANON_HOME) && stack build --no-terminal
	$$(cd $(CANON_HOME) && stack path --local-install-root)/bin/canon check

# | Everything a release needs to pass. ref:DEC-haskell-wasm-core
check: lint test integrity tofu-check canon ## run every check

# | The configuration service's image, the npm package's Node host over the WASM core, tagged as
# | the manifest's default. ref:DEC-config-service
config-service-image: ## build the configuration service image with podman
	$(PODMAN) build -f config-service/Containerfile -t localhost/ironframe-config-service:0.1.0 .

# | Remove build output and every generated working directory; the shipped WASM core in npm/
# | stays. ref:DEC-manifest-shape
clean: ## remove build output
	stack clean --no-terminal
	rm -rf wasm/dist-newstyle
	find . -name .ironframe -type d -prune -exec rm -rf {} +

# | Exercise actual Go laws with isolated observations and binding promotion.
.PHONY: e2e-observed
e2e-observed: ## observed Kafka/HTTP runs, publication, adoption and reversion
	node tools/observed-shop.mjs
