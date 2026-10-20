#include "strlcpy_compat.h"

/* Copies at most size - 1 bytes and always terminates when size > 0. Returns
 * strlen(src), so callers detect truncation by comparing against size. */
size_t strlcpy(char *dst, const char *src, size_t size) {
    size_t length = 0;
    while (src[length] != '\0') length++;
    if (size != 0) {
        size_t copy = length < size - 1 ? length : size - 1;
        for (size_t i = 0; i < copy; i++) dst[i] = src[i];
        dst[copy] = '\0';
    }
    return length;
}
