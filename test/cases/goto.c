#include <stdio.h>

int main(void) {
    int i = 0;
loop:
    if (i < 3) {
        printf("%d", i);
        i++;
        goto loop;
    }
    printf("\n");
    return 0;
}
