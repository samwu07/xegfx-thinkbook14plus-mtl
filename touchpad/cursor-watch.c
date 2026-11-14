// cursor-watch: the real cursor position every ~1 ms for N seconds; reports every step larger than JUMP pixels with the
// positions before/after and the time, plus a histogram of step sizes. No Input Monitoring needed (CGEventCreate(NULL)
// only reads the location). Swipe on the touchpad while it runs, and try to make the cursor fly.
//   clang -O2 -o cursor-watch cursor-watch.c -framework CoreGraphics -framework CoreFoundation && ./cursor-watch [seconds] [jump_px]
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
int main(int argc, char **argv) {
  int secs = argc > 1 ? atoi(argv[1]) : 30; if (secs < 1) secs = 30;
  double jump = argc > 2 ? atof(argv[2]) : 120;
  unsigned hist[8] = {0}; unsigned polls = 0, moved = 0, jumps = 0;
  CGEventRef e = CGEventCreate(NULL); CGPoint p = CGEventGetLocation(e); CFRelease(e);
  double t0 = now_ms(), tend = t0 + secs * 1000.0, tprev = t0;
  CGRect b = CGDisplayBounds(CGMainDisplayID());
  printf("display %.0fx%.0f pt; watching %d s, jump = step > %.0f pt in one poll. Swipe now.\n", b.size.width, b.size.height, secs, jump); fflush(stdout);
  while (now_ms() < tend) {
    usleep(1000);
    e = CGEventCreate(NULL); CGPoint q = CGEventGetLocation(e); CFRelease(e);
    double t = now_ms(); polls++;
    double d = hypot(q.x - p.x, q.y - p.y);
    if (d > 0) {
      moved++;
      int h = d < 2 ? 0 : d < 5 ? 1 : d < 10 ? 2 : d < 20 ? 3 : d < 50 ? 4 : d < 120 ? 5 : d < 300 ? 6 : 7; hist[h]++;
      if (d > jump) { jumps++; if (jumps <= 30) printf("%8.3f s  JUMP %6.1f pt in %.1f ms: (%.0f,%.0f) -> (%.0f,%.0f)\n", (t - t0) / 1000, d, t - tprev, p.x, p.y, q.x, q.y); }
    }
    p = q; tprev = t;
  }
  printf("%u polls, cursor moved in %u; steps: <2 %u, <5 %u, <10 %u, <20 %u, <50 %u, <120 %u, <300 %u, >=300 %u; jumps > %.0f pt: %u\n",
         polls, moved, hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6], hist[7], jump, jumps);
  return 0;
}
