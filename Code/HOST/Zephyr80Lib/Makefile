.DEFAULT_GOAL := all

PYTHON  ?= python3
FTLDIR  ?= ../Software/disk1/5
RUNCPM  ?= TOOLS/RUNCPM
CCPFILE ?= TOOLS/CCP-ZCP3.60K

.PHONY: all build clean help

all: build

build:
	$(PYTHON) TOOLS/FTLBUILD.PY \
		--ftl-dir "$(FTLDIR)" \
		--runcpm "$(RUNCPM)" \
		--ccp "$(CCPFILE)" \
		--output BUILD/FTL

clean:
	$(RM) -r BUILD/FTL

help:
	@echo "make          Build the FTL Modula-2 objects under BUILD/FTL"
	@echo "make clean    Remove them"
	@echo "Overrides: PYTHON, FTLDIR, RUNCPM, CCPFILE"
