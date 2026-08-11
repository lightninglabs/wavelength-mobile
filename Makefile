SHELL := /bin/bash

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SAMPLE_DIR := $(REPO_ROOT)/ios/Sample
PROJECT := $(SAMPLE_DIR)/Wavelength.xcodeproj
SCHEME := Wavelength
DERIVED_DATA ?= $(SAMPLE_DIR)/DerivedData
SIMULATOR_UDID ?=

.PHONY: help framework generate simulator build test run \
	check-regtest-env run-regtest test-regtest clean

help: ## Show the available developer commands.
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

framework: ## Fetch or build Wavewalletdk.xcframework when it is missing.
	@if [[ ! -d "$(REPO_ROOT)/ios/WalletKit/Frameworks/Wavewalletdk.xcframework" ]]; then \
		"$(REPO_ROOT)/scripts/fetch-xcframework.sh"; \
	fi

generate: ## Generate the Xcode project with xcodegen.
	@cd "$(SAMPLE_DIR)" && xcodegen generate

simulator: ## Print the selected Simulator UDID, booting it if necessary.
	@SIMULATOR_UDID="$(SIMULATOR_UDID)" "$(REPO_ROOT)/scripts/select-ios-simulator.sh"

build: framework generate ## Build the app for an automatically selected iPhone Simulator.
	@udid="$$(SIMULATOR_UDID="$(SIMULATOR_UDID)" "$(REPO_ROOT)/scripts/select-ios-simulator.sh")"; \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-destination "platform=iOS Simulator,id=$$udid" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGNING_REQUIRED=YES \
		CODE_SIGN_IDENTITY=- \
		build

test: framework generate ## Run unit tests; live regtest UI tests skip unless enabled.
	@udid="$$(SIMULATOR_UDID="$(SIMULATOR_UDID)" "$(REPO_ROOT)/scripts/select-ios-simulator.sh")"; \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-destination "platform=iOS Simulator,id=$$udid" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGNING_REQUIRED=YES \
		CODE_SIGN_IDENTITY=- \
		test

run: ## Build, install, and launch the app in an iPhone Simulator.
	@SIMULATOR_UDID="$(SIMULATOR_UDID)" "$(REPO_ROOT)/scripts/run-ios-sample.sh"

check-regtest-env:
	@missing=(); \
	for name in WAVELENGTH_OPERATOR_ADDRESS WAVELENGTH_SWAP_ADDRESS WAVELENGTH_ESPLORA_URL; do \
		[[ -n "$${!name:-}" ]] || missing+=("$$name"); \
	done; \
	if (( $${#missing[@]} )); then \
		echo "Missing regtest environment variables: $${missing[*]}" >&2; \
		echo "Export endpoints for a live local environment before running this target." >&2; \
		exit 2; \
	fi

run-regtest: check-regtest-env ## Build and run using exported regtest endpoints.
	@WAVELENGTH_REGTEST=1 \
	SIMULATOR_UDID="$(SIMULATOR_UDID)" \
	"$(REPO_ROOT)/scripts/run-ios-sample.sh"

test-regtest: check-regtest-env framework generate ## Run opt-in live UI tests against exported regtest endpoints.
	@WAVELENGTH_REGTEST=1 \
	WAVELENGTH_UI_REGTEST=1 \
	SIMULATOR_UDID="$(SIMULATOR_UDID)" \
	$(MAKE) --no-print-directory test

clean: ## Remove generated Xcode and DerivedData output.
	@rm -rf "$(PROJECT)" "$(DERIVED_DATA)"
