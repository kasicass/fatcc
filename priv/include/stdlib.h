#ifndef _FAT_STDLIB_H
#define _FAT_STDLIB_H

int atoi(const char *s);
long atol(const char *s);
int abs(int x);
long labs(long x);
void exit(int status);
void abort(void);
int rand(void);
void srand(unsigned int seed);
void *malloc(unsigned long size);
void *calloc(unsigned long n, unsigned long size);
void *realloc(void *p, unsigned long size);
void free(void *p);

#endif
