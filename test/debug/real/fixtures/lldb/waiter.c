// A program that stays up, for the lldb-dap tests to attach to and to run
// in a terminal: it says the word it is told first (none, its input
// closed), then counts a tick at a time.
#include <stdio.h>
#include <unistd.h>

static int tick(int count) {
  int next = count + 1; // BP:tick
  return next;
}

int main(void) {
  int count = 0;
  char word[64];
  if (scanf("%63s", word) == 1) {
    printf("heard %s\n", word);
    fflush(stdout);
  }
  for (;;) {
    count = tick(count);
    usleep(50 * 1000);
  }
  return 0;
}
