#include <stdio.h>

int counter = 5;

int add(int x) {
    counter += x;
    return counter;
}

int main(void) {
    printf("%d\n", add(3));
    printf("%d\n", add(4));
    return 0;
}
