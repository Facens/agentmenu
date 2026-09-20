# AgentMenu — builds with Command Line Tools only. No Xcode, no xcodebuild.
SWIFT   ?= swift
CONFIG  ?= release
VERSION ?= 0.0.0-alpha
DIST    ?= dist

.PHONY: all build test bundle run icons clean

all: build

build:
	$(SWIFT) build -c $(CONFIG)

# XCTest and swift-testing ship with Xcode, not with Command Line Tools, and
# R32 forbids Xcode-only tooling — so the suite is an executable, not a
# `.testTarget`, and this is the command that runs it.
# The CLI is built first on purpose: several scenarios run the real binary,
# and when it is absent they skip themselves — silently reporting a pass with
# 68 fewer expectations on a clean checkout than on a machine that happened to
# have built it.
test:
	$(SWIFT) build --product AgentMenuCLI
	$(SWIFT) run AgentMenuKitTests

# Renders the app icon and the menu-bar template from code (no Xcode asset
# catalogue, no committed binaries).
icons:
	$(SWIFT) packaging/icon/make-icons.swift

bundle:
	VERSION=$(VERSION) CONFIG=$(CONFIG) DIST=$(DIST) packaging/bundle.sh

run: bundle
	open $(DIST)/AgentMenu.app

clean:
	rm -rf .build $(DIST)
