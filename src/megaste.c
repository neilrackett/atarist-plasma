#include <stdint.h>

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

int is_megaste(void)
{
  long mch = 0;
  return get_cookie(COOKIE_MCH, &mch) && mch == MCH_MEGA_STE;
}

void megaste_enable_16mhz_cache(void)
{
  *(volatile uint8_t *)0xFFFF8E21 = 0x03; /* Mega STE 16MHz with cache */
}
