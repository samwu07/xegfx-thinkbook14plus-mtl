#include <stdio.h>
#include <stdint.h>
#include <time.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC_RAW,&t); return t.tv_sec+t.tv_nsec*1e-9; }
int main(void){
  for (int r=0;r<8;r++){
    uint64_t n=400000000ull, x=3;   /* 4 dependent imul (3 cycles each) per iteration */
    double t0=now();
    __asm__ volatile("1: imul %0, %0\n imul %0, %0\n imul %0, %0\n imul %0, %0\n dec %1\n jnz 1b" : "+r"(x), "+r"(n));
    double dt=now()-t0;
    printf("run %d: %.2f GHz (%.2f s)\n", r, 400e6*4*3/dt/1e9, dt);
  }
  return 0;
}
