# PetDFYDiag — 独立诊断 tweak（不依赖 T3 源码）
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:16.0
export INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PetDFYDiag
PetDFYDiag_FILES = Tweak.xm
PetDFYDiag_CFLAGS = -fobjc-arc -Wno-everything
PetDFYDiag_FRAMEWORKS = Foundation UIKit
PetDFYDiag_LDFLAGS = -Wl,-undefined,dynamic_lookup
PetDFYDiag_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
