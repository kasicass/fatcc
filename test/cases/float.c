#include <stdio.h>

double average(double a, double b) {
    return (a + b) / 2.0;
}

int main(void) {
    double x = 3.5;
    double y = 2.0;
    printf("%.2f\n", x + y);
    printf("%.2f\n", average(4.0, 9.0));
    float f = 1.25f;
    printf("%.2f\n", (double)f * 4.0);
    printf("%d\n", (int)(x + y));
    int i = 3;
    printf("%.2f\n", (double)i / 2.0);
    printf("%d %d\n", x > y, x < y);
    printf("%.1f\n", 10.0 / 4.0);
    return 0;
}
