#ifndef _FAT_ASSERT_H
#define _FAT_ASSERT_H

void abort(void);
#define assert(e) ((e) ? (void)0 : abort())

#endif
