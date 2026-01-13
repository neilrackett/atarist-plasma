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
  GRID_CELLS = COLUMN_COUNT * SCREEN_HEIGHT
};

uint16_t plasma_colors[SCREEN_HEIGHT * COLOR_REGS];
static uint16_t screen_buffer[SCREEN_HEIGHT * WORDS_PER_LINE];
static const uint8_t corner_tl[3] = {0, 0, 0};
static const uint8_t corner_tr[3] = {15, 0, 15};
static const uint8_t corner_bl[3] = {0, 15, 15};
static const uint8_t corner_br[3] = {15, 15, 0};
static const uint8_t edge_top[3] = {15, 0, 0};
static const uint8_t edge_bottom[3] = {0, 15, 0};
static const uint8_t edge_left[3] = {0, 0, 15};
static const uint8_t edge_right[3] = {15, 15, 15};

/* Storage for original screen resolution and palette */
int original_resolution;
uint16_t original_palette[COLOR_REGS];

extern void render_scanlines();

#define COOKIE_JAR_ADDRESS 0x5a0
#define COOKIE_MCH 0x5f4d4348L
#define MCH_MEGA_STE 0x0005L

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

static inline uint16_t swiz(int v)
{
  v &= 15;
  return (uint16_t)(((v & 1) << 3) | (v >> 1));
}

