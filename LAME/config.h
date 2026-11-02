/* iPhone/iPad derlemesi için elle hazırlanmış LAME ayarları (configure çalıştırılmadan). */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_MEMCPY 1
#define HAVE_STRCHR 1
#define PROTOTYPES 1

typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

#define TAKEHIRO_IEEE754_HACK 1
#define USE_FAST_LOG 1
#define LAME_LIBRARY_BUILD 1
#define PACKAGE_VERSION "3.100"

#endif
