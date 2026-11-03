SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS := $(ROOT)/scripts

# Prefer MacOSX26.5.sdk when building with Command Line Tools only.
# macOS 27+ SDKs declare @State via an external SwiftUIMacros plugin that ships
# only inside Xcode.app.  This selection is skipped when SDKROOT is already set
# (Xcode / CI) or when the preferred SDK is absent.
_PREFERRED_SDK := /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
ifeq ($(origin SDKROOT), undefined)
    ifneq ($(wildcard $(_PREFERRED_SDK)),)
        export SDKROOT := $(_PREFERRED_SDK)
    endif
endif

.PHONY: bootstrap project test test-worker test-swift build run-demo run package smoke-packaged sign-local sign-release icon clean

bootstrap:
	"$(SCRIPTS)/bootstrap.sh"

project:
	"$(SCRIPTS)/generate-project.sh"

icon:
	swift "$(SCRIPTS)/make-icon.swift" "$(ROOT)"

test:
	"$(SCRIPTS)/test-all.sh"

test-swift:
	"$(SCRIPTS)/test-swift.sh"

test-worker:
	"$(SCRIPTS)/test-worker.sh"

build: project
	"$(SCRIPTS)/build-app.sh" release
	"$(SCRIPTS)/build-app.sh" debug

run-demo: build
	"$(SCRIPTS)/run-demo.sh"

run: build
	"$(SCRIPTS)/run-app.sh"

package: project
	"$(SCRIPTS)/package.sh"

smoke-packaged:
	"$(SCRIPTS)/smoke-packaged.sh"

sign-local:
	"$(SCRIPTS)/sign-local.sh" "$(ROOT)/.build/TagTrail.app"

sign-release:
	"$(SCRIPTS)/sign-release.sh" "$(ROOT)/dist/TagTrail-$(shell uname -m)/TagTrail.app"

clean:
	cd "$(ROOT)" && swift package clean
	rm -rf "$(ROOT)/.build" "$(ROOT)/dist"
