/*
 * First-party Windows compatibility for the libFLAC UTF-8 file API.
 *
 * The libFLAC 1.4.3 headers expose these wrappers on Windows, but the
 * vendored library sources do not include their companion implementation.
 * Keep the vendor tree unchanged and translate paths through the Unicode CRT.
 */

#include "share/win_utf8_io.h"

#include <errno.h>
#include <stdlib.h>
#include <wchar.h>

static wchar_t *parso_wide_from_utf8(const char *utf8)
{
    int length;
    wchar_t *wide;

    if (utf8 == NULL) {
        return NULL;
    }

    length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1,
                                 NULL, 0);
    if (length <= 0) {
        return NULL;
    }

    wide = (wchar_t *)malloc((size_t)length * sizeof(*wide));
    if (wide == NULL) {
        return NULL;
    }

    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1,
                            wide, length) <= 0) {
        free(wide);
        return NULL;
    }
    return wide;
}

int vfprintf_utf8(FILE *stream, const char *format, va_list arguments)
{
    return vfprintf(stream, format, arguments);
}

int printf_utf8(const char *format, ...)
{
    int result;
    va_list arguments;

    va_start(arguments, format);
    result = vfprintf_utf8(stdout, format, arguments);
    va_end(arguments);
    return result;
}

int fprintf_utf8(FILE *stream, const char *format, ...)
{
    int result;
    va_list arguments;

    va_start(arguments, format);
    result = vfprintf_utf8(stream, format, arguments);
    va_end(arguments);
    return result;
}

FILE *fopen_utf8(const char *filename, const char *mode)
{
    FILE *file;
    wchar_t *wide_filename;
    wchar_t *wide_mode;

    wide_filename = parso_wide_from_utf8(filename);
    wide_mode = parso_wide_from_utf8(mode);
    if (wide_filename == NULL || wide_mode == NULL) {
        free(wide_filename);
        free(wide_mode);
        errno = EINVAL;
        return NULL;
    }

    file = _wfopen(wide_filename, wide_mode);
    free(wide_filename);
    free(wide_mode);
    return file;
}

int stat64_utf8(const char *path, struct __stat64 *buffer)
{
    int result;
    wchar_t *wide_path;

    wide_path = parso_wide_from_utf8(path);
    if (wide_path == NULL) {
        errno = EINVAL;
        return -1;
    }
    result = _wstat64(wide_path, buffer);
    free(wide_path);
    return result;
}

int chmod_utf8(const char *filename, int pmode)
{
    int result;
    wchar_t *wide_filename;

    wide_filename = parso_wide_from_utf8(filename);
    if (wide_filename == NULL) {
        errno = EINVAL;
        return -1;
    }
    result = _wchmod(wide_filename, pmode);
    free(wide_filename);
    return result;
}

int utime_utf8(const char *filename, struct utimbuf *times)
{
    int result;
    wchar_t *wide_filename;

    wide_filename = parso_wide_from_utf8(filename);
    if (wide_filename == NULL) {
        errno = EINVAL;
        return -1;
    }
    result = _wutime(wide_filename, (struct _utimbuf *)times);
    free(wide_filename);
    return result;
}

int unlink_utf8(const char *filename)
{
    int result;
    wchar_t *wide_filename;

    wide_filename = parso_wide_from_utf8(filename);
    if (wide_filename == NULL) {
        errno = EINVAL;
        return -1;
    }
    result = _wunlink(wide_filename);
    free(wide_filename);
    return result;
}

int rename_utf8(const char *oldname, const char *newname)
{
    int result;
    wchar_t *wide_oldname;
    wchar_t *wide_newname;

    wide_oldname = parso_wide_from_utf8(oldname);
    wide_newname = parso_wide_from_utf8(newname);
    if (wide_oldname == NULL || wide_newname == NULL) {
        free(wide_oldname);
        free(wide_newname);
        errno = EINVAL;
        return -1;
    }

    result = _wrename(wide_oldname, wide_newname);
    free(wide_oldname);
    free(wide_newname);
    return result;
}
