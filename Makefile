SHELL := /bin/bash
.SHELLFLAGS = -ec

# Prerequisite variables
SOURCEDIR   := $(shell printf "%q\n" "$(shell pwd)")
OUTPUTDIR   := $(SOURCEDIR)/artifacts
WORKINGDIR  := $(SOURCEDIR)/Natives/build
DETECTPLAT  := $(shell uname -s)
DETECTARCH  := $(shell uname -m)
VERSION     := $(shell cat $(SOURCEDIR)/DEBIAN/control.development | grep Version | cut -b 10-60)
COMMIT      := $(shell git log --oneline | sed '2,10000000d' | cut -b 1-7)

# Release vs Debug
RELEASE ?= 0

ifeq (1,$(RELEASE))
CMAKE_BUILD_TYPE := Release
else
CMAKE_BUILD_TYPE := Debug
endif

# Distinguish iOS from macOS, and *OS from others
ifeq ($(DETECTPLAT),Darwin)
ifeq ($(shell sw_vers -productName),macOS)
IOS         := 0
SDKPATH     ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
BOOTJDK     ?= /usr/bin
ifneq (,$(findstring arm,DETECTARCH))
SYSARCH     := arm
$(warning Building on an Apple-Silicon Mac.)
else ifneq (,$(findstring 86,$(DETECTARCH)))
SYSARCH     := x86_64
$(warning Building on an Intel or AMD-based Mac.)
endif
else
IOS         := 1
SDKPATH     ?= /usr/share/SDKs/iPhoneOS.sdk
BOOTJDK     ?= /usr/lib/jvm/java-8-openjdk/bin
SYSARCH     := arm
$(warning Building on a jailbroken iOS device.)
endif
else ifeq ($(DETECTPLAT),Linux)
$(warning Building on Linux. Note that all targets may not compile or require external components.)
IOS         := 0
# SDKPATH presence is checked later
BOOTJDK     ?= /usr/bin
SYSARCH     := $(shell uname -m)
else
$(error This platform is not currently supported for building PojavLauncher.)
endif

POJAV_BUNDLE_DIR    ?= $(OUTPUTDIR)/PojavLauncher.app
POJAV_JRE8_DIR       ?= $(SOURCEDIR)/depends/java-8-openjdk
POJAV_JRE17_DIR       ?= $(SOURCEDIR)/depends/java-17-openjdk

# Function to use later for checking dependencies
DEPCHECK   = $(shell type $(1) >/dev/null 2>&1 && echo 1)

# Function to modify Info.plist files
INFOPLIST  =  \
	if [ '$(4)' = '0' ]; then \
		plutil -replace $(1) -string $(2) $(3); \
	else \
		plutil -value $(2) -key $(1) $(3); \
	fi

