#include <stdio.h>
#include <string.h>

int main(void) {
    char s[] = "hello";
    char *p = "world";
    printf("%s %s %d\n", s, p, (int)sizeof(s));
    printf("%lu\n", strlen(s));
    printf("%d\n", strcmp(s, "hello"));
    printf("%c%c\n", *(p + 1), p[2]);
    return 0;
}
