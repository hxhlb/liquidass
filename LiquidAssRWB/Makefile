INSTALL_TARGET_PROCESSES = SpringBoard chronod WidgetRenderer_Default WidgetRenderer_CarPlay
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssRWB

LiquidAssRWB_FILES = Tweak.x ../Shared/LGRWBSupport.m
LiquidAssRWB_CFLAGS = -fobjc-arc
LiquidAssRWB_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
