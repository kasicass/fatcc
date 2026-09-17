#include <stdio.h>

int add(int a, int b) { return a + b; }
int sub(int a, int b) { return a - b; }
int mul(int a, int b) { return a * b; }

int apply(int (*op)(int, int), int a, int b) {
    return op(a, b);
}

int main(void) {
    int (*f)(int, int) = add;
    printf("%d %d\n", f(3, 4), apply(sub, 10, 3));
    f = mul;
    printf("%d\n", f(5, 6));

    int (*ops[3])(int, int);
    ops[0] = add;
    ops[1] = sub;
    ops[2] = mul;
    printf("%d %d %d\n", ops[0](1, 2), ops[1](5, 2), ops[2](3, 3));
    return 0;
}
