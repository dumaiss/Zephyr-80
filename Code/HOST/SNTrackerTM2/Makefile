.DEFAULT_GOAL := all

PYTHON  ?= python3
LIBPROJ ?= ../Zephyr80Lib
FTLDIR  ?= ../Software/disk1/5

.PHONY: all library build clean help

all: build

library:
	$(MAKE) -C "$(LIBPROJ)" build

build: library
	$(PYTHON) TOOLS/FTLBUILD.PY \
		--ftl-dir "$(FTLDIR)" \
		--library "$(LIBPROJ)/BUILD/FTL" \
		--output BUILD

clean:
	$(RM) BUILD/SNTRACK.COM BUILD/BUILD.LOG

help:
	@echo "make          Rebuild Zephyr80Lib for FTL, then build SNTRACK.COM"
	@echo "make clean    Remove the generated tracker"
	@echo "Overrides: PYTHON, LIBPROJ, FTLDIR"
