/* libpg_query's pg_config.h assumes the C library declares strlcpy, which
 * glibc does only from 2.38. build.zig force-includes this header, and links
 * strlcpy_compat.c, when the host glibc is older. */
#ifndef SQLZ_STRLCPY_COMPAT_H
#define SQLZ_STRLCPY_COMPAT_H

#include <stddef.h>

size_t strlcpy(char *dst, const char *src, size_t size);

#endif
