# The single entry point into the project. Everything goes through `mise exec --`, otherwise the
# global tuist 4.7.0 gets picked up, and this project's manifests don't work under it.

MISE ?= mise exec --
WORKSPACE := Pawshot.xcworkspace
SCHEME := Pawshot
TEST_SCHEME := Pawshot-Workspace
DESTINATION := platform=macOS,arch=arm64
DERIVED := build/derived
RELEASE_APP := $(DERIVED)/Build/Products/Release/Pawshot.app
INSTALL_PATH := /Applications/Pawshot.app
ICON_SET := Pawshot/Resources

.DEFAULT_GOAL := help
.PHONY: help generate build test test-ui lint format icon install dist release publish uninstall run clean

help: ## List every target
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

generate: ## Fetch Sparkle and generate the Xcode project (without opening it)
	$(MISE) tuist install
	$(MISE) tuist generate --no-open

build: generate ## Debug build from the CLI
	$(MISE) tuist xcodebuild build -scheme $(SCHEME) -workspace $(WORKSPACE) \
		-destination "$(DESTINATION)"

# Tests that put windows up, take the focus or dim the screen: they get in the way of whoever
# works at this Mac meanwhile, so `make test` leaves them to `make test-ui`.
UI_TESTS := \
	InstantOverlayTests \
	RecordingBarInOverlayTests \
	RecordingFrameViewTests \
	VideoEditorWindowControllerTests \
	VideoEditorOrderingTests \
	EditorWindowControllerTests/testShotStillFitsItsWindowAfterTheToolbarArrives \
	EditorWindowControllerTests/testShotRefitsWhenItsContentShrinksOutsideAResize \
	EditorWindowControllerTests/testUndoSentDownTheResponderChainUndoesTheLastChange \
	EditorWindowControllerTests/testWindowOpensCentredOnItsScreen \
	EditorWindowControllerTests/testHugeShotOpensScrolledToItsMiddle \
	EditorWindowControllerTests/testQuitKeyAsksBeforeThrowingAwayWork \
	WhatsNewTests/testTheWindowComesForwardByItself \
	RecordingBarTests/testButtonsCallTheActionsSetAfterTheFirstDraw \
	RecordingEngineTests/testRecordsAPlayableMovieOfARegion \
	RecordingEngineTests/testTheSourceOfARunningStreamCanMove \
	RecordingEngineTests/testATakeAt15FPSSaysSoInItsFile \
	InkPanelCaptureTests

# English, whatever language the app was switched to: the test host is the app itself.
TEST_RUN = $(MISE) tuist xcodebuild test -scheme $(TEST_SCHEME) -workspace $(WORKSPACE) \
	-destination "$(DESTINATION)" -testLanguage en

test: generate ## Run PawshotTests, except the ones that take the screen or the focus
	$(TEST_RUN) $(addprefix -skip-testing:PawshotTests/,$(UI_TESTS))

test-ui: generate ## Run every test, windows and overlays included (the Mac is busy meanwhile)
	$(TEST_RUN)

lint: ## Check formatting without changing anything
	$(MISE) swiftformat --lint Pawshot/Sources Tests Tools

format: ## Format the sources
	$(MISE) swiftformat Pawshot/Sources Tests Tools

icon: ## Redraw the app icon
	swift Tools/GenerateAppIcon.swift $(ICON_SET)

install: generate ## Release build and install into /Applications
	$(MISE) tuist xcodebuild build -scheme $(SCHEME) -workspace $(WORKSPACE) \
		-destination "$(DESTINATION)" -configuration Release -derivedDataPath $(DERIVED)
	@# A running instance holds the old bundle, and copying over it causes odd signature failures.
	@pkill -x Pawshot 2>/dev/null || true
	@rsync -a --delete "$(RELEASE_APP)/" "$(INSTALL_PATH)/"
	@echo "installed: $(INSTALL_PATH)"
	@open "$(INSTALL_PATH)"

dist: generate ## Release build packed into build/Pawshot-<version>.dmg, nothing installed
	$(MISE) tuist xcodebuild build -scheme $(SCHEME) -workspace $(WORKSPACE) \
		-destination "$(DESTINATION)" -configuration Release -derivedDataPath $(DERIVED)
	Tools/make-dmg.sh "$(RELEASE_APP)"

# Sparkle's tools come with the package; where SwiftPM unpacks them has moved before, so look.
# `=` and not `:=`: both are read when a recipe runs, after the build they depend on.
SPARKLE_BIN = $(dir $(firstword $(shell find Tuist/.build -type f -path '*/Sparkle/bin/generate_appcast')))
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$(RELEASE_APP)/Contents/Info.plist")
RELEASE_DIR := build/release
REPO := CaramelHeaven/Pawshot

# The appcast lists this one DMG, signed with the private key in the login Keychain (macOS asks
# for access the first time). The feed is read from the latest release, so it goes up with it.
release: dist ## DMG + signed appcast.xml into build/release, ready for `make publish`
	@rm -rf $(RELEASE_DIR) && mkdir -p $(RELEASE_DIR)
	cp "build/Pawshot-$(VERSION).dmg" $(RELEASE_DIR)/
	"$(SPARKLE_BIN)generate_appcast" \
		--download-url-prefix "https://github.com/$(REPO)/releases/download/v$(VERSION)/" $(RELEASE_DIR)
	@echo "ready: $(RELEASE_DIR) (v$(VERSION))"

# Not a pre-release: `releases/latest` skips those, and Sparkle would never see it.
publish: ## Put build/release up on GitHub as release v<version> (gh)
	gh release create "v$(VERSION)" -R $(REPO) --title "Pawshot $(VERSION)" --generate-notes \
		"$(RELEASE_DIR)/Pawshot-$(VERSION).dmg" "$(RELEASE_DIR)/appcast.xml"

uninstall: ## Remove the app from /Applications
	@pkill -x Pawshot 2>/dev/null || true
	@rm -rf "$(INSTALL_PATH)"
	@echo "removed: $(INSTALL_PATH)"
	@echo "if launch at login was on, turn it off in System Settings → General → Login Items"

# The build of *this* workspace, asked from xcodebuild: DerivedData can hold stale Pawshot-*
# folders from older generations of the project, and picking one by name or date once launched
# an August build instead of the one just made.
run: build ## Build and launch the Debug version
	@open "$$(xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Debug \
		-showBuildSettings 2>/dev/null | awk '$$1 == "BUILT_PRODUCTS_DIR" { print $$3 }')/Pawshot.app"

clean: ## Wipe build artifacts and the generation cache
	$(MISE) tuist clean
	@rm -rf build Derived Pawshot.xcodeproj Pawshot.xcworkspace
