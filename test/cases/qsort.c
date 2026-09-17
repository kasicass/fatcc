#include <stdio.h>
#include <stdlib.h>

int cmp_int(const void *a, const void *b) {
    int x = *(const int *)a;
    int y = *(const int *)b;
    if (x < y) return -1;
    if (x > y) return 1;
    return 0;
}

int main(void) {
    int a[6] = {5, 2, 9, 1, 7, 3};
    int i;
    qsort(a, 6, sizeof(int), cmp_int);
    for (i = 0; i < 6; i++) {
        printf("%d ", a[i]);
    }
    printf("\n");

    int key = 7;
    int *p = bsearch(&key, a, 6, sizeof(int), cmp_int);
    printf("%d\n", p ? *p : -1);
    return 0;
}
