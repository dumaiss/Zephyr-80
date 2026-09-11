.DEFAULT_GOAL := all

PYTHON    ?= python3
RUNCPM    ?= TOOLS/RUNCPM
TM2DIR    ?= ../Software/disk1/4
CCPFILE   ?= ../CPM2.2/zcpr2/tools/runcpm-ccp/CCP-ZCP3.60K
NIGHTZTR  ?= ../SNTracker/songs/night-market.ztr
RUNAWAY   ?= ../SNTracker/songs/RunawayCircuit.ztr

.PHONY: all build test clean help

all: build

build:
	$(PYTHON) TOOLS/TM2BUILD.PY \
		--runcpm "$(RUNCPM)" \
		--tm2-dir "$(TM2DIR)" \
		--ccp "$(CCPFILE)" \
		--night "$(NIGHTZTR)" \
		--runaway "$(RUNAWAY)" \
		--output BUILD

test: build

clean:
	$(RM) BUILD/SNTRACK.COM BUILD/TIMTEST.COM BUILD/SNDTEST.COM \
		BUILD/ZTRTEST.COM BUILD/PLYTEST.COM

help:
	@echo "make          Build and run the host-independent regression tests"
	@echo "make clean    Remove generated COM files"
	@echo "Override RUNCPM, TM2DIR, CCPFILE, NIGHTZTR, or RUNAWAY as needed"
