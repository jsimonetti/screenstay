# ScreenStay Makefile

APP_NAME = ScreenStay
BUNDLE_ID = com.simonetti.ScreenStay
VERSION = 1.0.0
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app

SWIFTC = swiftc
SWIFT_FLAGS = -framework AppKit -framework ApplicationServices
SOURCES = $(shell find ScreenStay -name "*.swift")
ENTITLEMENTS = ScreenStay/ScreenStay.entitlements
SIGNING_IDENTITY = "screenstay-codesign-certificate"

.PHONY: all build clean run install sign

all: build

build: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@$(MAKE) --no-print-directory info-plist
	@$(SWIFTC) -o $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) $(SWIFT_FLAGS) $(SOURCES)

sign: $(APP_BUNDLE)
	@codesign --force --sign "$(SIGNING_IDENTITY)" --identifier $(BUNDLE_ID) --entitlements $(ENTITLEMENTS) --options runtime $(APP_BUNDLE)

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

install: build
	@rm -rf ~/Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) ~/Applications/
