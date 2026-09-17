#include <stdio.h>
#include "mylib.h"

#define N 5
#define SQUARE(x) ((x) * (x))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define STR(x) #x
#define XSTR(x) STR(x)
#define CONCAT(a, b) a##b
#define SUM(...) sum_all(__VA_ARGS__, 0)

#if N > 3
#define MSG "big"
#else
#define MSG "small"
#endif

#ifdef MSG
#define HAS_MSG 1
#else
#define HAS_MSG 0
#endif

#ifndef UNDEFINED
#define GUARD 42
#endif

int sum_all(int first, ...) {
    return first + 100;
}

int triple(int x) {
    return x * 3;
}

int main(void) {
    int xy = 9;
    printf("%d %d %d\n", N, SQUARE(N), MAX(3, 7));
    printf("%s %d %d\n", MSG, HAS_MSG, GUARD);
    printf("%d\n", triple(DOUBLE(3)));
    printf("%s %s\n", STR(hello), XSTR(N));
    printf("%d\n", CONCAT(x, y));
    printf("%d\n", SUM(7));
    return 0;
}
