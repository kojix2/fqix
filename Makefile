CRYSTAL ?= crystal
AMEBA ?= ./bin/ameba
CC ?= cc
BUILD_DIR ?= build
BIN_DIR ?= bin
LDFLAGS ?=
SPEC_ZRAN_OBJECT ?= $(BUILD_DIR)/spec-zran.o
SPEC_ZRAN_LINK_OBJECT := $(abspath $(SPEC_ZRAN_OBJECT))

ifeq ($(release),1)
BUILD_MODE := release
CRYSTAL_BUILD_FLAGS ?= --release
SPEC_CFLAGS ?= -O3 -DNDEBUG
else
BUILD_MODE := debug
CRYSTAL_BUILD_FLAGS ?=
SPEC_CFLAGS ?= -O2
endif

# Optional CPU tuning: `make cpu=native` (or e.g. `cpu=skylake`) builds code
# tuned for that CPU. Tuned binaries may use instructions the build host has but
# other machines lack, so do not ship a cpu=native build to different hardware.
ifeq ($(strip $(cpu)),)
CPU_FLAGS :=
SPEC_CPU_FLAGS :=
CPU_TAG := generic
else
CPU_FLAGS := --mcpu $(cpu)
SPEC_CPU_FLAGS := -march=$(cpu)
CPU_TAG := $(cpu)
endif

BUILD_STAMP := $(BUILD_DIR)/.$(BUILD_MODE)-$(CPU_TAG)-build

.PHONY: all clean help test

all: $(BIN_DIR)/fqix

help:
	@printf '%s\n' \
		'Targets:' \
		'  make              Build bin/fqix' \
		'  make test         Run specs and Ameba' \
		'  make clean        Remove build artifacts' \
		'  make help         Show this help' \
		'' \
		'Options:' \
		'  make release=1    Build with Crystal --release' \
		'  make cpu=native   Tune codegen for this CPU (or cpu=<name>, e.g. skylake)' \
		'  CRYSTAL=crystal   Crystal compiler command' \
		'  AMEBA=./bin/ameba Ameba command' \
		'  CC=cc             C compiler for spec reference object'

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_STAMP): | $(BUILD_DIR)
	@rm -f $(BUILD_DIR)/.*-build
	@touch $@

$(BIN_DIR)/fqix: $(BUILD_STAMP) shard.yml $(shell find src -type f) | $(BIN_DIR)
	$(CRYSTAL) build $(CRYSTAL_BUILD_FLAGS) $(CPU_FLAGS) src/cli.cr -o $@ --link-flags "$(LDFLAGS)"

test: | $(BUILD_DIR)
	@test -x "$(AMEBA)" || { printf '%s\n' 'Ameba executable not found. Run `shards install` first, or set AMEBA=/path/to/ameba.' >&2; exit 1; }
	@trap 'rm -f "$(SPEC_ZRAN_OBJECT)"' EXIT; \
	$(CC) $(SPEC_CFLAGS) $(SPEC_CPU_FLAGS) -c spec/support/zran.c -o "$(SPEC_ZRAN_OBJECT)"; \
	$(CRYSTAL) spec --link-flags "$(SPEC_ZRAN_LINK_OBJECT) $(LDFLAGS)"
	$(AMEBA)

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)
