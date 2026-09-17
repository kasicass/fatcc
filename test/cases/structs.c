#include <stdio.h>

struct Point {
    int x;
    int y;
};

typedef struct {
    char name[8];
    int score;
} Player;

enum Color { RED, GREEN, BLUE = 10, YELLOW };

int main(void) {
    struct Point a;
    a.x = 3;
    a.y = 4;
    struct Point b = {10, 20};
    printf("%d %d %d %d\n", a.x, a.y, b.x, b.y);

    struct Point *pp = &a;
    pp->x = 100;
    printf("%d %d\n", a.x, pp->y);
    printf("%d\n", (int)sizeof(struct Point));

    Player p;
    p.score = 42;
    p.name[0] = 'B';
    p.name[1] = 0;
    printf("%s %d %d\n", p.name, p.score, (int)sizeof(Player));

    printf("%d %d %d %d\n", RED, GREEN, BLUE, YELLOW);
    return 0;
}
