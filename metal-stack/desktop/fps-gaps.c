// fps-gaps: the time between frames that reach the Intel panel (debug.nvaccel_iop_ok_h4), read about every 2 ms for
// N seconds (default 15), as a histogram of gaps. Which clock paces WindowServer: ~33 ms gaps = a 30 Hz beat, a mix of
// ~17 and ~33 ms = a 60 Hz refresh with missed frames. No sudo. Drag a window in circles while it runs.
//   clang -O2 -o fps-gaps fps-gaps.c && ./fps-gaps [seconds]
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <time.h>
static uint64_t now_us(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000; }
static long long frames(void) { long long v = 0; size_t l = sizeof v; if (sysctlbyname("debug.nvaccel_iop_ok_h4", &v, &l, NULL, 0)) return -1; return v; }
int main(int argc, char **argv) {
  int secs = argc > 1 ? atoi(argv[1]) : 15; if (secs < 1) secs = 15;
  long long f = frames(); if (f < 0) { puts("no debug.nvaccel_iop_ok_h4: the Intel desktop is not running"); return 1; }
  printf("measuring frame gaps for %d s -- drag a window in circles now\n", secs); fflush(stdout);
  unsigned hist[20] = {0}; unsigned n = 0, multi = 0; uint64_t t0 = now_us(), last = 0, end = t0 + (uint64_t)secs * 1000000;
  while (now_us() < end) {
    usleep(2000);
    long long g = frames(); if (g <= f) continue;
    uint64_t t = now_us();
    if (g - f > 1) multi++;
    if (last) { unsigned ms = (unsigned)((t - last + 500) / 1000); unsigned b = ms / 5; if (b > 19) b = 19; hist[b]++; n++; }
    last = t; f = g;
  }
  printf("%u gaps (%u reads saw 2+ frames at once)\n", n, multi);
  for (int b = 0; b < 20; b++) if (hist[b]) printf("  %3d-%3d ms %s %5u  %s\n", b * 5, b == 19 ? 999 : b * 5 + 4, b == 19 ? "+" : " ", hist[b],
      (b == 3 ? "<- one 60 Hz refresh (16.7)" : b == 6 ? "<- two refreshes (33.3) = 30 Hz" : b == 10 ? "<- three (50)" : ""));
  return 0;
}
