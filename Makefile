SHELL := /bin/bash

PROJECT   := Vigil.xcodeproj
SCHEME    := Vigil
CONFIG    := Debug
BUILD_DIR := $(CURDIR)/build
APP       := $(BUILD_DIR)/$(CONFIG)/Vigil.app

.PHONY: all project build run stop install clean icon demo-assertion demo-orphan assertions kill-all

all: build

ICONSET := icon/Vigil.iconset
ICNS    := Sources/Resources/Vigil.icns

## Regenerate Vigil.xcodeproj from project.yml.
##
## Depends on the .icns: XcodeGen adds only the files that exist when it runs,
## so generating the project before the icon is compiled leaves Vigil.icns out
## of the Copy Bundle Resources phase — the app builds, signs and notarizes
## cleanly, and ships with the generic icon. 0.3.1 and 0.3.2 both did exactly
## that. (The variables above have to be defined before this rule, because make
## expands a rule's prerequisites at the moment it reads the rule.)
project: $(ICNS)
	@command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	xcodegen generate

## Compile the .iconset into the .icns the bundle loads.
## iconutil ships with macOS, so this needs nothing installed. Editing the
## artwork means editing icon/vigil-icon.svg and running scripts/render-icon.sh
## first, which does need a rasteriser.
icon: $(ICNS)

