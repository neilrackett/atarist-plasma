# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later

CC      = m68k-atari-mint-gcc
AS      = m68k-atari-mint-as
VASM    = vasm
VLINK   = vlink
LIBCMINI = /freemint/libcmini/lib
CFLAGS = -O2 -fomit-frame-pointer -s -std=gnu99 -I/freemint/libcmini/include -I$(SRCDIR)/shared -m68000
LDFLAGS = -s -nostdlib -L$(LIBCMINI) $(LIBCMINI)/crt0.o -m68000
LIBS    = -lcmini -lgcc -lm
VASMFLAGS = -Faout -quiet -x -m68000 -spaces -devpac

SRCDIR = src
DISTDIR  = dist
OBJDIR   = obj
OBJS_SHARED  = $(OBJDIR)/shared/atari_megaste.o
OBJS_PLASMA1 = $(OBJDIR)/plasma1/plasma1.o $(OBJS_SHARED) $(OBJDIR)/plasma1/render_scanlines.o
OBJS_PLASMA2 = $(OBJDIR)/plasma2/plasma2.o $(OBJS_SHARED) $(OBJDIR)/plasma2/render_scanlines_rows.o
DEPS = $(OBJS_PLASMA1:.o=.d) $(OBJS_PLASMA2:.o=.d)

# IMAGE4K1-3.TOS: one build of image4k per palette engine (palettes per row)
IMAGE4K_DIR      = $(SRCDIR)/image4k
IMAGE4K_PICTURES = balloons braies spectrum
IMAGE4K_TARGETS  = $(DISTDIR)/IMAGE4K1.TOS $(DISTDIR)/IMAGE4K2.TOS $(DISTDIR)/IMAGE4K3.TOS
IMAGE4K_OBJS     = $(OBJDIR)/image4k/image4k1.o $(OBJDIR)/image4k/image4k2.o $(OBJDIR)/image4k/image4k3.o

TARGETS = $(DISTDIR)/PLASMA1.TOS $(DISTDIR)/PLASMA2.TOS $(IMAGE4K_TARGETS)

all: $(TARGETS)

$(DISTDIR)/PLASMA1.TOS: $(OBJS_PLASMA1)
	@mkdir -p $(DISTDIR)
	$(CC) $(LDFLAGS) $(OBJS_PLASMA1) $(LIBS) -o $@

$(DISTDIR)/PLASMA2.TOS: $(OBJS_PLASMA2)
	@mkdir -p $(DISTDIR)
	$(CC) $(LDFLAGS) $(OBJS_PLASMA2) $(LIBS) -o $@

$(IMAGE4K_TARGETS): $(DISTDIR)/IMAGE4K%.TOS: $(OBJDIR)/image4k/image4k%.o
	@mkdir -p $(DISTDIR)
	$(VLINK) -bataritos -o $@ $<

$(IMAGE4K_OBJS): $(OBJDIR)/image4k/image4k%.o: $(IMAGE4K_DIR)/image4k.s $(IMAGE4K_DIR)/raster.s \
		$(foreach p,$(IMAGE4K_PICTURES),$(IMAGE4K_DIR)/pictures/%/$(p).scr $(IMAGE4K_DIR)/pictures/%/$(p).pal)
	@mkdir -p $(dir $@)
	$(VASM) $(VASMFLAGS) -DSEGMENTS=$* -I $(IMAGE4K_DIR) -I $(IMAGE4K_DIR)/pictures/$* $< -o $@

$(OBJDIR)/%.o: ${SRCDIR}/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(OBJDIR)/%.o: ${SRCDIR}/%.s
	@mkdir -p $(dir $@)
	$(AS) $< -o $@

.PHONY: all clean

-include $(DEPS)

clean:
	rm -f $(OBJS_PLASMA1) $(OBJS_PLASMA2) $(IMAGE4K_OBJS) $(DEPS) $(TARGETS)
