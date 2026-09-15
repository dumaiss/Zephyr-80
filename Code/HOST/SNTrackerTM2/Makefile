.DEFAULT_GOAL := all

PYTHON   ?= python3
LIBPROJ  ?= ../Zephyr80Lib
LIBFILE  ?= $(LIBPROJ)/BUILD/ZEPHYR80.LIB
RUNCPM   ?= $(LIBPROJ)/TOOLS/RUNCPM
TM2DIR   ?= $(LIBPROJ)/TOOLS/TM2
CCPFILE  ?= $(LIBPROJ)/TOOLS/CCP-ZCP3.60K

.PHONY: all library build test clean help

all: build

library:
	$(MAKE) -C "$(LIBPROJ)" build

build: library
	$(PYTHON) TOOLS/TM2BUILD.PY \
		--runcpm "$(RUNCPM)" \
		--tm2-dir "$(TM2DIR)" \
		--ccp "$(CCPFILE)" \
		--library "$(LIBFILE)" \
		--output BUILD

test: build

clean:
	$(RM) BUILD/SNTRACK.COM

help:
	@echo "make          Rebuild Zephyr80Lib, then build SNTRACK.COM"
	@echo "make clean    Remove the generated standalone tracker"
	@echo "Overrides: PYTHON, LIBPROJ, LIBFILE, RUNCPM, TM2DIR, CCPFILE"
