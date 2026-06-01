export THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64

TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = 超自然行动组

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Xyaim
Xyaim_FILES = Xyaim.xm
Xyaim_CFLAGS = -fobjc-arc -Wno-arc-performSelector-leaks -Wno-unused-variable -Wno-unused-function

include $(THEOS)/makefiles/tweak.mk
