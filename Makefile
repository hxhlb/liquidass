# build for a real device then: make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless/roothide

LG_SIM_GOAL := $(filter sim,$(MAKECMDGOALS))
LG_SIM_LOCAL_GOAL := $(filter sim-local,$(MAKECMDGOALS))

ifeq ($(LG_SIM_LOCAL_GOAL),sim-local)
export TARGET ?= simulator:clang:latest:14.0
export ARCHS ?= arm64
export LIQUIDASS_STANDALONE_UI ?= 1
export TARGET_CODESIGN ?=
export TARGET_CODESIGN_FLAGS ?=
else ifeq ($(LG_SIM_GOAL),sim)
export TARGET ?= simulator:clang:latest:14.0
export ARCHS ?= x86_64
else
export TARGET ?= iphone:clang:latest:14.0
export ARCHS ?= arm64 arm64e
endif

# Avoid linking against CydiaSubstrate.framework by switching
# Logos to the internal (objc-runtime) generator.
export LOGOS_DEFAULT_GENERATOR = internal

INSTALL_TARGET_PROCESSES = SpringBoard chronod WidgetRenderer_Default WidgetRenderer_CarPlay
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = liquidass
HOOK_FILES := $(wildcard Hooks/*.x) $(wildcard Hooks/Lockscreen/*.x)
SHARED_FILES := Shared/LGSharedSupport.m Shared/LGHookSupport.m Shared/LGBannerCaptureSupport.m Shared/LGMetalShaderSource.m Shared/LGGlassRenderer.m Shared/LGBackButtonSupport.m Shared/LGRWBSupport.m
RUNTIME_FILES := Runtime/LGLiquidGlassRuntime.m Runtime/LGSnapshotCaptureSupport.m
PREF_CONTROL_FILES := LiquidAssPrefs/LGPrefsLiquidSlider.m LiquidAssPrefs/LGPrefsLiquidSwitch.m
STANDALONE_PREF_FILES := LiquidAssPrefs/LGPRootListController.m LiquidAssPrefs/LGPSurfaceController.m LiquidAssPrefs/LGPrefsDataSupport.m LiquidAssPrefs/LGPrefsUIHelpers.m
ifeq ($(LIQUIDASS_STANDALONE_UI),1)
$(TWEAK_NAME)_FILES = Tweak.x $(HOOK_FILES) $(SHARED_FILES) $(RUNTIME_FILES) $(PREF_CONTROL_FILES) $(STANDALONE_PREF_FILES)
else
$(TWEAK_NAME)_FILES = Tweak.x $(HOOK_FILES) $(SHARED_FILES) $(RUNTIME_FILES) $(PREF_CONTROL_FILES)
endif
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -fvisibility=default
ifeq ($(LIQUIDASS_STANDALONE_UI),1)
$(TWEAK_NAME)_CFLAGS += -DLIQUIDASS_STANDALONE_UI=1
endif
$(TWEAK_NAME)_FRAMEWORKS = UIKit Metal MetalKit Accelerate
$(TWEAK_NAME)_INSTALL_PATH = @rpath

include $(THEOS)/makefiles/tweak.mk
ifneq ($(LIQUIDASS_STANDALONE_UI),1)
SUBPROJECTS += LiquidAssPrefs
SUBPROJECTS += LiquidAssRWB
endif
include $(THEOS_MAKE_PATH)/aggregate.mk

.PHONY: sim sim-local remove release

sim:: all
	@rm -f /opt/simject/$(TWEAK_NAME).dylib
	@cp -v .theos/obj/iphone_simulator/debug/$(TWEAK_NAME).dylib /opt/simject
	@cp -v $(PWD)/$(TWEAK_NAME).plist /opt/simject
	@rm -f /opt/simject/LiquidAssRWB.dylib
	@cp -v .theos/obj/iphone_simulator/debug/LiquidAssRWB.dylib /opt/simject
	@cp -v $(PWD)/LiquidAssRWB/LiquidAssRWB.plist /opt/simject
	@mkdir -p /opt/simject/PreferenceLoader/Preferences
	@mkdir -p /opt/simject/PreferenceBundles
	@rm -rf /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle
	@cp -vR .theos/obj/iphone_simulator/debug/LiquidAssPrefs.bundle /opt/simject/PreferenceBundles/
	@APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' $(PWD)/LiquidAssPrefs/Resources/Localizable.strings | head -n 1); \
	cp -v $(PWD)/LiquidAssPrefs/Resources/entry.plist /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist; \
	/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist; \
	/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist
	@resim
	@pkill -9 -f 'CoreSimulator/.*/ChronoCore.framework/Support/chronod' || true
	@pkill -9 -f 'CoreSimulator/.*/Preferences' || true

sim-local:: all
	@printf 'standalone dylib ready: %s\n' "$(PWD)/.theos/obj/iphone_simulator/debug/$(TWEAK_NAME).dylib"

before-package::
	@APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' $(PWD)/LiquidAssPrefs/Resources/Localizable.strings | head -n 1); \
	if [ -f "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist" ]; then \
		/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist"; \
	fi; \
	if [ -f "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist" ]; then \
		/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist"; \
	fi

remove::
	@rm -f /opt/simject/$(TWEAK_NAME).dylib /opt/simject/$(TWEAK_NAME).plist
	@rm -f /opt/simject/LiquidAssRWB.dylib /opt/simject/LiquidAssRWB.plist
	@[ ! -d /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle ] || rm -rf /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle
	@[ ! -f /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist ] || rm -f /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist

# originally i tried to add `release::` here but apparently that keeps breaking for whatever fucking reason so i decided to create `release.sh`
