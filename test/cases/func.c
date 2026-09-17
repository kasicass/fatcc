#include <stdio.h>

long fact(long n) {
    if (n < 2) {
        return 1;
    }
    return n * fact(n - 1);
}

int fib(int n) {
    if (n < 2) {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

int main(void) {
    printf("%ld %d\n", fact(10), fib(10));
    return 0;
}
