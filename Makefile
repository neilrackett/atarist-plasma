CC      = m68k-atari-mint-gcc
AS      = m68k-atari-mint-as
# CFLAGS  = -O2 -fomit-frame-pointer -m68000
# LDFLAGS = -m68000
LIBCMINI = /freemint/libcmini/lib
CFLAGS = -O2 -fomit-frame-pointer -s -std=gnu99 -I/freemint/libcmini/include -m68000
LDFLAGS = -s -nostdlib -L$(LIBCMINI) $(LIBCMINI)/crt0.o -m68000
LIBS    = -lcmini -lgcc -lm

SRCDIR = src
BUILDDIR = build
OBJDIR   = obj
OBJS = $(OBJDIR)/main.o $(OBJDIR)/render_scanlines.o
TARGET = PLASMA.TOS
DEPS = $(OBJS:.o=.d)

all: $(TARGET)

$(TARGET): $(OBJS)
	@mkdir -p $(BUILDDIR)
	$(CC) $(LDFLAGS) $(OBJS) $(LIBS) -o $(BUILDDIR)/$(TARGET)

$(OBJDIR)/%.o: ${SRCDIR}/%.c
	@mkdir -p $(OBJDIR)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(OBJDIR)/%.o: ${SRCDIR}/%.s
	@mkdir -p $(OBJDIR)
	$(AS) $< -o $@

.PHONY: all clean

-include $(DEPS)

clean:
	rm -f $(OBJS) $(DEPS) $(BUILDDIR)/$(TARGET)
