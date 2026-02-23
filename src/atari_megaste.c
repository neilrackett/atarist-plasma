#include <stdint.h>
#include <mint/osbind.h>
#include <mint/cookie.h>

#define MCH_MEGA_STE 0x00010010L

int is_megaste(void)
{
  long mch = 0;
  if (C_FOUND != Getcookie(C__MCH, &mch))
    return 0;
  return mch == MCH_MEGA_STE;
}

int megaste_enable_16mhz_cache(void)
{
  if (is_megaste())
  {
    *(volatile uint8_t *)0xFFFF8E21 = 0x03;
    return 0;
  }

  return 1;
}