# Function to check directories
DIRCHECK   = \
	if [ ! -d '$(1)' ]; then \
		mkdir $(1); \
	else \
		if [ '$(NOSTDIN)' = '1' ]; then \
			echo '$(SUDOPASS)' | sudo -S rm -rf $(1)/*; \
		else \
			sudo rm -rf $(1)/*; \
		fi; \
	fi


# Make sure everything is already available for use. Error if they require something
ifeq ($(call HAS_COMMAND,cmake --version),1)
$(error You need to install cmake)
endif

ifeq ($(call HAS_COMMAND,$(BOOTJDK)/javac -version),1)
$(error You need to install JDK 8)
endif

ifeq ($(IOS),0)
ifeq ($(filter 1.8.0,$(shell $(BOOTJDK)/javac -version &> javaver.txt && cat javaver.txt | cut -b 7-11 && rm -rf javaver.txt)),)
$(error You need to install JDK 8)
endif
endif

ifeq ($(call HAS_COMMAND,ldid),1)
$(error You need to install ldid)
endif

ifeq ($(call HAS_COMMAND,fakeroot -v),1)
$(error You need to install fakeroot)
endif

ifeq ($(DETECTPLAT),Linux)
ifeq ($(call HAS_COMMAND,lld),1)
$(error You need to install lld)
endif
endif

ifeq ($(call HAS_COMMAND,nproc --version),1)
ifeq ($(call HAS_COMMAND,gnproc --version),1)
$(warning Unable to determine number of threads, defaulting to 2.)
JOBS   ?= 2
else
JOBS   ?= $(shell gnproc)
endif
else
JOBS   ?= $(shell nproc)
endif

ifndef SDKPATH
$(error You need to specify SDKPATH to the path of iPhoneOS.sdk. The SDK version should be 14.0 or newer.)
endif

# Now for the actual Makefile recipes.
#  all     - runs clean, native, java, extras, and package.
#  check   - Makes sure that all variables are correct.
#  native  - Builds the Objective-C code.
#  java    - Builds the Java code.
#  extras  - Builds the Assets and Storyboard.
#  ipa     - Builds the application package.

all: clean native java extras deb

check:
	@printf '\nDumping all Makefile variables.\n'
	@printf 'DETECTPLAT           - $(DETECTPLAT)\n'
	@printf 'DETECTARCH           - $(DETECTARCH)\n'
	@printf 'SDKPATH              - $(SDKPATH)\n'
	@printf 'BOOTJDK              - $(BOOTJDK)\n'
	@printf 'SOURCEDIR            - $(SOURCEDIR)\n'
	@printf 'WORKINGDIR           - $(WORKINGDIR)\n'
	@printf 'OUTPUTDIR            - $(OUTPUTDIR)\n'
	@printf 'JOBS                 - $(JOBS)\n'
	@printf 'VERSION              - $(VERSION)\n'
	@printf 'COMMIT               - $(COMMIT)\n'
	@printf 'RELEASE              - $(RELEASE)\n'
	@printf 'IOS                  - $(IOS)\n'
	@printf 'SYSARCH              - $(SYSARCH)\n'
	@printf 'POJAV_BUNDLE_DIR     - $(POJAV_BUNDLE_DIR)\n'
	@printf 'POJAV_JRE_DIR        - $(POJAV_JRE_DIR)\n'
	@printf '\nVerify that all of the variables are correct.\n'
	
native:
	@echo 'Building PojavLauncher $(VERSION) - NATIVES - Start'
	@mkdir -p $(WORKINGDIR)
	@cd $(WORKINGDIR) && cmake . \
		-DCMAKE_BUILD_TYPE=$(CMAKE_BUILD_TYPE) \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_C_FLAGS="-arch arm64 -miphoneos-version-min=12.0" \
		-DCONFIG_COMMIT="$(COMMIT)" \
		-DCONFIG_RELEASE=$(RELEASE) \
		..

	@cmake --build $(WORKINGDIR) --config $(CMAKE_BUILD_TYPE) -j$(JOBS)
	@# --target awt_headless awt_xawt libOSMesaOverride.dylib tinygl4angle PojavLauncher
	@rm $(WORKINGDIR)/libawt_headless.dylib
	@echo 'Building PojavLauncher $(VERSION) - NATIVES - End'

java:
	@echo 'Building PojavLauncher $(VERSION) - JAVA - Start'
	@cd $(SOURCEDIR)/JavaApp; \
	mkdir -p local_out/classes; \
	$(BOOTJDK)/javac -cp "libs/*:libs_caciocavallo/*" -d local_out/classes $$(find src -type f -name "*.java" -print) -XDignore.symbol.file || exit 1; \
	cd local_out/classes; \
	$(BOOTJDK)/jar -cf ../launcher.jar android com net || exit 1; \
	cp $(SOURCEDIR)/JavaApp/libs/lwjgl3-minecraft.jar ../lwjgl3-minecraft.jar || exit 1; \
	$(BOOTJDK)/jar -uf ../lwjgl3-minecraft.jar org || exit 1;
	@echo 'Building PojavLauncher $(VERSION) - JAVA - End'

extras:
	@echo 'Building PojavLauncher $(VERSION) - EXTRA - Start'
	@if [ '$(IOS)' = '0' ]; then \
		mkdir -p $(WORKINGDIR)/PojavLauncher.app/Base.lproj; \
		xcrun actool $(SOURCEDIR)/Natives/Assets.xcassets --compile $(SOURCEDIR)/Natives/resources --platform iphoneos --minimum-deployment-target 12.0 --app-icon AppIcon --output-partial-info-plist /dev/null || exit 1; \
		ibtool --compile $(WORKINGDIR)/PojavLauncher.app/Base.lproj/LaunchScreen.storyboardc $(SOURCEDIR)/Natives/en.lproj/LaunchScreen.storyboard || exit 1; \
	elif [ '$(IOS)' = '1' ]; then \
		echo 'Due to the required tools not being available, you cannot compile the extras for PojavLauncher with an iOS device.'; \
	fi
	@echo 'Building PojavLauncher $(VERSION) - EXTRAS - End'

ipa: native java extras
	echo 'Building PojavLauncher $(VERSION) - IPA - Start'
	@if [ '$(IOS)' = '1' ]; then \
		mkdir -p $(WORKINGDIR)/PojavLauncher.app/{Frameworks,Base.lproj}; \
		cp -R $(SOURCEDIR)/Natives/en.lproj/*.storyboardc $(WORKINGDIR)/PojavLauncher.app/Base.lproj/ || exit 1; \
		cp -R $(SOURCEDIR)/Natives/Info.plist $(WORKINGDIR)/PojavLauncher.app/Info.plist || exit 1;\
		cp -R $(SOURCEDIR)/Natives/PkgInfo $(WORKINGDIR)/PojavLauncher.app/PkgInfo || exit 1; \
	fi
	$(call DIRCHECK,$(WORKINGDIR)/PojavLauncher.app/libs)
	$(call DIRCHECK,$(WORKINGDIR)/PojavLauncher.app/libs_caciocavallo)
	@cp -R $(SOURCEDIR)/Natives/resources/* $(WORKINGDIR)/PojavLauncher.app/ || exit 1
	@cp $(WORKINGDIR)/*.dylib $(WORKINGDIR)/PojavLauncher.app/Frameworks/ || exit 1
	@( cd $(WORKINGDIR)/PojavLauncher.app/Frameworks; ln -sf libawt_xawt.dylib libawt_headless.dylib ) || exit 1
	@cp -R $(WORKINGDIR)/*.framework $(WORKINGDIR)/PojavLauncher.app/Frameworks/ || exit 1
	@cp -R $(SOURCEDIR)/JavaApp/libs/* $(WORKINGDIR)/PojavLauncher.app/libs/ || exit 1
	@cp $(SOURCEDIR)/JavaApp/local_out/*.jar $(WORKINGDIR)/PojavLauncher.app/libs/ || exit 1
	@cp -R $(SOURCEDIR)/JavaApp/libs_caciocavallo/* $(WORKINGDIR)/PojavLauncher.app/libs_caciocavallo/ || exit 1
	@cp -R $(SOURCEDIR)/Natives/*.lproj $(WORKINGDIR)/PojavLauncher.app/ || exit 1
	$(call DIRCHECK,$(OUTPUTDIR))
	@cp -R $(WORKINGDIR)/PojavLauncher.app $(OUTPUTDIR)
	mkdir -p $(SOURCEDIR)/depends; \
	cd $(SOURCEDIR)/depends; \
	if [ ! -d "java-8-openjdk" ]; then \
		mkdir java-8-openjdk && cd java-8-openjdk; \
		wget 'https://github.com/PojavLauncherTeam/android-openjdk-build-multiarch/releases/download/jre8-40df388/jre8-arm64-20220811-release.tar.xz'; \
		tar xvf *.tar.xz; \
		rm *.tar.xz; \
	fi; \
        cd ..; \
	if [ ! -d "java-17-openjdk" ]; then \
		mkdir java-17-openjdk && cd java-17-openjdk; \
		wget 'https://github.com/PojavLauncherTeam/android-openjdk-build-multiarch/releases/download/jre17-ca01427/jre17-arm64-20220817-release.tar.xz'; \
		tar xvf *.tar.xz; \
		rm *.tar.xz; \
	fi; \
	mkdir -p $(OUTPUTDIR); \
	cd $(OUTPUTDIR); \
	$(call DIRCHECK,$(OUTPUTDIR)/Payload); \
	cp -R $(POJAV_BUNDLE_DIR) $(OUTPUTDIR)/Payload; \
	$(call DIRCHECK,$(OUTPUTDIR)/Payload/PojavLauncher.app/jvm); \
	cp -R $(POJAV_JRE8_DIR) $(OUTPUTDIR)/Payload/PojavLauncher.app/jvm/; \
	cp -R $(POJAV_JRE17_DIR) $(OUTPUTDIR)/Payload/PojavLauncher.app/jvm/; \
	rm -rf $(OUTPUTDIR)/Payload/PojavLauncher.app/jvm/*/{bin,include,jre,lib/{ct.sym,libjsig.dylib,src.zip,tools.jar}}; \
	ldid -S$(SOURCEDIR)/entitlements_ipa.xml $(OUTPUTDIR)/Payload/PojavLauncher.app/PojavLauncher; \
	rm -f $(OUTPUTDIR)/*.ipa; \
	cd $(OUTPUTDIR); \
	chmod -R 755 Payload; \
	sudo chown -R 501:501 Payload; \
	zip --symlinks -r $(OUTPUTDIR)/net.kdt.pojavlauncher-$(VERSION).ipa Payload/*
	@echo 'Building PojavLauncher $(VERSION) - IPA - End'
	
dsym: ipa
	@echo 'Building PojavLauncher $(VERSION) - DSYM - Start'
	@cd $(OUTPUTDIR) && dsymutil --arch arm64 $(OUTPUTDIR)/PojavLauncher.app/PojavLauncher
	@rm -rf $(OUTPUTDIR)/PojavLauncher.dSYM
	@mv $(OUTPUTDIR)/PojavLauncher.app/PojavLauncher.dSYM $(OUTPUTDIR)/PojavLauncher.dSYM
	@echo 'Building PojavLauncher $(VERSION) - DSYM - Start'
	
clean:
	@echo 'Building PojavLauncher $(VERSION) - CLEAN - Start'
	@if [ '$(NOSTDIN)' = '1' ]; then \
		echo '$(SUDOPASS)' | sudo -S rm -rf $(WORKINGDIR); \
		echo '$(SUDOPASS)' | sudo -S rm -rf JavaApp/build; \
		echo '$(SUDOPASS)' | sudo -S rm -rf $(OUTPUTDIR); \
	else \
		sudo rm -rf $(WORKINGDIR); \
		sudo rm -rf JavaApp/build; \
		sudo rm -rf $(OUTPUTDIR); \
	fi
	@echo 'Building PojavLauncher $(VERSION) - CLEAN - End'

help:
	@echo 'Makefile to compile PojavLauncher'
	@echo ''
	@echo 'Usage:'
	@echo '    make                                Makes everything under all'
	@echo '    make all                            Builds natives, javaapp, extras, and package'
	@echo '    make native                         Builds the native app'
	@echo '    make java                           Builds the Java app'
	@echo '    make ipa                            Builds ipa of PojavLauncher'
	@echo '    make clean                          Cleans build directories'

.PHONY: all clean native java extras output ipa