uint16_t to_ste(int r, int g, int b)
{
  return (swiz(r) << 8) | (swiz(g) << 4) | swiz(b);
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

static void morton3_decode(uint16_t code, uint8_t *r, uint8_t *g, uint8_t *b)
{
  uint8_t rr = 0;
  uint8_t gg = 0;
  uint8_t bb = 0;
  int i;

  for (i = 0; i < 4; i++)
  {
    rr |= (uint8_t)(((code >> (3 * i)) & 1) << i);
    gg |= (uint8_t)(((code >> (3 * i + 1)) & 1) << i);
    bb |= (uint8_t)(((code >> (3 * i + 2)) & 1) << i);
  }

  *r = rr;
  *g = gg;
  *b = bb;
}

static uint16_t morton2_encode(uint16_t x, uint16_t y)
{
  uint16_t code = 0;
  int i;

  for (i = 0; i < 8; i++)
  {
    code |= (uint16_t)(((x >> i) & 1) << (2 * i));
    code |= (uint16_t)(((y >> i) & 1) << (2 * i + 1));
  }

  return code;
}

static void hsv_to_rgb_4bit(uint8_t h, uint8_t s, uint8_t v, int *r, int *g, int *b)
{
  uint8_t region = h / 43;
  uint8_t remainder = (uint8_t)((h - (region * 43)) * 6);
  uint16_t p = (uint16_t)(v * (255 - s)) / 255;
  uint16_t q = (uint16_t)(v * (255 - ((s * remainder) / 255))) / 255;
  uint16_t t = (uint16_t)(v * (255 - ((s * (255 - remainder)) / 255))) / 255;
  uint16_t rr;
  uint16_t gg;
  uint16_t bb;

  switch (region)
  {
  case 0:
    rr = v;
    gg = t;
    bb = p;
    break;
  case 1:
    rr = q;
    gg = v;
    bb = p;
    break;
  case 2:
    rr = p;
    gg = v;
    bb = t;
    break;
  case 3:
    rr = p;
    gg = q;
    bb = v;
    break;
  case 4:
    rr = t;
    gg = p;
    bb = v;
    break;
  default:
    rr = v;
    gg = p;
    bb = q;
    break;
  }

  *r = (int)((rr * 15 + 127) / 255);
  *g = (int)((gg * 15 + 127) / 255);
  *b = (int)((bb * 15 + 127) / 255);
}

static void update_plasma_colors(int mode)
{
  int x, y;
  uint8_t center[3];
  int max_morton = morton2_encode(COLUMN_COUNT - 1, SCREEN_HEIGHT - 1);

  center[0] = (uint8_t)((edge_top[0] + edge_bottom[0] + edge_left[0] + edge_right[0] + 2) / 4);
  center[1] = (uint8_t)((edge_top[1] + edge_bottom[1] + edge_left[1] + edge_right[1] + 2) / 4);
  center[2] = (uint8_t)((edge_top[2] + edge_bottom[2] + edge_left[2] + edge_right[2] + 2) / 4);

  for (y = 0; y < SCREEN_HEIGHT; y++)
  {
    int row_offset = y * COLOR_REGS;
    int v = (y * 256) / (SCREEN_HEIGHT - 1);
    int v_half = (v <= 128) ? (v * 2) : ((v - 128) * 2);
    int inv_v = 256 - v_half;

    /* Palette 0 reserved for background */
    plasma_colors[row_offset + 0] = to_ste(0, 0, 0);

    for (x = 0; x < COLUMN_COUNT; x++)
    {
      int u = (x * 256) / (COLUMN_COUNT - 1);
      int r;
      int g;
      int b;

      if (mode == 1)
      {
        int inv_u = 256 - u;
        int inv_v_full = 256 - v;
        int w_tl = inv_u * inv_v_full;
        int w_tr = u * inv_v_full;
        int w_bl = inv_u * v;
        int w_br = u * v;
        r = (corner_tl[0] * w_tl + corner_tr[0] * w_tr +
             corner_bl[0] * w_bl + corner_br[0] * w_br + 32768) >>
            16;
        g = (corner_tl[1] * w_tl + corner_tr[1] * w_tr +
             corner_bl[1] * w_bl + corner_br[1] * w_br + 32768) >>
            16;
        b = (corner_tl[2] * w_tl + corner_tr[2] * w_tr +
             corner_bl[2] * w_bl + corner_br[2] * w_br + 32768) >>
            16;
      }
      else
      {
        if (mode == 3)
        {
          int key = morton2_encode((uint16_t)x, (uint16_t)y);
          uint16_t code = (uint16_t)((key * 4095) / max_morton);
          uint8_t rr;
          uint8_t gg;
          uint8_t bb;
          morton3_decode(code, &rr, &gg, &bb);
          r = rr;
          g = gg;
          b = bb;
        }
        else if (mode == 2)
        {
          int h = (y * 255) / (SCREEN_HEIGHT - 1);
          int h_shift = (x * 255) / (COLUMN_COUNT - 1);
          int hue = (h + (h_shift / 3)) & 255;
          int dist_x2 = abs((2 * x) - (COLUMN_COUNT - 1));
          int dist_y2 = abs((2 * y) - (SCREEN_HEIGHT - 1));
          int sat = 255 - (dist_x2 * 255) / (COLUMN_COUNT - 1);
          int val = 128 + ((127 * ((SCREEN_HEIGHT - 1) - dist_y2)) / (SCREEN_HEIGHT - 1));
          hsv_to_rgb_4bit((uint8_t)hue, (uint8_t)sat, (uint8_t)val, &r, &g, &b);
        }
        else
        {
          int u_half = (u <= 128) ? (u * 2) : ((u - 128) * 2);
          int inv_u = 256 - u_half;
          const uint8_t *c_tl;
          const uint8_t *c_tr;
          const uint8_t *c_bl;
          const uint8_t *c_br;
          int w_tl;
          int w_tr;
          int w_bl;
          int w_br;

          if (v <= 128)
          {
            if (u <= 128)
            {
              c_tl = corner_tl;
              c_tr = edge_top;
              c_bl = edge_left;
              c_br = center;
            }
            else
            {
              c_tl = edge_top;
              c_tr = corner_tr;
              c_bl = center;
              c_br = edge_right;
            }
          }
          else
          {
            if (u <= 128)
            {
              c_tl = edge_left;
              c_tr = center;
              c_bl = corner_bl;
              c_br = edge_bottom;
            }
            else
            {
              c_tl = center;
              c_tr = edge_right;
              c_bl = edge_bottom;
              c_br = corner_br;
            }
          }

          w_tl = inv_u * inv_v;
          w_tr = u_half * inv_v;
          w_bl = inv_u * v_half;
          w_br = u_half * v_half;
          r = (c_tl[0] * w_tl + c_tr[0] * w_tr +
               c_bl[0] * w_bl + c_br[0] * w_br + 32768) >>
              16;
          g = (c_tl[1] * w_tl + c_tr[1] * w_tr +
               c_bl[1] * w_bl + c_br[1] * w_br + 32768) >>
              16;
          b = (c_tl[2] * w_tl + c_tr[2] * w_tr +
               c_bl[2] * w_bl + c_br[2] * w_br + 32768) >>
              16;
        }
      }
      plasma_colors[row_offset + 1 + x] = to_ste(r, g, b);
    }

    for (x = 1 + COLUMN_COUNT; x < COLOR_REGS; x++)
    {
      plasma_colors[row_offset + x] = plasma_colors[row_offset + 0];
    }

    // Palette 15 reserved for text
    plasma_colors[row_offset + COLOR_REGS - 1] = to_ste(2, 2, 2);
  }
}

int main()
{
  void *old_stack = (void *)Super(0);
  void *old_screen = (void *)Physbase();
  int current_mode = 0;
  const int mode_count = 4;

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

  update_plasma_colors(current_mode);

  draw_square_to_buffer(screen_buffer);

  /* Hide coloured bars until render loop */
  int c;
  for (c = 0; c < 16; c++)
    Setcolor(c, 0x000);

  blit_buffer_to_screen(screen_buffer, (uint16_t *)Physbase());

  /* Instructions (bottom-left) */
  Cconws("\033Y");
  Bconout(2, 32 + 22);
  Bconout(2, 32 + 0);
  printf("1-4\n");
  printf("Space\n");
  printf("Esc\n");

  ikbd_off();

  /* 2. CLEAR KEYBOARD BUFFER */
  /* This prevents the "instant exit" bug */
  while (Cconis())
    Cnecin();

  /* 3. RENDER LOOP */
  while (1)
  {
    Vsync();
    render_scanlines();
    if (Cconis())
    {
      int ch = Cnecin();
      int ascii = ch & 0xff;
      if (ascii == '1')
      {
        current_mode = 0;
        update_plasma_colors(current_mode);
      }
      else if (ascii == '2')
      {
        current_mode = 1;
        update_plasma_colors(current_mode);
      }
      else if (ascii == '3')
      {
        current_mode = 2;
        update_plasma_colors(current_mode);
      }
      else if (ascii == '4')
      {
        current_mode = 3;
        update_plasma_colors(current_mode);
      }
      else if (ascii == ' ')
      {
        current_mode = (current_mode + 1) % mode_count;
        update_plasma_colors(current_mode);
      }
      else if (ascii == 27)
      {
        break;
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
