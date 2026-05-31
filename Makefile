TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = 超自然行动组

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Xyaim
XyAim_FILES = Xyaim.m
XyAim_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk
