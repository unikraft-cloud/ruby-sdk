# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

# Release channel to generate against (maps to a branch of the openapi repo).
CHANNEL           ?= prod-staging
SPEC_BASE         ?= https://raw.githubusercontent.com/unikraft-cloud/openapi/refs/heads/$(CHANNEL)
PLATFORM_SPEC     ?= $(SPEC_BASE)/platform.json
CONTROLPLANE_SPEC ?= $(SPEC_BASE)/controlplane.json

GO            ?= go
BUNDLE        ?= bundle
OPENAPI_GEN   ?= $(GO) run unikraft.com/x/tools/openapi-gen@latest

TEMPLATES     ?= ./templates
OUTPUT        ?= ./lib/unikraft/cloud/api

.PHONY: all
all: generate build

# TypeSpec namespaces its schemas (`Instances.Instance`), which is not a legal
# Ruby constant; --namespace-flatten=strip restores the bare names.
.PHONY: generate
generate: ## Regenerate the platform and control-plane plumbing clients.
	rm -f $(OUTPUT)/platform/*.gen.rb
	$(OPENAPI_GEN) \
		-i $(PLATFORM_SPEC) \
		-o $(OUTPUT)/platform \
		-t $(TEMPLATES) \
		-v module=Platform \
		--namespace-flatten=strip
	rm -f $(OUTPUT)/controlplane/*.gen.rb
	$(OPENAPI_GEN) \
		-i $(CONTROLPLANE_SPEC) \
		-o $(OUTPUT)/controlplane \
		-t $(TEMPLATES) \
		-v module=ControlPlane \
		--namespace-flatten=strip

.PHONY: build
build: ## Build the gem into pkg/.
	$(BUNDLE) exec rake build

.PHONY: check-package
check-package: ## Install the built gem into a temporary GEM_HOME and load it.
	$(BUNDLE) exec rake check_package

.PHONY: lint
lint: ## Lint and format-check with RuboCop.
	$(BUNDLE) exec rake lint

.PHONY: test
test: ## Run the unit test suite.
	$(BUNDLE) exec rake test

.PHONY: clean
clean: ## Remove build output.
	rm -rf pkg

.PHONY: help
help: ## Show this help.
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
