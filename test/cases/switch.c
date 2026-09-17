#include <stdio.h>

int classify(int x) {
    switch (x) {
        case 0: return 100;
        case 1:
        case 2: return 200;
        case 5: return 500;
        default: return -1;
    }
}

int main(void) {
    int i;
    int sum = 0;
    for (i = 0; i < 7; i++) {
        switch (i) {
            case 0: sum += 1; break;
            case 1: sum += 10; break;
            case 3: sum += 100; break;
            default: sum += 1000; break;
        }
    }
    printf("%d\n", sum);
    printf("%d %d %d %d\n", classify(0), classify(2), classify(5), classify(9));
    return 0;
}
