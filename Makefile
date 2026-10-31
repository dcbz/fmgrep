# The FoundationModels @Generable/@Guide macro plugins ship with Xcode, not
# with bare Command Line Tools, so prefer the Xcode toolchain when present.
XCODE := /Applications/Xcode.app
ifeq ($(wildcard $(XCODE)),)
  DEV_DIR :=
else ifeq ($(filter Xcode.app,$(shell xcode-select -p)),)
  DEV_DIR := DEVELOPER_DIR=$(XCODE)
else
  DEV_DIR :=
endif

SWIFT = $(DEV_DIR) swift

.PHONY: build release test install clean

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

test: release
	./Tests/run.sh

install: release
	mkdir -p $(DESTDIR)/usr/local/bin
	cp .build/release/fmgrep $(DESTDIR)/usr/local/bin/fmgrep

clean:
	rm -rf .build
