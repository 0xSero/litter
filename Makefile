#!/usr/bin/make -f

SHELL := /bin/bash
.DEFAULT_GOAL := all

# Prefer rustup-managed toolchain over Homebrew Rust for cross-compilation targets.
# Also include ~/.cargo/bin for cargo-installed tools like cargo-ndk.
RUSTUP_TOOLCHAIN_BIN := $(shell rustup which cargo 2>/dev/null | xargs dirname 2>/dev/null)
CARGO_BIN := $(HOME)/.cargo/bin
ifneq ($(RUSTUP_TOOLCHAIN_BIN),)
  export PATH := $(RUSTUP_TOOLCHAIN_BIN):$(CARGO_BIN):$(PATH)
else ifneq ($(wildcard $(CARGO_BIN)),)
  export PATH := $(CARGO_BIN):$(PATH)
endif

ROOT := $(shell pwd)
STAMPS := $(ROOT)/.build-stamps
RUST_DIR := $(ROOT)/shared/rust-bridge
KITTYLITTER_DIR := $(ROOT)/services/kittylitter
ALLEYCAT_DEV_DIR ?= $(HOME)/dev/alleycat
KITTYLITTER_DEV_DIR := $(STAMPS)/kittylitter-dev
KITTYLITTER_DEV_MANIFEST := $(KITTYLITTER_DEV_DIR)/Cargo.toml
KITTYLITTER_VERSION := $(shell awk -F'"' '/^version = / { print $$2; exit }' $(KITTYLITTER_DIR)/Cargo.toml)
SUBMODULE_DIR := $(ROOT)/shared/third_party/codex
IOS_DIR := $(ROOT)/apps/ios
IOS_SCRIPTS := $(IOS_DIR)/scripts
IOS_FW_DIR := $(IOS_DIR)/Frameworks
IOS_GENERATED := $(IOS_DIR)/GeneratedRust
IOS_SOURCES := $(IOS_DIR)/Sources
IOS_RUN_ARTIFACTS_DIR ?= $(ROOT)/artifacts/ios-device-run
IOS_DEVICE_PROFILE ?= 0
IOS_DEVICE_PROFILE_TEMPLATE ?= Time Profiler
IOS_DEVICE_PROFILE_TIME_LIMIT ?=
IOS_SIM_RUN_ARTIFACTS_DIR ?= $(ROOT)/artifacts/ios-sim-run
IOS_SIM_PROFILE ?= 1
IOS_SIM_PROFILE_TEMPLATE ?= Time Profiler
IOS_SIM_PROFILE_TIME_LIMIT ?=
ANDROID_DEVICE_RUN_ARTIFACTS_DIR ?= $(ROOT)/artifacts/android-device-run
ANDROID_EMULATOR_RUN_ARTIFACTS_DIR ?= $(ROOT)/artifacts/android-emulator-run
ANDROID_DIR := $(ROOT)/apps/android
ANDROID_JNI := $(ANDROID_DIR)/core/bridge/src/main/jniLibs
ANDROID_APP_JNI := $(ANDROID_DIR)/app/src/main/jniLibs
GENERATED_DIR := $(RUST_DIR)/generated
PATCHES_DIR := $(ROOT)/patches/codex

IOS_DEPLOYMENT_TARGET ?= 18.0
IOS_SIM_DEVICE ?= iPhone 17 Pro
IOS_SCHEME ?= Litter
XCODE_CONFIG ?= Debug
CARGO_FEATURES ?=
ANDROID_ABIS ?= arm64-v8a
ANDROID_RUST_PROFILE ?= android-dev
ANDROID_RELEASE_ABIS ?= arm64-v8a
HOST_ARCH := $(shell uname -m)
ANDROID_EMULATOR_ABIS ?= $(if $(filter arm64 aarch64,$(HOST_ARCH)),arm64-v8a,x86_64)

# Source local env (credentials, SDK paths, cache settings) if present.
# This must precede cache setup and path auto-detection.
-include .env

LITTER_SHARED_CACHE_ROOT ?= $(HOME)/Library/Caches/litter-build
LITTER_SHARED_RUST_TARGET ?= 0
ifeq ($(LITTER_SHARED_RUST_TARGET),1)
  export CARGO_TARGET_DIR ?= $(LITTER_SHARED_CACHE_ROOT)/cargo-target
endif
RUST_TARGET := $(if $(CARGO_TARGET_DIR),$(CARGO_TARGET_DIR),$(RUST_DIR)/target)

AWS_SHARED_CREDENTIALS_FILE ?= $(HOME)/.aws/credentials

