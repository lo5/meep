# Makefile for the meepmeep macOS service
#
# Override any variable on the command line, e.g.:
#   make install SOUNDS_DIR=/path/to/sounds SOCKET=/tmp/other.sock

SHELL := /bin/bash

LABEL       ?= org.game-over.meepmeep
PLIST_SRC   ?= LaunchAgent/$(LABEL).plist
AGENTS_DIR  ?= $(HOME)/Library/LaunchAgents
PLIST_DST   ?= $(AGENTS_DIR)/$(LABEL).plist
SOUNDS_DIR  ?= $(HOME)/Library/Sounds
SOCKET      ?= /tmp/meepmeep.sock
LOG         ?= /tmp/meepmeep.log
BINARY      ?= $(CURDIR)/.build/release/meepmeep
DOMAIN      := gui/$(shell id -u)
BOOTOUT_WAIT ?= 2

.DEFAULT_GOAL := help

.PHONY: help build debug clean run install uninstall restart status logs

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the release binary
	swift build -c release

debug: ## Build a debug binary
	swift build

clean: ## Remove build artifacts
	swift package clean
	rm -rf .build

run: build ## Run in the foreground (SOUNDS_DIR=... SOCKET=...)
	$(BINARY) "$(SOUNDS_DIR)" "$(SOCKET)"

install: build ## Build and install the launchd LaunchAgent
	@mkdir -p "$(AGENTS_DIR)"
	@sed -e 's#<string>.*\.build/release/meepmeep</string>#<string>$(BINARY)</string>#' \
		-e 's#$(HOME)/Library/Sounds#$(SOUNDS_DIR)#' \
		-e 's#/tmp/meepmeep.sock#$(SOCKET)#' \
		-e 's#/tmp/meepmeep.log#$(LOG)#g' \
		"$(PLIST_SRC)" > "$(PLIST_DST)"
	@-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) "$(PLIST_DST)"
	@echo "installed $(LABEL) -> socket $(SOCKET), logs $(LOG)"

uninstall: ## Stop and remove the LaunchAgent
	@-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f "$(PLIST_DST)"
	@echo "uninstalled $(LABEL)"

restart: ## Restart the installed LaunchAgent
	@-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	@echo "waiting $(BOOTOUT_WAIT)s for bootout to settle..."
	@sleep $(BOOTOUT_WAIT)
	launchctl bootstrap $(DOMAIN) "$(PLIST_DST)"
	@echo "restarted $(LABEL)"

status: ## Show LaunchAgent status
	@launchctl print $(DOMAIN)/$(LABEL) 2>/dev/null || echo "$(LABEL) is not loaded"

logs: ## Tail the service log
	tail -f "$(LOG)"
