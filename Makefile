# Run `make help` for the targets.

SHELL := bash
.SHELLFLAGS := -euo pipefail -c

ANDROID := arm arm64 x64
TARGETS := $(ANDROID) aab linux

FLUTTER ?= flutter
ADB_SERIAL ?= $(ANDROID_SERIAL)
ADB       := adb $(if $(ADB_SERIAL),-s $(ADB_SERIAL))
DEVICE_ID := $(if $(ADB_SERIAL),--device-id=$(ADB_SERIAL))
BUNDLETOOL_VERSION := 1.18.1
BUNDLETOOL_SHA256  := 675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c
BUNDLETOOL := build/tools/bundletool-all-$(BUNDLETOOL_VERSION).jar
LINUX_ARCH := $(if $(filter aarch64 arm64,$(shell uname -m)),arm64,x64)

TRACK       ?= internal
PLAY_STATUS ?= completed

# This machine exports a deprecated ANDROID_SDK_HOME that AGP rejects.
unexport ANDROID_SDK_HOME
export ANDROID_USER_HOME ?= $(HOME)/.android-user

abi_arm   := armeabi-v7a
abi_arm64 := arm64-v8a
abi_x64   := x86_64

PACKAGE  := com.aukmind.tincan
OUTPUTS  := build/app/outputs
AAB      := $(OUTPUTS)/bundle/release/app-release.aab
APKS     := $(OUTPUTS)/bundle/release/app-release.apks
LAUNCH   := $(ADB) shell am start -n $(PACKAGE)/.MainActivity
PLAY_API := https://androidpublisher.googleapis.com

.PHONY: help deps bridge_android release publish store keystore install_linux uninstall_linux \
	$(TARGETS) $(TARGETS:%=run_%)

help:
	@echo "make <target>                target: $(TARGETS) (x64 is x86_64)"
	@echo "make run_<target>            build, install with adb and launch (Linux: run the bundle)"
	@echo "make publish PLAY_KEY=<key.json> [TRACK=internal] [PLAY_STATUS=completed|draft]"
	@echo "                             upload the next version code to Google Play"
	@echo "make store                   Play Store images in tool/store/build/listing/"
	@echo "make keystore                create the Play upload key and its android/key.properties (once)"
	@echo "make release VERSION=x.y.z [DRY_RUN=1]"
	@echo "                             build the aab, bump, changelog, tag vx.y.z, push, GitHub release"
	@echo "make install_linux           build and install Tincan for this user"
	@echo "make uninstall_linux         remove it again"
	@echo "make deps                    flutter pub get"
	@echo "ADB_SERIAL=<serial> (default \$$ANDROID_SERIAL) selects the device"

deps:
	$(FLUTTER) pub get

# jniLibs are gitignored, so every Android build cross-compiles the bridge first.
bridge_android:
	gobridge/build-android.sh

$(BUNDLETOOL):
	mkdir -p $(dir $@)
	curl -fL -o $@.tmp https://github.com/google/bundletool/releases/download/$(BUNDLETOOL_VERSION)/bundletool-all-$(BUNDLETOOL_VERSION).jar
	echo "$(BUNDLETOOL_SHA256)  $@.tmp" | sha256sum -c -
	mv $@.tmp $@

define android_rules
$(1): bridge_android
	$$(FLUTTER) build apk --release --split-per-abi --target-platform android-$(1)

run_$(1): $(1)
	$$(ADB) install -r $$(OUTPUTS)/flutter-apk/app-$(abi_$(1))-release.apk
	$$(LAUNCH)
endef

$(foreach t,$(ANDROID),$(eval $(call android_rules,$(t))))

aab: bridge_android
	$(FLUTTER) build appbundle --release

