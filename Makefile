# ScreenStay Makefile

APP_NAME = ScreenStay
BUNDLE_ID = com.simonetti.ScreenStay
VERSION = 1.0.1
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
APP_BINARY = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)

SWIFTC = swiftc
SWIFT_FLAGS = -framework AppKit -framework ApplicationServices
SOURCES = $(shell find ScreenStay -name "*.swift")
ENTITLEMENTS = ScreenStay/ScreenStay.entitlements

# Ad-hoc by default so a clean checkout builds and runs with no certificate and
# no developer account. "-" is codesign's ad-hoc identity.
#
# Override this in Makefile.local (gitignored) to sign with a real certificate.
# Do not put a personal signing identity in this file: it is committed.
SIGNING_IDENTITY = -

.PHONY: all build clean run install sign check-signature

all: build

build: $(APP_BINARY)

# Depend on the executable, not on the .app directory. A directory's mtime only
# tracks its immediate children, so rewriting Contents/MacOS/ScreenStay leaves
# the bundle looking up to date and make skips the rebuild.
$(APP_BINARY): $(SOURCES)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@$(MAKE) --no-print-directory info-plist
	@$(SWIFTC) -o $(APP_BINARY) $(SWIFT_FLAGS) $(SOURCES)

sign: $(APP_BINARY)
	@codesign --force --sign "$(SIGNING_IDENTITY)" --identifier $(BUNDLE_ID) --entitlements $(ENTITLEMENTS) --options runtime $(APP_BUNDLE)

# Check the bundle carries an identity macOS can hang permissions off.
#
# swiftc leaves its output linker-signed under the executable's name rather than
# the bundle ID, which TCC sees as a different app from the one in your
# Accessibility list. `make sign` replaces that with a proper signature, ad-hoc
# or otherwise, carrying --identifier $(BUNDLE_ID).
check-signature:
	@codesign --verify --strict $(APP_BUNDLE) 2>/dev/null || { \
		echo "ERROR: $(APP_BUNDLE) has a missing or invalid signature."; \
		echo "       Run 'make sign' first."; \
		exit 1; \
	}
	@if ! codesign -d --verbose=1 $(APP_BUNDLE) 2>&1 | grep -q "Identifier=$(BUNDLE_ID)"; then \
		echo "ERROR: signing identifier is not $(BUNDLE_ID)."; \
		echo "       macOS treats this as a different app, so it will not match"; \
		echo "       the ScreenStay entry already in your Accessibility list."; \
		echo "       Run 'make sign' first."; \
		exit 1; \
	fi
	@if codesign -dvv $(APP_BUNDLE) 2>&1 | grep -q "Signature=adhoc"; then \
		echo "NOTE: ad-hoc signed. macOS keys Accessibility permission to the"; \
		echo "      exact binary, so you must re-grant it after every rebuild."; \
		echo "      Sign with a real certificate to keep the grant across builds;"; \
		echo "      see 'Custom Build Configuration' in the README."; \
	fi

info-plist:
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n' > $(APP_BUNDLE)/Contents/Info.plist
	@printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '<plist version="1.0">\n<dict>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>CFBundleDevelopmentRegion</key>\n    <string>en</string>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>CFBundleExecutable</key>\n    <string>%s</string>\n' "$(APP_NAME)" >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>CFBundleIdentifier</key>\n    <string>%s</string>\n' "$(BUNDLE_ID)" >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>CFBundleInfoDictionaryVersion</key>\n    <string>6.0</string>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>CFBundleName</key>\n    <string>%s</string>\n' "$(APP_NAME)" >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>CFBundlePackageType</key>\n    <string>APPL</string>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>CFBundleShortVersionString</key>\n    <string>%s</string>\n' "$(VERSION)" >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>CFBundleVersion</key>\n    <string>1</string>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>LSMinimumSystemVersion</key>\n    <string>15.0</string>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>LSUIElement</key>\n    <true/>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>NSHumanReadableCopyright</key>\n    <string>MIT Licensed</string>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '    <key>NSPrincipalClass</key>\n    <string>NSApplication</string>\n' >> $(APP_BUNDLE)/Contents/Info.plist
	@printf '</dict>\n</plist>\n' >> $(APP_BUNDLE)/Contents/Info.plist

clean:
	@rm -rf $(BUILD_DIR)

run: build
	@open $(APP_BUNDLE)

install: build check-signature
	@rm -rf ~/Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) ~/Applications/
