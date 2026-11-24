CC       ?= cc
AR       ?= ar
PREFIX   ?= /usr/local
DESTDIR  ?=
BUILD    ?= build

COWFS_DIR ?= ../../Sources/CCowFS
CFLAGS    ?= -O2 -Wall -Wextra -std=c11
CPPFLAGS  += -I$(COWFS_DIR)/include -I$(COWFS_DIR)
LDLIBS    := -lz -lpthread

FUSE_PREFIX ?= /usr/local
FUSE_CFLAGS ?= -I$(FUSE_PREFIX)/include/fuse3
FUSE_LIBS   ?= -L$(FUSE_PREFIX)/lib -lfuse3 -Wl,-rpath,/usr/local/lib

LIB_SRCS := \
	$(COWFS_DIR)/cowfs_core.c \
	$(COWFS_DIR)/cowfs_xfs.c \
	$(COWFS_DIR)/cowfs_btrfs.c \
	$(COWFS_DIR)/cowfs_luks_lvm.c

LIB_OBJS := \
	$(BUILD)/cowfs_core.o \
	$(BUILD)/cowfs_xfs.o \
	$(BUILD)/cowfs_btrfs.o \
	$(BUILD)/cowfs_luks_lvm.o

STATIC_LIB := $(BUILD)/libcowfs.a

BINS := \
	$(BUILD)/xfsfuse \
	$(BUILD)/btrfsfuse \
	$(BUILD)/montserrat-mapper

SBINS := \
	$(BUILD)/mkxfs \
	$(BUILD)/mkbtrfs \
	$(BUILD)/xfsck \
	$(BUILD)/btrfsck

.PHONY: all clean install

all: $(STATIC_LIB) $(BINS) $(SBINS)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: $(COWFS_DIR)/%.c $(COWFS_DIR)/include/cowfs_bridge.h $(COWFS_DIR)/cowfs_internal.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(STATIC_LIB): $(LIB_OBJS)
	rm -f $@
	$(AR) rcs $@ $(LIB_OBJS)

$(BUILD)/xfsfuse: cowfs_fuse.c $(STATIC_LIB)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(FUSE_CFLAGS) -DCOWFS_DEFAULT_KIND=COWFS_KIND_XFS $< $(STATIC_LIB) $(LDLIBS) $(FUSE_LIBS) -o $@

$(BUILD)/btrfsfuse: cowfs_fuse.c $(STATIC_LIB)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(FUSE_CFLAGS) -DCOWFS_DEFAULT_KIND=COWFS_KIND_BTRFS $< $(STATIC_LIB) $(LDLIBS) $(FUSE_LIBS) -o $@

$(BUILD)/montserrat-mapper: montserrat_mapper.c $(STATIC_LIB)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(FUSE_CFLAGS) $< $(STATIC_LIB) $(LDLIBS) $(FUSE_LIBS) -o $@

$(BUILD)/mkxfs: cowfs_cli.c $(STATIC_LIB)
	$(CC) $(CPPFLAGS) $(CFLAGS) -DCOWFS_CLI_KIND=COWFS_KIND_XFS -DCOWFS_CLI_IS_MKFS=1 $< $(STATIC_LIB) $(LDLIBS) -o $@

$(BUILD)/mkbtrfs: cowfs_cli.c $(STATIC_LIB)
	$(CC) $(CPPFLAGS) $(CFLAGS) -DCOWFS_CLI_KIND=COWFS_KIND_BTRFS -DCOWFS_CLI_IS_MKFS=1 $< $(STATIC_LIB) $(LDLIBS) -o $@

$(BUILD)/xfsck: cowfs_cli.c $(STATIC_LIB)
	$(CC) $(CPPFLAGS) $(CFLAGS) -DCOWFS_CLI_KIND=COWFS_KIND_XFS -DCOWFS_CLI_IS_MKFS=0 $< $(STATIC_LIB) $(LDLIBS) -o $@

$(BUILD)/btrfsck: cowfs_cli.c $(STATIC_LIB)
	$(CC) $(CPPFLAGS) $(CFLAGS) -DCOWFS_CLI_KIND=COWFS_KIND_BTRFS -DCOWFS_CLI_IS_MKFS=0 $< $(STATIC_LIB) $(LDLIBS) -o $@

install: all
	mkdir -p "$(DESTDIR)$(PREFIX)/include" "$(DESTDIR)$(PREFIX)/lib" "$(DESTDIR)$(PREFIX)/bin" "$(DESTDIR)$(PREFIX)/sbin"
	cp -p $(COWFS_DIR)/include/cowfs_bridge.h "$(DESTDIR)$(PREFIX)/include/cowfs_bridge.h"
	cp -p $(STATIC_LIB) "$(DESTDIR)$(PREFIX)/lib/libcowfs.a"
	cp -p $(BUILD)/xfsfuse "$(DESTDIR)$(PREFIX)/bin/xfsfuse"
	cp -p $(BUILD)/btrfsfuse "$(DESTDIR)$(PREFIX)/bin/btrfsfuse"
	cp -p $(BUILD)/montserrat-mapper "$(DESTDIR)$(PREFIX)/bin/montserrat-mapper"
	cp -p $(BUILD)/mkxfs "$(DESTDIR)$(PREFIX)/sbin/mkxfs"
	cp -p $(BUILD)/mkbtrfs "$(DESTDIR)$(PREFIX)/sbin/mkbtrfs"
	cp -p $(BUILD)/xfsck "$(DESTDIR)$(PREFIX)/sbin/xfsck"
	cp -p $(BUILD)/btrfsck "$(DESTDIR)$(PREFIX)/sbin/btrfsck"

clean:
	rm -rf $(BUILD)
