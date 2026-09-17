#include <stdio.h>

int main(void) {
    int a = 6;
    int b = 4;
    printf("%d %d %d %d %d\n", a + b, a - b, a * b, a / b, a % b);
    printf("%d %d\n", a > b, a == b);
    int c = 1;
    c += 5;
    c *= 2;
    c -= 3;
    printf("%d\n", c);
    printf("%d\n", -a + +b);
    return 0;
}
