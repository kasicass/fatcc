#include <stdio.h>

int main(void) {
    int x = 42;
    int *p = &x;
    *p = 7;
    printf("%d %d\n", x, *p);
    int a = 1;
    int b = 2;
    int *q = &a;
    *q = *q + 10;
    printf("%d %d\n", a, b);
    int **pp = &p;
    **pp = 99;
    printf("%d\n", x);
    return 0;
}