define aws_profile_credential
$(strip $(shell PROFILE='$(AWS_PROFILE)' CREDS_FILE='$(AWS_SHARED_CREDENTIALS_FILE)' KEY='$(1)' /bin/bash -lc '\
if [ -n "$$PROFILE" ] && [ -f "$$CREDS_FILE" ]; then \
  awk -F" *= *" -v profile="$$PROFILE" -v key="$$KEY" '\''
    $$0 == "[" profile "]" { in_profile = 1; next } \
    /^\[/ { in_profile = 0 } \
    in_profile && $$1 == key { print $$2; exit }\
  '\'' "$$CREDS_FILE"; \
fi'))
endef

# Auto-detect Android SDK/NDK/JDK paths (macOS defaults, overridable via env or .env)
ANDROID_SDK_ROOT ?= $(or $(ANDROID_HOME),$(wildcard $(HOME)/Library/Android/sdk),$(wildcard /opt/homebrew/share/android-commandlinetools))
ANDROID_NDK_HOME ?= $(shell ls -d $(ANDROID_SDK_ROOT)/ndk/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/*$$::')
JAVA_HOME ?= $(or $(shell /usr/libexec/java_home 2>/dev/null),$(shell test -d '/Applications/Android Studio.app/Contents/jbr/Contents/Home' && echo '/Applications/Android Studio.app/Contents/jbr/Contents/Home'))
ANDROID_PLATFORM_TOOLS_DIR := $(ANDROID_SDK_ROOT)/platform-tools
ANDROID_EMULATOR_DIR := $(ANDROID_SDK_ROOT)/emulator
ANDROID_ENV := JAVA_HOME='$(JAVA_HOME)' ANDROID_SDK_ROOT='$(ANDROID_SDK_ROOT)' ANDROID_NDK_HOME='$(ANDROID_NDK_HOME)'

# Android app metadata
ANDROID_APK := $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk
ANDROID_PACKAGE := com.sigkitten.litter.android
ANDROID_ACTIVITY := com.litter.android.MainActivity
ANDROID_DEVICE_SERIAL ?=
ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH ?= 1

export ANDROID_SDK_ROOT
export ANDROID_NDK_HOME
export JAVA_HOME
ifneq ($(wildcard $(ANDROID_PLATFORM_TOOLS_DIR)),)
  export PATH := $(ANDROID_PLATFORM_TOOLS_DIR):$(PATH)
endif
ifneq ($(wildcard $(ANDROID_EMULATOR_DIR)),)
  export PATH := $(ANDROID_EMULATOR_DIR):$(PATH)
endif

SCCACHE := $(shell command -v sccache 2>/dev/null)
ifneq ($(SCCACHE),)
  ifeq ($(strip $(AWS_ACCESS_KEY_ID)),)
    AWS_ACCESS_KEY_ID := $(call aws_profile_credential,aws_access_key_id)
  endif
  ifeq ($(strip $(AWS_SECRET_ACCESS_KEY)),)
    AWS_SECRET_ACCESS_KEY := $(call aws_profile_credential,aws_secret_access_key)
  endif
  ifeq ($(strip $(AWS_SESSION_TOKEN)),)
    AWS_SESSION_TOKEN := $(call aws_profile_credential,aws_session_token)
  endif
  export RUSTC_WRAPPER := $(SCCACHE)
  ifdef SCCACHE_BUCKET
    export SCCACHE_BUCKET
    export SCCACHE_ENDPOINT
    export SCCACHE_REGION
    export SCCACHE_S3_KEY_PREFIX
    ifneq ($(strip $(AWS_ACCESS_KEY_ID)),)
      export AWS_ACCESS_KEY_ID
    endif
    ifneq ($(strip $(AWS_SECRET_ACCESS_KEY)),)
      export AWS_SECRET_ACCESS_KEY
    endif
    ifneq ($(strip $(AWS_SESSION_TOKEN)),)
      export AWS_SESSION_TOKEN
    endif
    $(info [cache] Using sccache: $(SCCACHE) → s3://$(SCCACHE_BUCKET))
  else
    $(info [cache] Using sccache: $(SCCACHE) (local only))
  endif
endif

PACKAGE_CARGO_ENV := CARGO_INCREMENTAL=0

# Local dev iteration: enable incremental compilation and disable sccache.
# sccache caches by source hash so it misses on every edit, and it rejects
# CARGO_INCREMENTAL=1. Incremental wins for small-change rebuilds. CI calls
# build-rust.sh directly with its own env, so it bypasses this var.
DEV_CARGO_ENV := env -u RUSTC_WRAPPER CARGO_INCREMENTAL=1
# The generated KittyLitter development manifest otherwise gets its own
# `.build-stamps/kittylitter-dev/target` tree.  Point it at the normal Rust
# target so host dependencies are compiled once and Cargo can reuse them.
KITTYLITTER_CARGO_ENV := $(DEV_CARGO_ENV) CARGO_TARGET_DIR="$(RUST_TARGET)"
ifeq ($(firstword $(MAKECMDGOALS)),kittylitter)
  KITTYLITTER_GOAL_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  .PHONY: $(KITTYLITTER_GOAL_ARGS)
  $(KITTYLITTER_GOAL_ARGS):
	@:
endif
KITTYLITTER_ARGS := $(strip $(KITTYLITTER_GOAL_ARGS) $(ARGS))
UPDATE_ALLEYCAT_MAIN := $(ROOT)/tools/scripts/update-alleycat-main.sh

PATCH_FILES := \
	$(PATCHES_DIR)/ios-exec-hook.patch \
	$(PATCHES_DIR)/client-controlled-handoff.patch \
	$(PATCHES_DIR)/mobile-code-mode-stub.patch \
	$(PATCHES_DIR)/thread-read-permissions.patch

BOUNDARY_SOURCES := \
	$(RUST_DIR)/codex-mobile-client/Cargo.toml \
	$(RUST_DIR)/codex-mobile-client/src/lib.rs \
	$(RUST_DIR)/codex-mobile-client/src/conversation_uniffi.rs \
	$(RUST_DIR)/codex-mobile-client/src/discovery_uniffi.rs

BOUNDARY_SOURCES += $(shell find $(RUST_DIR)/codex-mobile-client/src -type f -name '*.rs' 2>/dev/null)

STAMP_SYNC := $(STAMPS)/sync
STAMP_BINDINGS_S := $(STAMPS)/bindings-swift
STAMP_BINDINGS_K := $(STAMPS)/bindings-kotlin
STAMP_XCGEN := $(STAMPS)/xcgen

# Pinned release tag of the prebuilt Alpine rootfs tarball (still hosted
# on the dnakov/litter-ish releases page). The iSH kernel itself is built
# from the `ish` Rust crate. Bump and re-run `make alpine-fs` to upgrade.
ALPINE_FS_VERSION := v0.1.2
STAMP_ALPINE_FS := $(STAMPS)/alpine-fs-$(ALPINE_FS_VERSION)
STAMP_ANDROID_ALPINE_FS := $(STAMPS)/android-alpine-fs-$(ALPINE_FS_VERSION)
PROOT_COMMIT := ee10b279a38d34b6704345bc448d18f019ca1b49
TALLOC_VERSION := 2.4.3
STAMP_PROOT_ANDROID = $(STAMPS)/proot-android-$(PROOT_COMMIT)-talloc-$(TALLOC_VERSION)-$(ANDROID_ABIS_SAFE)
GHOSTTY_DIR := $(ROOT)/shared/third_party/ghostty
GHOSTTY_COMMIT := $(shell git -C $(GHOSTTY_DIR) rev-parse --short=12 HEAD 2>/dev/null || echo missing)
GHOSTTY_PATCH_FILES := $(wildcard $(ROOT)/patches/ghostty/*.patch)
GHOSTTY_PATCH_FINGERPRINT := $(shell cat $(GHOSTTY_PATCH_FILES) 2>/dev/null | shasum -a 256 | cut -c1-12)
STAMP_SYNC_GHOSTTY := $(STAMPS)/sync-ghostty-$(GHOSTTY_COMMIT)-$(GHOSTTY_PATCH_FINGERPRINT)
STAMP_GHOSTTY_IOS := $(STAMPS)/ghostty-ios-$(GHOSTTY_COMMIT)-$(GHOSTTY_PATCH_FINGERPRINT)

empty :=
space := $(empty) $(empty)
ANDROID_ABIS_SAFE := $(subst $(space),_,$(subst /,_,$(ANDROID_ABIS)))
ANDROID_RUST_PROFILE_SAFE := $(subst /,_,$(ANDROID_RUST_PROFILE))
STAMP_GHOSTTY_ANDROID := $(STAMPS)/ghostty-android-$(GHOSTTY_COMMIT)-$(GHOSTTY_PATCH_FINGERPRINT)-$(ANDROID_ABIS_SAFE)
STAMP_RUST_ANDROID := $(STAMPS)/rust-android-$(ANDROID_RUST_PROFILE_SAFE)-$(ANDROID_ABIS_SAFE)
ANDROID_RUST_SOURCES := $(shell find $(RUST_DIR) \
	-path '*/target' -prune -o \
	-path '*/generated' -prune -o \
	-type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' -o -name 'build.rs' \) -print 2>/dev/null)

$(shell mkdir -p $(STAMPS))

.PHONY: all ios ios-sim ios-sim-fast ios-sim-run ios-device ios-device-fast ios-device-run ios-device-stop ios-run verify-ios-project catalyst catalyst-run catalyst-fast catalyst-fast-run mac-direct mac-direct-run mac-direct-fast mac-direct-fast-run \
	android android-fast android-tools android-emulator-fast android-emulator-run android-device-run android-release android-debug android-install android-emulator-install \
	rust-ios rust-ios-package rust-ios-device-release rust-mac-release rust-ios-device-fast rust-ios-sim-fast rust-ios-macabi-fast rust-android rust-check rust-test rust-host-dev \
	android-alpine-fs proot-android \
	ghostty-ios ghostty-android \
	alleycat-main \
	bindings bindings-swift bindings-kotlin \
	sync patch unpatch sync-ghostty unpatch-ghostty xcgen alpine-fs \
	ios-build ios-build-sim ios-build-sim-fast ios-build-device ios-build-device-fast \
	watch watch-sim watch-sim-run watch-device watch-typecheck watch-register \
	test test-rust test-ios test-android \
	ios-release-prep mac-release-prep testflight mac-testflight mac-direct-dist appstore-release play-upload play-release \
	clean clean-rust clean-ios clean-android prune-dev-cache prune-ios-sim-only \
	rebuild-bindings kittylitter kittylitter-restart tui tui-run help

all: ios android

# ios-build-* targets declare their real prerequisites so that `make -j`
# can run rust-ios-package, alpine-fs download, and xcgen in parallel.
ios-build-sim: rust-ios-package alpine-fs xcgen
ios-build-device: rust-ios-package alpine-fs xcgen

# Fast lanes use lightweight raw staticlib outputs instead of full packaging.
ios-build-sim-fast: rust-ios-sim-fast alpine-fs xcgen
ios-build-device-fast: rust-ios-device-fast alpine-fs xcgen

ios: ios-build-sim
ios-sim: ios-build-sim
ios-sim-fast: ios-build-sim-fast
ios-device: ios-build-device
ios-device-fast: ios-build-device-fast

# Mac Catalyst build. Uses the same rust-ios-package (macabi arches)
# + xcgen chain, but targets the `LitterMac` scheme and writes into a
# separate DerivedData path so it doesn't collide with the iOS sim build
# cache.
CATALYST_DERIVED_DATA := $(IOS_DIR)/build/catalyst
catalyst: rust-ios-package alpine-fs xcgen
	@echo "==> Building LitterMac for Mac Catalyst..."
	@cd $(IOS_DIR) && xcodebuild \
		-project Litter.xcodeproj \
		-scheme LitterMac \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=macOS,variant=Mac Catalyst' \
		-derivedDataPath $(CATALYST_DERIVED_DATA) \
		build \
		| tail -6

# Build + (kill any running copy) + launch the freshly-built Catalyst app.
catalyst-run: catalyst
	@echo "==> Launching Catalyst app..."
	@pkill -9 -f "Debug-maccatalyst/Litter.app" 2>/dev/null; true
	@open $(CATALYST_DERIVED_DATA)/Build/Products/Debug-maccatalyst/Litter.app

# Fast Mac Catalyst dev lane. Mirrors `ios-sim-fast` for Catalyst:
# host-arch-only macabi staticlib via the `ios-dev` Cargo profile (no
# LTO, codegen-units=256, line-table debuginfo) instead of the full
# release+LTO+xcframework `rust-ios-package` chain. Warm rebuilds drop
# from minutes to seconds. Cold first build is still slow because cargo
# has to compile the codex workspace once for macabi.
catalyst-fast: rust-ios-macabi-fast alpine-fs xcgen
	@echo "==> Building LitterMac for Mac Catalyst (fast)..."
	@cd $(IOS_DIR) && xcodebuild \
		-project Litter.xcodeproj \
		-scheme LitterMac \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=macOS,variant=Mac Catalyst' \
		-derivedDataPath $(CATALYST_DERIVED_DATA) \
		build \
		| tail -6

catalyst-fast-run: catalyst-fast
	@echo "==> Launching Catalyst app..."
	@pkill -9 -f "Debug-maccatalyst/Litter.app" 2>/dev/null; true
	@open $(CATALYST_DERIVED_DATA)/Build/Products/Debug-maccatalyst/Litter.app

# Direct (unsandboxed) Mac Catalyst build — same binary the DMG
# distribution lane ships, but built with `DeveloperID` configuration
# and launched in-place so you can iterate without the archive →
# export → hdiutil → notarize → staple cycle. Use `make mac-direct-dist`
# for the signed + notarized DMG.
MAC_DIRECT_DERIVED := $(IOS_DIR)/build/mac-direct
mac-direct: rust-ios-package alpine-fs xcgen
	@echo "==> Building LitterMac (DeveloperID — unsandboxed)..."
	@cd $(IOS_DIR) && xcodebuild \
		-project Litter.xcodeproj \
		-scheme LitterMac \
		-configuration DeveloperID \
		-destination 'platform=macOS,variant=Mac Catalyst' \
		-derivedDataPath $(MAC_DIRECT_DERIVED) \
		build \
		| tail -6

mac-direct-run: mac-direct
	@echo "==> Launching unsandboxed Mac Catalyst app..."
	@pkill -9 -f "DeveloperID-maccatalyst/Litter.app" 2>/dev/null; true
	@open $(MAC_DIRECT_DERIVED)/Build/Products/DeveloperID-maccatalyst/Litter.app

# Fast unsandboxed Catalyst lane. Same DeveloperID config as `mac-direct`
# (so MacPairingHost / local Codex / BLE advertiser are all live), but uses
# the fast macabi-only Rust path so warm rebuilds are seconds. Uses ad-hoc
# code signing (`CODE_SIGN_IDENTITY=-`) to bypass the Developer ID cert
# requirement during local iteration.
mac-direct-fast: rust-ios-macabi-fast alpine-fs xcgen
	@echo "==> Building LitterMac (DeveloperID — unsandboxed, fast)..."
	@cd $(IOS_DIR) && xcodebuild \
		-project Litter.xcodeproj \
		-scheme LitterMac \
		-configuration DeveloperID \
		-destination 'platform=macOS,variant=Mac Catalyst' \
		-derivedDataPath $(MAC_DIRECT_DERIVED) \
		ARCHS=arm64 \
		ONLY_ACTIVE_ARCH=YES \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build \
		| tail -6

mac-direct-fast-run: mac-direct-fast
	@echo "==> Launching unsandboxed Mac Catalyst app..."
	@pkill -9 -f "DeveloperID-maccatalyst/Litter.app" 2>/dev/null; true
	@/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f $(MAC_DIRECT_DERIVED)/Build/Products/DeveloperID-maccatalyst/Litter.app
	@open $(MAC_DIRECT_DERIVED)/Build/Products/DeveloperID-maccatalyst/Litter.app
loop-sim:
	@$(ROOT)/tools/scripts/loop-ios.sh sim

loop-sim-run:
	@$(ROOT)/tools/scripts/loop-ios.sh sim-run

loop-device:
	@$(ROOT)/tools/scripts/loop-ios.sh device

loop-device-run:
	@$(ROOT)/tools/scripts/loop-ios.sh device-run

ios-sim-run: ios-sim-fast
	@echo "==> Installing and launching on booted simulator with saved logs/profile..."
	@cd $(ROOT) && \
	IOS_SIM_PROFILE='$(IOS_SIM_PROFILE)' \
	IOS_SIM_PROFILE_TEMPLATE='$(IOS_SIM_PROFILE_TEMPLATE)' \
	IOS_SIM_PROFILE_TIME_LIMIT='$(IOS_SIM_PROFILE_TIME_LIMIT)' \
	IOS_SIM_RUN_ARTIFACTS_DIR='$(IOS_SIM_RUN_ARTIFACTS_DIR)' \
	$(IOS_SCRIPTS)/run-sim.sh

ios-device-run: ios-device-fast
	@echo "==> Installing and launching on connected device with saved logs/profile..."
	@cd $(ROOT) && \
	IOS_DEVICE_PROFILE='$(IOS_DEVICE_PROFILE)' \
	IOS_DEVICE_PROFILE_TEMPLATE='$(IOS_DEVICE_PROFILE_TEMPLATE)' \
	IOS_DEVICE_PROFILE_TIME_LIMIT='$(IOS_DEVICE_PROFILE_TIME_LIMIT)' \
	IOS_DEVICE_PROFILE_LAUNCH='$(IOS_DEVICE_PROFILE_LAUNCH)' \
	IOS_DEVICE_PROFILE_DETACH='$(IOS_DEVICE_PROFILE_DETACH)' \
	IOS_RUN_ARTIFACTS_DIR='$(IOS_RUN_ARTIFACTS_DIR)' \
	$(IOS_SCRIPTS)/run-device.sh

# Gracefully stop the most-recent detached xctrace recording. Sends
# SIGINT (the same signal Ctrl+C would send) so xctrace finalizes the
# .trace file instead of truncating it. Use after `make ios-device-run`
# with `IOS_DEVICE_PROFILE_DETACH=1`.
ios-device-stop:
	@latest_pid_file=$$(ls -1t $(IOS_RUN_ARTIFACTS_DIR)/*/profile.pid 2>/dev/null | head -1); \
	if [[ -z "$$latest_pid_file" ]]; then \
		echo "==> No detached xctrace run found under $(IOS_RUN_ARTIFACTS_DIR)"; \
		exit 1; \
	fi; \
	pid=$$(cat "$$latest_pid_file"); \
	run_dir=$$(dirname "$$latest_pid_file"); \
	if ! kill -0 "$$pid" 2>/dev/null; then \
		echo "==> No xctrace process at pid $$pid (stale pid file: $$latest_pid_file)"; \
		exit 1; \
	fi; \
	echo "==> Stopping xctrace pid $$pid and finalizing trace..."; \
	kill -INT "$$pid"; \
	while kill -0 "$$pid" 2>/dev/null; do sleep 0.5; done; \
	echo "==> Finalized: $$run_dir/profile.trace"

ios-run: ios
	@open $(IOS_DIR)/Litter.xcodeproj

android: android-fast
android-fast: rust-android android-tools android-alpine-fs proot-android android-debug
android-tools:
	@echo "==> Downloading bundled Android CLI tools..."
	@$(ROOT)/tools/scripts/download-android-tools.sh
android-emulator-fast:
	@$(MAKE) android-fast ANDROID_ABIS="$(ANDROID_EMULATOR_ABIS)"
android-emulator-run: android-emulator-fast
	@echo "==> Installing and launching on emulator with saved logcat..."
	@cd $(ROOT) && \
	ANDROID_RUN_MODE=emulator \
	ANDROID_RUN_ARTIFACTS_DIR='$(ANDROID_EMULATOR_RUN_ARTIFACTS_DIR)' \
	ANDROID_APK='$(ANDROID_APK)' \
	ANDROID_PACKAGE='$(ANDROID_PACKAGE)' \
	ANDROID_ACTIVITY='$(ANDROID_ACTIVITY)' \
	ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH='$(ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH)' \
	./tools/scripts/run-android.sh
android-device-run: android-fast
	@echo "==> Installing and launching on connected device with saved logcat..."
	@cd $(ROOT) && \
	ANDROID_RUN_MODE=device \
	ANDROID_RUN_ARTIFACTS_DIR='$(ANDROID_DEVICE_RUN_ARTIFACTS_DIR)' \
	ANDROID_APK='$(ANDROID_APK)' \
	ANDROID_PACKAGE='$(ANDROID_PACKAGE)' \
	ANDROID_ACTIVITY='$(ANDROID_ACTIVITY)' \
	ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH='$(ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH)' \
	./tools/scripts/run-android.sh

android-release: android-tools android-alpine-fs proot-android
	@$(MAKE) rust-android ANDROID_RUST_PROFILE=release ANDROID_ABIS="$(ANDROID_RELEASE_ABIS)"
	@echo "==> Building Android release..."
	@cd $(ANDROID_DIR) && $(ANDROID_ENV) ANDROID_ABIS="$(ANDROID_RELEASE_ABIS)" ./gradlew :app:assembleRelease

rust-ios: rust-ios-package

alleycat-main:
	@$(UPDATE_ALLEYCAT_MAIN) --all

rust-ios-package: alleycat-main $(STAMP_SYNC) $(STAMP_GHOSTTY_IOS)
	@echo "==> Packaging Rust for iOS (device + simulator + xcframework)..."
	@cd $(ROOT) && $(PACKAGE_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current $(CARGO_FEATURES)

rust-ios-device-release: alleycat-main $(STAMP_SYNC) $(STAMP_GHOSTTY_IOS)
	@echo "==> Building Rust for iOS release archive prep (device staticlib + headers)..."
	@cd $(ROOT) && $(PACKAGE_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --device-only $(CARGO_FEATURES)

rust-mac-release: alleycat-main $(STAMP_SYNC) $(STAMP_GHOSTTY_IOS)
	@echo "==> Building Rust for Mac Catalyst release archive prep (macabi staticlib + headers)..."
	@cd $(ROOT) && $(PACKAGE_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --macabi-only $(CARGO_FEATURES)

rust-ios-device-fast: alleycat-main $(STAMP_SYNC) $(STAMP_GHOSTTY_IOS)
	@echo "==> Building Rust for fast iOS device iteration (raw staticlib + headers)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --fast-device $(CARGO_FEATURES)

rust-ios-sim-fast: alleycat-main $(STAMP_SYNC) $(STAMP_GHOSTTY_IOS)
	@echo "==> Building Rust for fast iOS simulator iteration (raw staticlib + headers)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --fast-sim $(CARGO_FEATURES)

rust-ios-macabi-fast: alleycat-main $(STAMP_SYNC) $(STAMP_GHOSTTY_IOS)
	@echo "==> Building Rust for fast Mac Catalyst iteration (raw macabi staticlib + headers, host arch only)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --fast-macabi $(CARGO_FEATURES)

rust-check: alleycat-main
	@echo "==> cargo check (host, shared crates)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo check --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client

rust-test: alleycat-main rust-shellcheck
	@echo "==> cargo test (host, shared crates)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo test --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client --lib

# Lint the embedded SSH bootstrap shell scripts. shellcheck and pwsh are
# best-effort: missing tools warn but don't fail the build (matches the
# fresh-checkout reality where contributors may not have either installed).
SSH_SCRIPT_DIR := $(RUST_DIR)/codex-mobile-client/src/ssh_scripts
rust-shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "==> shellcheck $(SSH_SCRIPT_DIR)/posix/*.sh"; \
	  shellcheck --shell=sh --severity=warning $(SSH_SCRIPT_DIR)/posix/*.sh || exit 1; \
	else \
	  echo "==> shellcheck not installed, skipping (brew install shellcheck)"; \
	fi
	@echo "==> bash -n on $(SSH_SCRIPT_DIR)/posix/*.sh"
	@for f in $(SSH_SCRIPT_DIR)/posix/*.sh; do bash -n "$$f" || exit 1; done
	@if command -v pwsh >/dev/null 2>&1; then \
	  echo "==> pwsh syntax check on $(SSH_SCRIPT_DIR)/powershell/*.ps1"; \
	  for f in $(SSH_SCRIPT_DIR)/powershell/*.ps1; do \
	    pwsh -NoProfile -Command "[void][scriptblock]::Create((Get-Content -Raw '$$f'))" || exit 1; \
	  done; \
	else \
	  echo "==> pwsh not installed, skipping ps1 check"; \
	fi

rust-host-dev: rust-check rust-test

rust-android: $(STAMP_RUST_ANDROID)
$(STAMP_RUST_ANDROID): $(STAMP_SYNC) $(STAMP_BINDINGS_K) $(STAMP_GHOSTTY_ANDROID) $(ANDROID_RUST_SOURCES) tools/scripts/build-android-rust.sh Makefile | alleycat-main
	@echo "==> Building Rust for Android..."
	@cd $(ROOT) && $(ANDROID_ENV) ANDROID_ABIS="$(ANDROID_ABIS)" ANDROID_RUST_PROFILE="$(ANDROID_RUST_PROFILE)" $(DEV_CARGO_ENV) ./tools/scripts/build-android-rust.sh
	@touch $@

sync-ghostty: $(STAMP_SYNC_GHOSTTY)
$(STAMP_SYNC_GHOSTTY): $(GHOSTTY_PATCH_FILES) apps/ios/scripts/sync-ghostty.sh Makefile
	@echo "==> Syncing ghostty submodule + applying Litter patches..."
	@$(IOS_SCRIPTS)/sync-ghostty.sh --preserve-current
	@touch $@

ghostty-ios: $(STAMP_GHOSTTY_IOS)
$(STAMP_GHOSTTY_IOS): $(STAMP_SYNC_GHOSTTY) shared/third_party/ghostty/build.zig apps/ios/scripts/build-ghostty.sh Makefile
	@echo "==> Building Ghostty renderer for iOS..."
	@cd $(ROOT) && $(IOS_SCRIPTS)/build-ghostty.sh
	@touch $@

ghostty-android: $(STAMP_GHOSTTY_ANDROID)
$(STAMP_GHOSTTY_ANDROID): $(STAMP_SYNC_GHOSTTY) shared/third_party/ghostty/build.zig tools/scripts/build-ghostty-android.sh Makefile
	@echo "==> Building Ghostty renderer for Android..."
	@cd $(ROOT) && ANDROID_ABIS="$(ANDROID_ABIS)" ./tools/scripts/build-ghostty-android.sh
	@touch $@

android-alpine-fs: $(STAMP_ANDROID_ALPINE_FS)
$(STAMP_ANDROID_ALPINE_FS): apps/android/scripts/download-alpine-fs.sh Makefile
	@echo "==> Fetching Android alpine-fs $(ALPINE_FS_VERSION)..."
	@ALPINE_FS_VERSION=$(ALPINE_FS_VERSION) $(ANDROID_DIR)/scripts/download-alpine-fs.sh
	@touch $@

proot-android: $(STAMP_PROOT_ANDROID)
$(STAMP_PROOT_ANDROID): tools/scripts/build-proot-android.sh Makefile
	@echo "==> Building Android proot $(PROOT_COMMIT)..."
	@cd $(ROOT) && $(ANDROID_ENV) ANDROID_ABIS="$(ANDROID_ABIS)" PROOT_COMMIT="$(PROOT_COMMIT)" TALLOC_VERSION="$(TALLOC_VERSION)" ./tools/scripts/build-proot-android.sh
	@touch $@

help:
	@printf '%s\n' \
		'make ios                full iOS package lane + simulator build' \
		'make ios-sim-fast       fast simulator lane using raw staticlib outputs' \
		'make ios-sim-run        fast sim build + install + launch on booted simulator; saves console log and Time Profiler trace under artifacts/ios-sim-run (override IOS_SIM_PROFILE=0, IOS_SIM_PROFILE_TEMPLATE, IOS_SIM_PROFILE_TIME_LIMIT=30s to cap capture)' \
		'make ios-device         full iOS package lane + device build' \
		'make ios-device-fast    fast device lane using raw staticlib outputs' \
		'make ios-device-run     fast device build + install + launch on connected device; saves console log and Time Profiler trace for the whole run under artifacts/ios-device-run (override IOS_DEVICE_PROFILE=0, IOS_DEVICE_PROFILE_TEMPLATE, IOS_DEVICE_PROFILE_TIME_LIMIT=30s to cap capture)' \
		'make watch-register     register a newly paired Apple Watch with the developer portal (one-shot; idempotent via stamp file). Override discovery with WATCH_UDID=...' \
		'make rust-ios-package   full Rust iOS package lane (bindings + xcframework)' \
		'make rust-ios-sim-fast  fast Rust iOS simulator lane (raw staticlib only)' \
		'make rust-ios-device-fast fast Rust iOS device lane (raw staticlib only)' \
		'make rust-ios-macabi-fast fast Rust Mac Catalyst lane (host-arch macabi staticlib only)' \
		'make android-alpine-fs  download Android proot Alpine rootfs asset' \
		'make proot-android     build Android proot executable artifacts' \
		'make ghostty-ios        build pinned Ghostty iOS renderer artifacts' \
		'make ghostty-android    build pinned Ghostty Android renderer artifacts (requires Android platform patch)' \
		'make alleycat-main      refresh Alleycat git deps to latest dnakov/alleycat main' \
		'make catalyst           full Mac Catalyst build (release+LTO macabi staticlib + xcodebuild)' \
		'make catalyst-run       full Mac Catalyst build + launch' \
		'make catalyst-fast      fast Mac Catalyst dev build (ios-dev profile, host arch)' \
		'make catalyst-fast-run  fast Mac Catalyst dev build + launch' \
		'make android            fast Android dev build (default ABI/profile: arm64-v8a/android-dev)' \
		'make android-emulator-fast fast Android dev build using emulator ABI ($(ANDROID_EMULATOR_ABIS))' \
		'make android-emulator-run  fast emulator build + install + launch on emulator; saves logcat under artifacts/android-emulator-run' \
		'make android-device-run    fast Android dev build + install + launch with saved logcat under artifacts/android-device-run (override ANDROID_DEVICE_SERIAL; auto-uninstalls on versionCode downgrade; set ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH=1 to also uninstall on signature mismatch)' \
		'make android-release    Android build using release Rust profile and ARM64 output' \
		'make rust-check         host cargo check for shared crates' \
		'make rust-test          host cargo test for shared crates' \
		'make prune-dev-cache    remove rebuildable Rust incremental output and the legacy KittyLitter target tree' \
		'make prune-ios-sim-only remove device/Catalyst iOS outputs; retain the simulator staticlib and generated headers'

sync: $(STAMP_SYNC)
$(STAMP_SYNC):
	@echo "==> Syncing codex submodule..."
	@$(IOS_SCRIPTS)/sync-codex.sh --preserve-current
	@touch $@

patch: $(STAMP_SYNC)
	@echo "==> Verifying codex patch set..."
	@$(IOS_SCRIPTS)/sync-codex.sh --preserve-current

unpatch:
	@echo "==> Reverting codex patches..."
	@for pf in $(PATCH_FILES); do \
		if git -C $(SUBMODULE_DIR) apply --reverse --check "$$pf" >/dev/null 2>&1; then \
			git -C $(SUBMODULE_DIR) apply --reverse "$$pf"; \
		fi; \
	done
	@rm -f $(STAMP_SYNC)

unpatch-ghostty:
	@echo "==> Reverting ghostty patches..."
	@for pf in $(GHOSTTY_PATCH_FILES); do \
		if git -C $(GHOSTTY_DIR) apply --reverse --check "$$pf" >/dev/null 2>&1; then \
			git -C $(GHOSTTY_DIR) apply --reverse "$$pf"; \
		fi; \
	done
	@rm -f $(STAMPS)/sync-ghostty-* $(STAMPS)/ghostty-ios-* $(STAMPS)/ghostty-android-*

bindings: bindings-swift bindings-kotlin

bindings-swift: $(STAMP_BINDINGS_S)
$(STAMP_BINDINGS_S): $(STAMP_SYNC) $(BOUNDARY_SOURCES) | alleycat-main
	@echo "==> Generating Swift bindings..."
	@cd $(RUST_DIR) && ./generate-bindings.sh --swift-only
	@mkdir -p $(IOS_GENERATED)/Headers
	@cp $(GENERATED_DIR)/swift/codex_mobile_client.swift $(IOS_SOURCES)/Litter/Bridge/UniFFICodexClient.generated.swift
	@cp $(GENERATED_DIR)/swift/codex_mobile_clientFFI.h $(IOS_GENERATED)/Headers/codex_mobile_clientFFI.h
	@cp $(GENERATED_DIR)/swift/codex_mobile_clientFFI.modulemap $(IOS_GENERATED)/Headers/codex_mobile_clientFFI.modulemap
	@cp $(GENERATED_DIR)/swift/module.modulemap $(IOS_GENERATED)/Headers/module.modulemap
	@touch $@

bindings-kotlin: $(STAMP_BINDINGS_K)
$(STAMP_BINDINGS_K): $(STAMP_SYNC) $(BOUNDARY_SOURCES) | alleycat-main
	@echo "==> Generating Kotlin bindings..."
	@cd $(RUST_DIR) && ./generate-bindings.sh --kotlin-only
	@touch $@

xcgen: $(STAMP_XCGEN)
$(STAMP_XCGEN): $(IOS_DIR)/project.yml
	@echo "==> Regenerating Xcode project..."
	@$(IOS_SCRIPTS)/regenerate-project.sh
	@touch $@

# Download the pinned Alpine rootfs tarball and extract into
# apps/ios/Resources/fs. The stamp is version-keyed so bumping
# ALPINE_FS_VERSION re-runs the download. The iSH kernel itself is
# compiled from the `ish` Rust crate via cargo.
alpine-fs: $(STAMP_ALPINE_FS)
$(STAMP_ALPINE_FS):
	@echo "==> Fetching alpine-fs $(ALPINE_FS_VERSION)..."
	@ALPINE_FS_VERSION=$(ALPINE_FS_VERSION) $(IOS_SCRIPTS)/download-alpine-fs.sh
	@touch $@

verify-ios-project:
	@$(IOS_SCRIPTS)/regenerate-project.sh --repair-only

ios-build-sim: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		COMPILER_INDEX_STORE_ENABLE=NO \
		build

ios-build-sim-fast: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), fast simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		COMPILER_INDEX_STORE_ENABLE=NO \
		ONLY_ACTIVE_ARCH=YES \
		build

ios-build-device: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		COMPILER_INDEX_STORE_ENABLE=NO \
		build

ios-build-device-fast: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), fast device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		COMPILER_INDEX_STORE_ENABLE=NO \
		ONLY_ACTIVE_ARCH=YES \
		build

ios-build: ios-build-sim

# ─────────────────────────────────────────────────────────────────────────────
# watchOS build lanes
# The watch app (LitterWatch) and its complications (LitterWatchComplications)
# are pure Swift/SwiftUI — they don't link the shared Rust library, so there
# is no rust-watch step. The watch app is also embedded into the main iOS
# app, so `make ios-sim-fast` will build it transitively when that ships.
#
# Variables you can override:
#   WATCH_SIM_DEVICE       simulator name for watch-sim-run (default: Apple Watch Series 11 (46mm))
#   WATCH_SIM_UDID         concrete watch simulator UDID for watch-sim-run
#   WATCH_BUILD_DESTINATION xcodebuild watchOS simulator destination (default: generic/platform=watchOS Simulator)
#   WATCH_SCHEME           Xcode scheme (default: LitterWatch)
# ─────────────────────────────────────────────────────────────────────────────

WATCH_SIM_DEVICE ?= Apple Watch Series 11 (46mm)
WATCH_SIM_UDID ?=
WATCH_BUILD_DESTINATION ?= generic/platform=watchOS Simulator
WATCH_SCHEME ?= LitterWatch

watch: watch-sim

watch-typecheck:
	@echo "==> Type-checking watchOS sources..."
	@cd $(IOS_DIR) && xcrun -sdk watchsimulator swiftc -typecheck \
		-target arm64-apple-watchos11.0-simulator \
		$$(find Sources/LitterWatch Sources/LitterWatchComplications -name '*.swift')

watch-sim: verify-ios-project
	@echo "==> Building watchOS ($(XCODE_CONFIG), simulator: $(WATCH_SIM_DEVICE))..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(WATCH_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination '$(WATCH_BUILD_DESTINATION)' \
		COMPILER_INDEX_STORE_ENABLE=NO \
		ONLY_ACTIVE_ARCH=YES \
		build

watch-device: verify-ios-project
	@echo "==> Building watchOS ($(XCODE_CONFIG), device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(WATCH_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=watchOS' \
		-allowProvisioningUpdates \
		COMPILER_INDEX_STORE_ENABLE=NO \
		ONLY_ACTIVE_ARCH=YES \
		build

# Add a newly paired Apple Watch's UDID to the developer portal so device
# installs stop failing with "App could not be installed at this time".
# The script discovers the watch via `xcrun devicectl list devices`
# (override with WATCH_UDID=...) and runs the one-shot xcodebuild
# invocation that triggers Xcode's provisioning device-registration
# flow. The stamp file is keyed on the UDID, so re-running this target
# is a no-op after the first success — pairing a new watch produces a
# new UDID and re-triggers registration automatically.
watch-register: xcgen
	@watch_udid="$$($(IOS_SCRIPTS)/register-paired-watch.sh --print-udid)" || { \
		echo "==> watch-register: no paired Apple Watch found (set WATCH_UDID=... to override)" >&2; \
		exit 1; \
	}; \
	stamp="$(STAMPS)/watch-register-$$watch_udid.stamp"; \
	if [ -f "$$stamp" ]; then \
		echo "==> Apple Watch $$watch_udid already registered (stamp: $$stamp)"; \
		echo "    Remove the stamp file to force re-registration."; \
		exit 0; \
	fi; \
	WATCH_UDID="$$watch_udid" XCODE_CONFIG="$(XCODE_CONFIG)" WATCH_SCHEME="$(WATCH_SCHEME)" \
		$(IOS_SCRIPTS)/register-paired-watch.sh && \
	touch "$$stamp" && \
	echo "==> Wrote stamp $$stamp"

# Boot a matching watch simulator, build, install the .app and launch.
watch-sim-run: watch-sim
	@echo "==> Booting $(WATCH_SIM_DEVICE) and installing LitterWatch..."
	@WATCH_UDID="$(WATCH_SIM_UDID)" ; \
	if [ -z "$$WATCH_UDID" ]; then \
		WATCH_UDID=$$(xcrun simctl list devices available | awk 'index($$0, "$(WATCH_SIM_DEVICE)") { \
			if (match($$0, /\([0-9A-F-]+\)/)) id=substr($$0, RSTART+1, RLENGTH-2) \
		} END { print id }') ; \
	fi ; \
	if [ -z "$$WATCH_UDID" ]; then \
		echo "ERROR: no simulator matching '$(WATCH_SIM_DEVICE)'. Run 'xcrun simctl list devices' to see what's installed."; exit 1; \
	fi ; \
	xcrun simctl boot $$WATCH_UDID 2>/dev/null || true ; \
	APP_PATH=$$(xcodebuild -project $(IOS_DIR)/Litter.xcodeproj -scheme $(WATCH_SCHEME) \
		-configuration $(XCODE_CONFIG) -destination "$(WATCH_BUILD_DESTINATION)" \
		-showBuildSettings 2>/dev/null | awk -F' = ' '/ CODESIGNING_FOLDER_PATH /{print $$2; exit}') ; \
	echo "==> Installing $$APP_PATH"; \
	xcrun simctl install $$WATCH_UDID "$$APP_PATH" ; \
	xcrun simctl launch $$WATCH_UDID com.sigkitten.litter.watchkitapp

android-debug:
	@echo "==> Building Android debug..."
	@cd $(ANDROID_DIR) && $(ANDROID_ENV) ./gradlew :app:assembleDebug

android-install: android-debug
	@echo "==> Installing APK to device..."
	@DEVICE=$${ANDROID_DEVICE_SERIAL:-$$(adb devices | awk -F'\t' 'NR>1 && $$2=="device" && $$1 !~ /^emulator-/ {print $$1; exit}')} && \
	if [ -z "$$DEVICE" ]; then echo "ERROR: no connected Android device found (set ANDROID_DEVICE_SERIAL=<serial> to override)"; exit 1; fi && \
	echo "==> Using device $$DEVICE..." && \
	INSTALL_OUTPUT=$$(adb -s "$$DEVICE" install -r $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk 2>&1) && \
	printf '%s\n' "$$INSTALL_OUTPUT" || { \
		status=$$?; \
		printf '%s\n' "$$INSTALL_OUTPUT"; \
		if printf '%s' "$$INSTALL_OUTPUT" | grep -q 'INSTALL_FAILED_UPDATE_INCOMPATIBLE'; then \
			if [ "$(ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH)" = "1" ]; then \
				echo "==> Installed app has a different signing key; uninstalling $(ANDROID_PACKAGE) and retrying..."; \
				adb -s "$$DEVICE" uninstall $(ANDROID_PACKAGE) && \
				adb -s "$$DEVICE" install -r $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk || exit $$?; \
			else \
				echo "ERROR: installed app signature does not match this APK. Re-run with ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH=1 to uninstall the existing app and install this build."; \
				exit 1; \
			fi; \
		elif printf '%s' "$$INSTALL_OUTPUT" | grep -q 'INSTALL_FAILED_VERSION_DOWNGRADE'; then \
			echo "==> Installed app has a higher versionCode; uninstalling $(ANDROID_PACKAGE) and retrying..."; \
			adb -s "$$DEVICE" uninstall $(ANDROID_PACKAGE) && \
			adb -s "$$DEVICE" install -r $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk || exit $$?; \
		else \
			exit $$status; \
		fi; \
	}

android-emulator-install: android-emulator-fast
	@echo "==> Installing APK to emulator..."
	@EMU=$$(adb devices | grep '^emulator-' | head -1 | cut -f1) && \
	if [ -z "$$EMU" ]; then echo "ERROR: no emulator found"; exit 1; fi && \
	adb -s "$$EMU" install -r $(ANDROID_APK)

test: test-rust test-ios test-android

test-rust: alleycat-main
	@echo "==> Running Rust tests..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo test --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client --lib

test-ios: xcgen
	@echo "==> Running iOS tests..."
	@xcodebuild test -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration Debug \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)'

test-android:
	@echo "==> Running Android tests..."
	@cd $(ANDROID_DIR) && ./gradlew :app:testDebugUnitTest

ios-release-prep: rust-ios-device-release alpine-fs xcgen

mac-release-prep: rust-mac-release xcgen

testflight: ios-release-prep
	@echo "==> Uploading to TestFlight..."
	@$(IOS_SCRIPTS)/testflight-upload.sh

mac-testflight: mac-release-prep
	@echo "==> Uploading Mac Catalyst build to TestFlight..."
	@$(IOS_SCRIPTS)/testflight-upload-mac.sh

mac-direct-dist: mac-release-prep
	@echo "==> Building notarized Mac Catalyst DMG for direct distribution..."
	@$(IOS_SCRIPTS)/direct-dist-mac.sh

appstore-release: ios-release-prep
	@echo "==> Submitting current repo version to the App Store..."
	@$(IOS_SCRIPTS)/app-store-release.sh

play-upload: android-release
	@echo "==> Uploading to Google Play..."
	@$(ANDROID_DIR)/scripts/play-upload.sh

play-release:
	@if [ -n "$$LITTER_VERSION_CODE_OVERRIDE" ]; then \
		echo "==> Using overridden Android versionCode $$LITTER_VERSION_CODE_OVERRIDE"; \
	else \
		$(ANDROID_DIR)/scripts/bump-version.sh; \
	fi
	@$(MAKE) play-upload

clean: clean-rust clean-ios clean-android
	@rm -rf $(STAMPS)
	@echo "==> Clean complete"

clean-rust:
	@echo "==> Cleaning Rust build artifacts..."
	@if [ "$(LITTER_SHARED_RUST_TARGET)" = "1" ] && [ "$(RUST_TARGET)" != "$(RUST_DIR)/target" ]; then \
		echo "==> Shared Rust target is enabled; leaving $(RUST_TARGET) intact."; \
		echo "==> Remove it manually if you really want to clear the shared cache."; \
	else \
		rm -rf $(RUST_TARGET); \
	fi

clean-ios:
	@echo "==> Cleaning iOS artifacts..."
	@rm -rf $(IOS_FW_DIR)/codex_mobile_client.xcframework $(IOS_FW_DIR)/GhosttyKit.xcframework $(IOS_GENERATED)
	@rm -rf $(IOS_DIR)/Resources/fs
	@rm -f $(STAMP_XCGEN) $(STAMP_BINDINGS_S) $(STAMPS)/alpine-fs-* $(STAMPS)/ghostty-ios-*

# Reclaim development cache without destroying the compiled dependency graph.
# Refuse to run while Cargo holds a target lock; removing a live target is not
# safe.  This deliberately leaves `deps` in place so the next build is fast.
prune-dev-cache:
	@for cache_dir in "$(RUST_TARGET)" "$(KITTYLITTER_DEV_DIR)/target"; do \
		if [ -d "$$cache_dir" ] && find "$$cache_dir" -type f -name .cargo-lock -exec lsof -t {} \; 2>/dev/null | grep -q .; then \
			echo "ERROR: Cargo is using $$cache_dir. Wait for it to finish before pruning." >&2; \
			exit 1; \
		fi; \
	done
	@if [ -d "$(RUST_TARGET)" ]; then \
		echo "==> Removing Rust incremental artifacts from $(RUST_TARGET)..."; \
		find "$(RUST_TARGET)" -type d -name incremental -prune -print -exec rm -rf {} +; \
	else \
		echo "==> No Rust target directory to prune."; \
	fi
	@if [ -d "$(KITTYLITTER_DEV_DIR)/target" ]; then \
		echo "==> Removing legacy KittyLitter target tree..."; \
		du -sh "$(KITTYLITTER_DEV_DIR)/target"; \
		rm -rf "$(KITTYLITTER_DEV_DIR)/target"; \
	fi

# Keep the active simulator lane small by dropping artifacts it cannot use.
# Ghostty will be rebuilt by the next iOS build because it is a shared
# prerequisite; this target is for reclaiming space when that rebuild is okay.
prune-ios-sim-only:
	@echo "==> Removing non-simulator iOS development artifacts..."
	@rm -rf "$(IOS_GENERATED)/ios-device" "$(IOS_GENERATED)/ios-macabi" "$(IOS_GENERATED)/ghostty-build"
	@rm -f $(STAMPS)/ghostty-ios-*

clean-android:
	@echo "==> Cleaning Android artifacts..."
	@rm -rf $(ANDROID_JNI)/arm64-v8a $(ANDROID_JNI)/x86_64 $(ANDROID_DIR)/core/bridge/src/main/cpp/include/ghostty.h
	@rm -f $(ANDROID_DIR)/app/src/main/assets/alpine-fs.tar.gz $(ANDROID_DIR)/app/src/main/assets/alpine-fs.tgz $(ANDROID_DIR)/app/src/main/assets/alpine-fs.version
	@rm -f $(ANDROID_APP_JNI)/arm64-v8a/libproot.so $(ANDROID_APP_JNI)/arm64-v8a/libproot_loader.so $(ANDROID_APP_JNI)/x86_64/libproot.so $(ANDROID_APP_JNI)/x86_64/libproot_loader.so
	@rm -f $(ANDROID_DIR)/app/src/main/assets/licenses/proot-COPYING.txt $(ANDROID_DIR)/app/src/main/assets/licenses/talloc-COPYING.txt $(ANDROID_DIR)/app/src/main/assets/proot.version
	@rm -f $(STAMP_BINDINGS_K) $(STAMPS)/rust-android-* $(STAMPS)/ghostty-android-* $(STAMPS)/android-alpine-fs-* $(STAMPS)/proot-android-*
	@cd $(ANDROID_DIR) && ./gradlew clean 2>/dev/null || true

rebuild-bindings:
	@rm -f $(STAMP_BINDINGS_S) $(STAMP_BINDINGS_K)
	@$(MAKE) bindings

screenshots: screenshots-ios screenshots-android

screenshots-ios:
	@echo "── Capturing iOS screenshots ──"
	cd $(IOS_DIR) && bundle exec fastlane screenshots

screenshots-android:
	@echo "── Capturing Android screenshots ──"
	cd $(ANDROID_DIR) && bundle exec fastlane screenshots

$(KITTYLITTER_DEV_MANIFEST): $(KITTYLITTER_DIR)/Cargo.toml $(KITTYLITTER_DIR)/src/main.rs
	@if [ ! -f "$(ALLEYCAT_DEV_DIR)/crates/alleycat/Cargo.toml" ]; then \
		echo "error: ALLEYCAT_DEV_DIR=$(ALLEYCAT_DEV_DIR) does not look like an alleycat checkout"; \
		echo "override with: make kittylitter ALLEYCAT_DEV_DIR=/path/to/alleycat"; \
		exit 1; \
	fi
	@mkdir -p "$(KITTYLITTER_DEV_DIR)/src"
	@printf '%s\n' \
		'[workspace]' \
		'' \
		'[package]' \
		'name = "kittylitter-dev"' \
		'version = "$(KITTYLITTER_VERSION)"' \
		'edition = "2024"' \
		'publish = false' \
		'' \
		'[[bin]]' \
		'name = "kittylitter"' \
		'path = "src/main.rs"' \
		'' \
		'[dependencies]' \
		'alleycat = { path = "$(ALLEYCAT_DEV_DIR)/crates/alleycat" }' \
		'anyhow = "1"' \
		> "$(KITTYLITTER_DEV_MANIFEST)"
	@printf '%s\n' \
		'fn main() -> anyhow::Result<()> {' \
		'    alleycat::App {' \
		'        binary_name: "kittylitter",' \
		'        qualifier: "com",' \
		'        organization: "sigkitten",' \
		'        application: "kittylitter",' \
		'        label: "com.sigkitten.kittylitter",' \
		'        version: env!("CARGO_PKG_VERSION"),' \
		'    }' \
		'    .run()' \
		'}' \
		> "$(KITTYLITTER_DEV_DIR)/src/main.rs"

kittylitter: $(KITTYLITTER_DEV_MANIFEST)
	@echo "── Running kittylitter $(KITTYLITTER_ARGS) via $(ALLEYCAT_DEV_DIR) ──"
	@cd $(ROOT) && $(KITTYLITTER_CARGO_ENV) cargo run --manifest-path "$(KITTYLITTER_DEV_MANIFEST)" --bin kittylitter -- $(KITTYLITTER_ARGS)

kittylitter-restart: $(KITTYLITTER_DEV_MANIFEST)
	@echo "── Building kittylitter via $(ALLEYCAT_DEV_DIR) ──"
	@cd $(ROOT) && $(KITTYLITTER_CARGO_ENV) cargo build --manifest-path "$(KITTYLITTER_DEV_MANIFEST)" --bin kittylitter
	@echo "── Restarting installed kittylitter daemon ──"
	@cd $(ROOT) && $(KITTYLITTER_CARGO_ENV) cargo run --manifest-path "$(KITTYLITTER_DEV_MANIFEST)" --bin kittylitter -- stop >/dev/null 2>&1 || true
	@if launchctl print "gui/$$(id -u)/com.sigkitten.kittylitter" >/dev/null 2>&1; then \
		launchctl kickstart -k "gui/$$(id -u)/com.sigkitten.kittylitter"; \
		sleep 3; \
		cd "$(ROOT)" && $(KITTYLITTER_CARGO_ENV) cargo run --manifest-path "$(KITTYLITTER_DEV_MANIFEST)" --bin kittylitter -- agents list; \
	else \
		echo "kittylitter autostart is not installed; start it with: make kittylitter serve"; \
	fi
