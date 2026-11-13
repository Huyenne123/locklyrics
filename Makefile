THEOS ?= /home/neyuh/theos
THEOS_PACKAGE_SCHEME ?= roothide

TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LockLyrics

LockLyrics_FILES = Source/Tweak.x Source/LRLyricsModel.m Source/LRLyricsManager.m Source/LRLyricsView.m Source/LRPreferences.m
LockLyrics_CFLAGS = -fobjc-arc -IHeaders -ISource
LockLyrics_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
LockLyrics_PRIVATE_FRAMEWORKS = MediaRemote

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk

