#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

int main(void) {
    char buf[64];
    strcpy(buf, "hello");
    strcat(buf, ", world");
    printf("%s %lu\n", buf, strlen(buf));
    printf("%d %d %d\n", strcmp("abc", "abd"), strncmp("abc", "abd", 2), memcmp("ab", "ab", 2));
    printf("%c %c\n", *strchr(buf, 'w'), *strrchr(buf, 'l'));

    char *p = malloc(16);
    strcpy(p, "malloced");
    printf("%s\n", p);
    free(p);

    int *arr = calloc(4, sizeof(int));
    arr[0] = 7;
    arr[3] = 9;
    printf("%d %d\n", arr[0], arr[3]);

    printf("%d %d %d %d\n", isalpha('a'), isdigit('5'), toupper('x'), tolower('Y'));
    return 0;
}