# Sign like Gradle does: key.properties when present, else the debug key.
run_aab: aab $(BUNDLETOOL)
	@props=android/key.properties; ks=(); \
	if [ -f "$$props" ]; then \
	  p() { sed -n "s/^[[:space:]]*$$1[[:space:]]*[=:][[:space:]]*//p" "$$props" | tr -d '\r'; }; \
	  store=$$(p storeFile); case $$store in /*) ;; *) store=android/$$store ;; esac; \
	  ks=(--ks="$$store" --ks-key-alias="$$(p keyAlias)" --ks-pass="pass:$$(p storePassword)" --key-pass="pass:$$(p keyPassword)"); \
	fi; \
	echo "bundletool build-apks $(AAB)"; \
	java -jar $(BUNDLETOOL) build-apks --overwrite --connected-device $(DEVICE_ID) "$${ks[@]}" \
		--bundle=$(AAB) --output=$(APKS)
	java -jar $(BUNDLETOOL) install-apks $(DEVICE_ID) --apks=$(APKS)
	$(LAUNCH)

linux:
	$(FLUTTER) build linux --release

run_linux: linux
	build/linux/$(LINUX_ARCH)/release/bundle/tincan

# Any failed step stops before the commit, so Play is left unchanged.
publish: bridge_android
	@test -n "$(PLAY_KEY)" || { echo "Set PLAY_KEY to the service account's JSON key" >&2; exit 1; }
	@api=$(PLAY_API)/androidpublisher/v3/applications/$(PACKAGE); \
	token=$$(python3 -c "import os,sys,google.auth.transport.requests as r;from google.oauth2 import service_account as s;c=s.Credentials.from_service_account_file(os.path.expanduser(sys.argv[1]),scopes=['https://www.googleapis.com/auth/androidpublisher']);c.refresh(r.Request());print(c.token)" "$(PLAY_KEY)"); \
	h="Authorization: Bearer $$token"; \
	edit=$$(curl -fsS -X POST -H "$$h" "$$api/edits" | jq -er .id); \
	last=$$(curl -fsS -H "$$h" "$$api/edits/$$edit/bundles" | jq -e '[.bundles[]?.versionCode] | max // 0'); \
	next=$$((last + 1)); \
	echo "tincan: version code $$next to $(TRACK) ($(PLAY_STATUS))"; \
	$(FLUTTER) build appbundle --release --build-number=$$next; \
	curl -fsS -o /dev/null -X POST -H "$$h" -H "Content-Type: application/octet-stream" \
	  --data-binary @$(AAB) \
	  "$(PLAY_API)/upload/androidpublisher/v3/applications/$(PACKAGE)/edits/$$edit/bundles?uploadType=media"; \
	curl -fsS -o /dev/null -X PUT -H "$$h" -H "Content-Type: application/json" \
	  -d "{\"releases\":[{\"versionCodes\":[\"$$next\"],\"status\":\"$(PLAY_STATUS)\"}]}" "$$api/edits/$$edit/tracks/$(TRACK)"; \
	curl -fsS -o /dev/null -X POST -H "$$h" "$$api/edits/$$edit:commit"; \
	echo "tincan: committed version code $$next"

store:
	tool/store/store.sh

KEYS ?= $(HOME)/keys

# PKCS12 keystores use one password for the store and the key.
keystore:
	@ks=$(KEYS)/tincan-upload.keystore; props=android/key.properties; \
	[[ ! -e "$$ks" ]] || { echo "$$ks already exists" >&2; exit 1; }; \
	[[ ! -e "$$props" ]] || { echo "$$props already exists" >&2; exit 1; }; \
	read -rsp "New keystore password (keep it in your password manager): " pw; echo; \
	read -rsp "Again: " pw2; echo; \
	[[ "$$pw" == "$$pw2" && $${#pw} -ge 6 ]] || { echo "passwords differ or are shorter than 6" >&2; exit 1; }; \
	mkdir -p "$(KEYS)"; export pw; \
	keytool -genkeypair -v -keystore "$$ks" -storetype PKCS12 -alias upload \
		-keyalg RSA -keysize 4096 -validity 10000 -storepass:env pw -dname "CN=Aukmind, O=Aukmind"; \
	(umask 077; printf 'storeFile=%s\nkeyAlias=upload\nstorePassword=%s\nkeyPassword=%s\n' "$$ks" "$$pw" "$$pw" > "$$props"); \
	echo "Back up $$ks and its password: Play needs this key for every update."

release:
	@test -n "$(VERSION)" || { echo "Set VERSION=x.y.z" >&2; exit 1; }
	DRY_RUN=$(DRY_RUN) tool/release.sh $(VERSION)

# Menu entry and icon; PREFIX defaults to ~/.local.
install_linux: linux
	linux/install.sh

uninstall_linux:
	linux/install.sh --uninstall
