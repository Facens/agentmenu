# AgentMenu — builds with Command Line Tools only. No Xcode, no xcodebuild.
SWIFT   ?= swift
CONFIG  ?= release
VERSION ?= 0.0.0-alpha
DIST    ?= dist

.PHONY: all build test tmux bundle run icons clean

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

# The tmux the app ships (R17, KTD2): built from pinned sources, static, with
# jemalloc, cached under .build/tmux keyed by packaging/tmux/sources.sha256 and
# build.sh. The first build takes a couple of minutes; a cache hit is
# instant. `make clean` removes the cache with the rest of .build.
tmux:
	packaging/tmux/build.sh

bundle: tmux
	VERSION=$(VERSION) CONFIG=$(CONFIG) DIST=$(DIST) packaging/bundle.sh

run: bundle
	open $(DIST)/AgentMenu.app

clean:
	rm -rf .build $(DIST)
