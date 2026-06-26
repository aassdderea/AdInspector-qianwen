THEOS_PACKAGE_DIR_NAME = debs
TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdInspector

AdInspector_FILES = Tweak.xm
AdInspector_CFLAGS = -fobjc-arc
AdInspector_PRIVATE_FRAMEWORKS = UIKit
AdInspector_LIBRARIES = objc

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	cp .theos/obj/AdInspector.dylib ./AdInspector.dylib
	@echo "✅ dylib ready: ./AdInspector.dylib"