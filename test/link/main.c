#include <stdio.h>

int square(int x);
void say(const char *s);

int main(void) {
    say("linked");
    printf("%d\n", square(7));
    return 0;
}
