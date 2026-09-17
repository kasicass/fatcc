#include <stdio.h>

int main(void) {
    int a[5];
    int i;
    for (i = 0; i < 5; i++) {
        a[i] = i * i;
    }
    int sum = 0;
    for (i = 0; i < 5; i++) {
        sum += a[i];
    }
    printf("%d %d %d\n", a[0], a[4], sum);

    int b[3] = {1, 2, 3};
    printf("%d %d %d\n", b[0], b[1], b[2]);
    return 0;
}
