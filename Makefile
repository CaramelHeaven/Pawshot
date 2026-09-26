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
.PHONY: help generate build test lint format icon install dist uninstall run clean

help: ## List every target
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

generate: ## Generate the Xcode project (without opening it)
	$(MISE) tuist generate --no-open

build: generate ## Debug build from the CLI
	$(MISE) tuist xcodebuild build -scheme $(SCHEME) -workspace $(WORKSPACE) \
		-destination "$(DESTINATION)"

# English, whatever language the app was switched to: the test host is the app itself.
test: generate ## Run PawshotTests
	$(MISE) tuist xcodebuild test -scheme $(TEST_SCHEME) -workspace $(WORKSPACE) \
		-destination "$(DESTINATION)" -testLanguage en

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
