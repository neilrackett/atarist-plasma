#include <osbind.h>
#include <stdio.h>
#include <stdint.h>

enum
{
  SCREEN_HEIGHT = 200,
  SCREEN_WIDTH = 320,
  COLOR_REGS = 16,
  PLANES = 4,
  WORDS_PER_LINE = (SCREEN_WIDTH / 16) * PLANES,
  COLUMN_COUNT = 14,
  COLUMN_WIDTH_PIXELS = 15,
  SQUARE_WIDTH_PIXELS = COLUMN_COUNT * COLUMN_WIDTH_PIXELS,
  SQUARE_LEFT = (SCREEN_WIDTH - SQUARE_WIDTH_PIXELS) / 2,
  SQUARE_RIGHT = SQUARE_LEFT + SQUARE_WIDTH_PIXELS,
  PALETTE_ROWS = 20,
  PLASMA_FRAME_COUNT = 240
};

const uint16_t *plasma_palette_rows;
static uint16_t screen_buffer[SCREEN_HEIGHT * WORDS_PER_LINE];

#include "plasma2_frames.inc"

/* Storage for original screen resolution and palette */
int original_resolution;
uint16_t original_palette[COLOR_REGS];

extern void render_scanlines_rows();

#define COOKIE_JAR_ADDRESS 0x5a0
#define COOKIE_MCH 0x5f4d4348L
#define MCH_MEGA_STE 0x00010010L

static int get_cookie(long id, long *value)
{
  long *jar = *(long **)COOKIE_JAR_ADDRESS;

  if (!jar)
    return 0;

  while (jar[0])
  {
    if (jar[0] == id)
    {
      if (value)
        *value = jar[1];
      return 1;
    }
    jar += 2;
  }

  return 0;
}

static int is_megaste(void)
{
  long mch = 0;
  return get_cookie(COOKIE_MCH, &mch) && mch == MCH_MEGA_STE;
}

void ikbd_off()
{
  Cconws("\033f");  /* Hide cursor */
  Bconout(4, 0x12); /* Disable mouse */
  Bconout(4, 0x1a); /* Disable joystick */
}

void ikbd_on()
{
  Bconout(4, 0x08); /* Enable mouse */
  Cconws("\033e");  /* Show cursor */
}

static void save_palette(uint16_t *palette)
{
  int i;
  for (i = 0; i < COLOR_REGS; i++)
  {
    palette[i] = (uint16_t)Setcolor(i, -1);
  }
}

static void clear_screen_buffer(uint16_t *buffer)
{
  int i;
  for (i = 0; i < SCREEN_HEIGHT * WORDS_PER_LINE; i++)
  {
    buffer[i] = 0;
  }
}

static void draw_square_to_buffer(uint16_t *buffer)
{
  int x, y;
  clear_screen_buffer(buffer);

  for (y = 0; y < SCREEN_HEIGHT; y++)
  {
    uint16_t *line = buffer + (y * WORDS_PER_LINE);
    for (x = SQUARE_LEFT; x < SQUARE_RIGHT; x++)
    {
      int column = (x - SQUARE_LEFT) / COLUMN_WIDTH_PIXELS;
      int color_index = 1 + column;
      int word_index = x / 16;
      uint16_t bit = (uint16_t)(0x8000 >> (x & 15));
      uint16_t *word_base = line + (word_index * PLANES);

      if (color_index & 1)
        word_base[0] |= bit;
      if (color_index & 2)
        word_base[1] |= bit;
      if (color_index & 4)
        word_base[2] |= bit;
      if (color_index & 8)
        word_base[3] |= bit;
    }
  }
}

static void blit_buffer_to_screen(const uint16_t *buffer, uint16_t *screen_base)
{
  int i;
  for (i = 0; i < SCREEN_HEIGHT * WORDS_PER_LINE; i++)
  {
    screen_base[i] = buffer[i];
  }
}

static void clear_palette()
{
  int i;
  for (i = 1; i < COLOR_REGS - 1; i++)
    Setcolor(i, 0x000);
}

static void apply_palette_frame(int frame_index)
{
  plasma_palette_rows = &plasma_frames[frame_index][0][0];
}

int main()
{
  void *old_stack = (void *)Super(0);
  void *old_screen = (void *)Physbase();

  if (is_megaste())
    *(volatile uint8_t *)0xFFFF8E21 = 0x03; /* Mega STE 16MHz with cache */

  /* Store original screen resolution and palette */
  original_resolution = Getrez();

  /* Read current palette via OS call */
  save_palette(original_palette);

  /* Switch to low resolution via OS call */
  Setscreen((void *)-1, (void *)-1, 0);

  /* Colours 0 and 15 are reseved for background and text */
  Setcolor(0, 0x000);
  Setcolor(15, 0x555);

  /* Center "Loading..." on a 40x25 low-res console */
  Cconws("\033Y");
  Bconout(2, 32 + 12);
  Bconout(2, 32 + 13);
  printf("Are you ready?\n");

  draw_square_to_buffer(screen_buffer);

  /* Hide coloured bars until render loop */
  clear_palette();

  blit_buffer_to_screen(screen_buffer, (uint16_t *)Physbase());

  ikbd_off();

  /* 2. CLEAR KEYBOARD BUFFER */
  /* This prevents the "instant exit" bug */
  while (Cconis())
    Cnecin();

  apply_palette_frame(0);

  /* 3. RENDER LOOP */
  {
    int frame_index = 0;
    while (1)
    {
      Vsync();
      render_scanlines_rows();

      frame_index = (frame_index + 1) % PLASMA_FRAME_COUNT;
      apply_palette_frame(frame_index);

      if (Cconis())
      {
        int ch = Cnecin();
        int ascii = ch & 0xff;
        if (ascii == 27)
        {
          break;
        }
      }
    }
  }

  ikbd_on();

  /* Restore original screen resolution and palette */
  Setscreen(old_screen, old_screen, original_resolution);
  Setpalette(original_palette);
  Super(old_stack);
  return 0;
}
