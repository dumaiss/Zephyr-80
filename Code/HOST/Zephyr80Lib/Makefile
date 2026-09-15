.DEFAULT_GOAL := all

PYTHON   ?= python3
RUNCPM   ?= TOOLS/RUNCPM
TM2DIR   ?= TOOLS/TM2
CCPFILE  ?= TOOLS/CCP-ZCP3.60K
NIGHTZTR ?= ../SNTracker/songs/night-market.ztr
RUNAWAY  ?= ../SNTracker/songs/RunawayCircuit.ztr

.PHONY: all build test clean help

all: build

build:
	$(PYTHON) TOOLS/LIBBUILD.PY \
		--runcpm "$(RUNCPM)" \
		--tm2-dir "$(TM2DIR)" \
		--ccp "$(CCPFILE)" \
		--night "$(NIGHTZTR)" \
		--runaway "$(RUNAWAY)" \
		--output BUILD

test: build

clean:
	$(RM) BUILD/ZEPHYR80.LIB BUILD/TIMTEST.COM BUILD/SNDTEST.COM \
		BUILD/ZTRTEST.COM BUILD/PLYTEST.COM BUILD/LIBTEST.COM

help:
	@echo "make          Build ZEPHYR80.LIB and run hosted regressions"
	@echo "make clean    Remove generated library and test executables"
	@echo "The default build uses the RunCPM and TM2 tools under TOOLS."
	@echo "Overrides: PYTHON, RUNCPM, TM2DIR, CCPFILE, NIGHTZTR, RUNAWAY"
