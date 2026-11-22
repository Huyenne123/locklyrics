THEOS ?= /home/neyuh/theos

TARGET := iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LockLyricsPrefs

LockLyricsPrefs_FILES = LRPRootListController.m LRPLockScreenPreviewCell.m
LockLyricsPrefs_FRAMEWORKS = UIKit QuartzCore
LockLyricsPrefs_PRIVATE_FRAMEWORKS = Preferences
LockLyricsPrefs_INSTALL_PATH = /Library/PreferenceBundles
LockLyricsPrefs_CFLAGS = -fobjc-arc -I../Headers

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
LockLyricsPrefs_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/bundle.mk