$(ICNS): $(wildcard $(ICONSET)/*.png)
	@iconutil -c icns "$(ICONSET)" -o "$(ICNS)"
	@echo "Built $(ICNS)"

## Build the app bundle
build: project
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		CONFIGURATION_BUILD_DIR=$(BUILD_DIR)/$(CONFIG) \
		build

## Build and launch. Vigil is an accessory app — it appears in the menu bar,
## not the Dock. Console output stays attached to this terminal.
run: build
	@pkill -x Vigil 2>/dev/null || true
	$(APP)/Contents/MacOS/Vigil

## Quit a running copy
stop:
	@pkill -x Vigil 2>/dev/null || true

## Copy into /Applications. Use CONFIG=Release for an app you intend to leave
## running: `make install CONFIG=Release`
install: build
	@pkill -x Vigil 2>/dev/null || true
	@sleep 1
	@rm -rf /Applications/Vigil.app
	cp -R $(APP) /Applications/
	@echo "Installed to /Applications/Vigil.app ($(CONFIG) build)"
	@open /Applications/Vigil.app
	@echo "Launched. Add it under System Settings > General > Login Items"
	@echo "to have it start automatically."

clean:
	rm -rf $(BUILD_DIR) $(PROJECT) $(ICNS)

# ---------------------------------------------------------------------------
# Distribution
#
# Signing happens after the build rather than inside it, so `make run` keeps
# working with ad-hoc signing and never needs the Developer ID cert. The
# explicit codesign call is also what applies the hardened runtime — xcodebuild
# skips it when ad-hoc signing, which is why Debug builds have always logged
# "Disabling hardened runtime with ad-hoc codesigning".
# ---------------------------------------------------------------------------

SIGN_ID        ?= Developer ID Application: Jordan Alegant (FSY5635NFT)
NOTARY_PROFILE := vigil-notary
DIST_DIR       := $(CURDIR)/dist
RELEASE_APP    := $(BUILD_DIR)/Release/Vigil.app

# Lazy (=) not immediate (:=): the app doesn't exist until after the build.
VERSION         = $(shell defaults read "$(RELEASE_APP)/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)
ZIP             = $(DIST_DIR)/Vigil-$(VERSION).zip

.PHONY: release release-build sign notarize staple verify package install-signed

## Everything: build Release, sign, notarize, staple, verify, zip
release: release-build sign notarize staple verify package

release-build:
	$(MAKE) build CONFIG=Release

## Sign with the hardened runtime and a secure timestamp.
## --timestamp is not optional: without it the signature stops validating when
## the certificate expires, which would break already-distributed copies.
sign:
	@test -d "$(RELEASE_APP)" || { echo "No Release build found. Run: make release-build"; exit 1; }
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(RELEASE_APP)"
	@echo "Signed as: $(SIGN_ID)"

## Submit to Apple's notary service and block until it answers.
## ditto is the archiver Apple's service expects — a zip made any other way
## can lose bundle structure and come back rejected for reasons that have
## nothing to do with your code.
notarize:
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(DIST_DIR)/notarize.zip"
	ditto -c -k --keepParent "$(RELEASE_APP)" "$(DIST_DIR)/notarize.zip"
	@echo "Submitting. This usually takes 1-5 minutes."
	xcrun notarytool submit "$(DIST_DIR)/notarize.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait \
		|| { echo; echo "Rejected. For the reason:"; \
		     echo "  xcrun notarytool log <submission-id> --keychain-profile \"$(NOTARY_PROFILE)\""; \
		     exit 1; }
	@rm -f "$(DIST_DIR)/notarize.zip"

## Attach the notarization ticket to the bundle, so Gatekeeper can approve it
## without a network round trip on the user's machine.
staple:
	xcrun stapler staple "$(RELEASE_APP)"

## Confirm the artifact would actually pass on someone else's Mac, rather than
## finding out from a bug report.
verify:
	@echo "--- signature ---"
	codesign --verify --deep --strict --verbose=2 "$(RELEASE_APP)"
	@echo "--- gatekeeper ---"
	spctl --assess --type execute --verbose=4 "$(RELEASE_APP)"
	@echo "--- stapled ticket ---"
	xcrun stapler validate "$(RELEASE_APP)"
	@echo "--- signing identity ---"
	@codesign -dvvv "$(RELEASE_APP)" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|flags"
	@echo "--- icon ---"
	@test -f "$(RELEASE_APP)/Contents/Resources/Vigil.icns" \
		&& echo "Vigil.icns present" \
		|| { echo "Vigil.icns MISSING from the bundle — the app would ship with the generic icon"; exit 1; }

package:
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(RELEASE_APP)" "$(ZIP)"
	@echo
	@echo "Ready to distribute: $(ZIP)"

## Install the signed, stapled build without rebuilding it.
## Use this instead of `make install` after a release — `install` rebuilds,
## and xcodebuild would re-sign ad-hoc and throw away the notarization.
install-signed:
	@test -d "$(RELEASE_APP)" || { echo "No Release build found. Run: make release"; exit 1; }
	@pkill -x Vigil 2>/dev/null || true
	@sleep 1
	@rm -rf /Applications/Vigil.app
	cp -R "$(RELEASE_APP)" /Applications/
	@open /Applications/Vigil.app
	@echo "Installed the signed build to /Applications/Vigil.app"

DMG = $(DIST_DIR)/Vigil-$(VERSION).dmg

.PHONY: dmg dist

## Drag-to-Applications disk image, signed and notarized in its own right.
## The image needs its own ticket: notarizing the app inside is not enough,
## because a downloaded .dmg carries its own quarantine flag and Gatekeeper
## checks the image before it checks anything in it.
dmg:
	@test -d "$(RELEASE_APP)" || { echo "No signed Release build. Run: make release"; exit 1; }
	@mkdir -p "$(DIST_DIR)"
	bash scripts/make-dmg.sh "$(RELEASE_APP)" "$(DMG)"
	codesign --force --sign "$(SIGN_ID)" --timestamp "$(DMG)"
	@echo "Notarizing the disk image. Another 1-5 minutes."
	xcrun notarytool submit "$(DMG)" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait \
		|| { echo; echo "Rejected. For the reason:"; \
		     echo "  xcrun notarytool log <submission-id> --keychain-profile \"$(NOTARY_PROFILE)\""; \
		     exit 1; }
	xcrun stapler staple "$(DMG)"
	@echo
	@echo "--- disk image ---"
	@spctl --assess --type open --context context:primary-signature --verbose=2 "$(DMG)" || true
	@xcrun stapler validate "$(DMG)"
	@echo
	@echo "Ready to distribute: $(DMG)"

## The whole thing: signed app, notarized, stapled, as both a zip and a DMG.
dist: release dmg

# ---------------------------------------------------------------------------
# Test fixtures
#
# Vigil's whole job is finding and killing stray assertions, which is awkward
# to test if nothing is holding one. These targets manufacture the two cases
# that matter.
# ---------------------------------------------------------------------------

## Print the command for a well-behaved assertion. This one has to be pasted
## into an interactive shell rather than run from make: make's recipe shell
## exits as soon as the recipe finishes, which reparents any background job to
## launchd — so running it here would produce a second orphan, not a contrast.
demo-assertion:
	@echo "Paste this into your shell (parent stays alive, so it won't read as orphaned):"
	@echo
	@echo "    caffeinate -d -t 600 &"
	@echo
	@echo "Expect: killable, 'expires in 10m', ancestry ending at Terminal."

## A stray assertion: no parent, no timeout. This is the shape of the one that
## kept a machine awake for fourteen hours.
##
## The obvious `nohup caffeinate -d & disown` does NOT work: disown only drops
## the job from the shell's table, and the parent stays alive, so the process
## never reparents and never gets flagged. A short-lived intermediate shell
## does the job — it exits the instant it has spawned the child, and the kernel
## hands the orphan to launchd.
demo-orphan:
	@zsh -c 'caffeinate -d >/dev/null 2>&1 &' & \
	sleep 1; \
	echo "Started an orphaned caffeinate -d. Check Vigil for the orange tag."
	@pgrep -lx caffeinate || true

## The manual equivalents, for comparison
assertions:
	@pmset -g assertions

kill-all:
	@pkill -x caffeinate 2>/dev/null && echo "Killed all caffeinate processes" || echo "None running"
