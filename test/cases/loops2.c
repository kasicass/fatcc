#include <stdio.h>

int main(void) {
    int i;
    int sum = 0;
    for (i = 0; i < 10; i++) {
        if (i % 2 == 0) continue;
        if (i > 7) break;
        sum += i;
    }
    int j = 0;
    do { j++; } while (j < 3);
    int x = 5, y = 3;
    printf("%d %d %d %d %d\n", sum, j, x & y, x | y, x ^ y);
    printf("%d %d %d\n", x << 1, x >> 1, ~x);
    printf("%d %d\n", (x > 2) && (y < 5), (x < 2) || (y > 5));
    int a = 0;
    int b = a++;
    int c = ++a;
    printf("%d %d %d\n", a, b, c);
    return 0;
}
