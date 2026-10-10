# Ironframe's front door: make and a verb runs the cargo, OpenTofu, podman and canon commands the
# docs name. Every check runs locally. ref:DEC-rust

# | The canon checkout whose grammars and binary check this repository. ref:DEC-vetting-deferred
CANON_HOME ?= ../canon

# | The podman binary, as Ironframe itself finds it. ref:DEC-podman-compose
PODMAN ?= $(shell command -v podman || echo /opt/podman/bin/podman)

# | The OpenTofu modules, each validated and tested on its own. ref:DEC-opentofu
MODULES = $(wildcard modules/*)

.DEFAULT_GOAL := help
.PHONY: help build test e2e lint tofu-check canon check config-service-image clean

# | What you can ask for, read from the help lines of the rules below.
help: ## what you can ask for
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | awk -F'\t' '{ printf "  %-22s %s\n", $$1, $$2 }'

# | Build the command, the configuration service and the example. ref:DEC-rust
build: ## build every crate
	cargo build --workspace

# | Run every crate's tests. ref:REQ-manifest-validation
test: ## run the cargo tests
	cargo test --workspace

# | Bring both examples up against LawTwin's real images in podman, run each app, attest and take
# | everything down; needs podman and the images. ref:REQ-end-to-end-with-twins
e2e: ## run the end-to-end test against LawTwin's images in podman
	cargo test -p ironframe-cli --test e2e -- --ignored --nocapture

# | Formatting and clippy, warnings as errors. ref:DEC-rust
lint: ## check formatting and clippy
	cargo fmt --all -- --check
	cargo clippy --workspace --all-targets -- -D warnings

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

# | Everything a release needs to pass. ref:DEC-rust
check: lint test tofu-check canon ## run every check

# | The configuration service's image, tagged as the manifest's default. ref:DEC-config-service
config-service-image: ## build the configuration service image with podman
	$(PODMAN) build -f crates/ironframe-config-service/Containerfile -t localhost/ironframe-config-service:0.1.0 .

# | Remove build output and every generated working directory. ref:DEC-manifest-shape
clean: ## remove build output
	cargo clean
	find . -name .ironframe -type d -prune -exec rm -rf {} +
