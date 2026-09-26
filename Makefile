# Lyrical — build and packaging entry points.
#
# Everything here shells out to Scripts/, which is also what CI runs, so there
# is exactly one build path to keep working.
#
#   make install   build and drop Lyrical.app in /Applications
#   make run       ...and launch it
#   make dmg       build dist/Lyrical-<version>.dmg + .zip for a release
#
# Signing for distribution (needs a paid Apple Developer account):
#   make dmg DEVELOPER_ID="Developer ID Application: You (TEAMID)" NOTARY_PROFILE=Lyrical

.DEFAULT_GOAL := app
.PHONY: app dmg install run test test-one icon project clean help

APP := build/Lyrical.app

## app: build build/Lyrical.app
app:
	@./Scripts/build-app.sh

## dmg: build the release .dmg and .zip into dist/
dmg: app
	@./Scripts/package.sh

## install: copy the built app into /Applications
install: app
	@echo "==> Installing to /Applications/Lyrical.app"
	@# Quit a running copy first: replacing the bundle underneath a live process
	@# leaves it running from a deleted inode and the menu bar icon goes stale.
	@# Guarded by pgrep so we don't make your terminal ask for Automation access
	@# just to quit something that was never running.
	@if pgrep -x Lyrical >/dev/null 2>&1; then \
		osascript -e 'quit app "Lyrical"' >/dev/null 2>&1 || pkill -x Lyrical || true; \
		sleep 1; \
	fi
	@rm -rf /Applications/Lyrical.app
	@cp -R $(APP) /Applications/Lyrical.app
	@echo "==> Installed. Launch it from Spotlight or run: make run"

## run: install and launch
run: install
	@open -a /Applications/Lyrical.app
	@echo "==> Lyrical is running — look for the quote.bubble icon in the menu bar"

## test: run the unit tests
test: project
	@xcodebuild -project Lyrical.xcodeproj -scheme Lyrical \
		-configuration Debug -destination 'platform=macOS' test

## test-one: run one test class, e.g. make test-one T=LRCParserTests
test-one: project
	@xcodebuild -project Lyrical.xcodeproj -scheme Lyrical \
		-configuration Debug -destination 'platform=macOS' \
		test -only-testing:LyricalTests/$(T) 2>&1 | grep -E "error:|failed|passed|Executed|TEST (SUCCEEDED|FAILED)" | tail -40

## icon: regenerate Lyrical/Resources/Lyrical.icns
icon:
	@./Scripts/make-icon.swift

## project: regenerate Lyrical.xcodeproj from project.yml
project:
	@xcodegen generate

## clean: remove build and dist output
clean:
	@rm -rf build dist Lyrical.xcodeproj
	@echo "==> Cleaned build/, dist/ and the generated xcodeproj"

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
