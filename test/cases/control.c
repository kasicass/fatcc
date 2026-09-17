#include <stdio.h>

int main(void) {
    int sum = 0;
    for (int i = 1; i <= 10; i = i + 1) {
        sum += i;
    }
    int j = 0;
    while (j < 5) {
        j++;
    }
    int k = 10;
    if (k > 5) {
        k = 1;
    } else {
        k = 2;
    }
    int n = 3;
    int r = n > 2 ? 100 : 200;
    printf("%d %d %d %d\n", sum, j, k, r);
    return 0;
}
