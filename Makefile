SHELL := /bin/bash

# Pipe build output through xcsift when it is installed; fall back to raw output.
XCSIFT := $(shell command -v xcsift 2>/dev/null)
ifdef XCSIFT
PIPE := | xcsift
else
PIPE :=
endif

HOST_PROJECT := Examples/WorkoutFixturesHost/WorkoutFixturesHost.xcodeproj
HOST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
SWIFT_SOURCE_DIRS := Sources Tests \
	Examples/WorkoutFixturesHost/WorkoutFixturesHost \
	Examples/WorkoutFixturesHost/WorkoutFixturesHostTests \
	Examples/WorkoutFixturesHost/WorkoutFixturesHostUITests

.PHONY: test test-host lint format smoke

test: ## Run the portable package tests
	set -o pipefail; swift test 2>&1 $(PIPE)

test-host: ## Run the host app unit + UI tests on a simulator
	set -o pipefail; xcodebuild test \
		-project $(HOST_PROJECT) \
		-scheme WorkoutFixturesHost \
		-destination '$(HOST_DESTINATION)' \
		CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES 2>&1 $(PIPE)

lint: ## Check formatting (strict, matches CI)
	swift format lint --strict --recursive $(SWIFT_SOURCE_DIRS)

format: ## Reformat all Swift sources in place
	swift format --in-place --recursive $(SWIFT_SOURCE_DIRS)

smoke: ## CLI round trip: generate variations from a bundled preset, then validate them
	rm -rf .smoke
	swift run workout-fixture generate \
		Sources/WorkoutFixturesTestSupport/Resources/Fixtures/outdoor-run.json \
		--recipe Examples/focused-recipe.json \
		--count 2 --seed 42 --output-directory .smoke
	set -e; for file in .smoke/*.json; do \
		swift run workout-fixture validate "$$file"; \
		swift run workout-fixture inspect "$$file" >/dev/null; \
	done
	rm -rf .smoke
