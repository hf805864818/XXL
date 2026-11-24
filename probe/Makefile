# PetDFYProbe — 极简探针（纯 constructor，不依赖 substrate 符号）
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:16.0
export INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PetDFYProbe
PetDFYProbe_FILES = PetDFYProbe.m
PetDFYProbe_CFLAGS = -fobjc-arc -Wno-everything
PetDFYProbe_FRAMEWORKS = Foundation UIKit
PetDFYProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
