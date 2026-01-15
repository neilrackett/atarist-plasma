CC      = m68k-atari-mint-gcc
AS      = m68k-atari-mint-as
LIBCMINI = /freemint/libcmini/lib
CFLAGS = -O2 -fomit-frame-pointer -s -std=gnu99 -I/freemint/libcmini/include -m68000
LDFLAGS = -s -nostdlib -L$(LIBCMINI) $(LIBCMINI)/crt0.o -m68000
LIBS    = -lcmini -lgcc -lm

SRCDIR = src
BUILDDIR = build
OBJDIR   = obj
OBJS_PLASMA1 = $(OBJDIR)/plasma1.o $(OBJDIR)/render_scanlines.o
OBJS_PLASMA2 = $(OBJDIR)/plasma2.o $(OBJDIR)/render_scanlines_rows.o
TARGETS = $(BUILDDIR)/PLASMA1.TOS $(BUILDDIR)/PLASMA2.TOS
DEPS = $(OBJS_PLASMA1:.o=.d) $(OBJS_PLASMA2:.o=.d)

all: $(TARGETS)

$(BUILDDIR)/PLASMA1.TOS: $(OBJS_PLASMA1)
	@mkdir -p $(BUILDDIR)
	$(CC) $(LDFLAGS) $(OBJS_PLASMA1) $(LIBS) -o $@

$(BUILDDIR)/PLASMA2.TOS: $(OBJS_PLASMA2)
	@mkdir -p $(BUILDDIR)
	$(CC) $(LDFLAGS) $(OBJS_PLASMA2) $(LIBS) -o $@

$(OBJDIR)/%.o: ${SRCDIR}/%.c
	@mkdir -p $(OBJDIR)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(OBJDIR)/%.o: ${SRCDIR}/%.s
	@mkdir -p $(OBJDIR)
	$(AS) $< -o $@

.PHONY: all clean

-include $(DEPS)

clean:
	rm -f $(OBJS_PLASMA1) $(OBJS_PLASMA2) $(DEPS) \
		$(BUILDDIR)/PLASMA1.TOS $(BUILDDIR)/PLASMA2.TOS
