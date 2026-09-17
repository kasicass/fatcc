#include <stdio.h>

struct Inner {
    int a;
    int b;
};

struct Outer {
    struct Inner in;
    int c;
};

union U {
    int i;
    char c[4];
};

int main(void) {
    struct Outer o;
    o.in.a = 1;
    o.in.b = 2;
    o.c = 3;
    printf("%d %d %d %d\n", o.in.a, o.in.b, o.c, (int)sizeof(struct Outer));

    union U u;
    u.i = 0;
    u.c[0] = 65;
    u.c[1] = 66;
    printf("%d %d %d\n", u.c[0], u.c[1], (int)sizeof(union U));
    return 0;
}
