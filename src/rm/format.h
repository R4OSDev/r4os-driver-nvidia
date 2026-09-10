/* R4OS-owned, allocation-free integer formatter for the RM/NVKMS OS ABI.
 * This is not libc or Linux printk. No floating point, %n, positional arguments
 * or Linux pointer dereferences. Unsupported formats fail with an empty output.
 * Input scans and actual output storage are bounded to 64 KB per call; field
 * padding is counted without iterating over discarded bytes. */
#ifndef R4NV_FORMAT_H
#define R4NV_FORMAT_H
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>

#define R4NV_FORMAT_LIMIT 65536U
enum r4nv_fmt_length { R4NV_INT, R4NV_CHAR, R4NV_SHORT, R4NV_LONG, R4NV_LLONG, R4NV_SIZE, R4NV_PTRDIFF, R4NV_MAXINT };
struct r4nv_fmt_output {
    char *data;
    size_t capacity, used, scanned;
    unsigned count;
    int failed;
};

static void r4nv_fmt_repeat(struct r4nv_fmt_output *out, char ch, unsigned count)
{
    if (out->failed) return;
    if (count > (unsigned)INT_MAX - out->count) { out->failed = 1; return; }
    out->count += count;
    size_t available = out->capacity == 0 ? 0 : out->capacity - 1 - out->used;
    size_t copied = count < available ? count : available;
    for (size_t i = 0; i < copied; ++i) out->data[out->used++] = ch;
}
static void r4nv_fmt_bytes(struct r4nv_fmt_output *out, const char *text, unsigned count)
{
    if (out->failed) return;
    if (count > (unsigned)INT_MAX - out->count) { out->failed = 1; return; }
    out->count += count;
    size_t available = out->capacity == 0 ? 0 : out->capacity - 1 - out->used;
    size_t copied = count < available ? count : available;
    for (size_t i = 0; i < copied; ++i) out->data[out->used++] = text[i];
}
static unsigned r4nv_fmt_decimal(const char **format, int *failed)
{
    unsigned result = 0;
    while (**format >= '0' && **format <= '9') {
        unsigned digit = (unsigned)(**format - '0');
        if (result > ((unsigned)INT_MAX - digit) / 10U) { *failed = 1; return 0; }
        result = result * 10U + digit;
        ++*format;
    }
    return result;
}
static uint64_t r4nv_fmt_unsigned(va_list *args, enum r4nv_fmt_length length)
{
    switch (length) {
    case R4NV_CHAR: return (unsigned char)va_arg(*args, unsigned int);
    case R4NV_SHORT: return (unsigned short)va_arg(*args, unsigned int);
    case R4NV_LONG: return va_arg(*args, unsigned long);
    case R4NV_LLONG: return va_arg(*args, unsigned long long);
    case R4NV_SIZE: return va_arg(*args, size_t);
    case R4NV_PTRDIFF: return va_arg(*args, uintptr_t);
    case R4NV_MAXINT: return va_arg(*args, uintmax_t);
    default: return va_arg(*args, unsigned int);
    }
}
static int64_t r4nv_fmt_signed(va_list *args, enum r4nv_fmt_length length)
{
    switch (length) {
    case R4NV_CHAR: return (signed char)va_arg(*args, int);
    case R4NV_SHORT: return (short)va_arg(*args, int);
    case R4NV_LONG: return va_arg(*args, long);
    case R4NV_LLONG: return va_arg(*args, long long);
    case R4NV_SIZE: return va_arg(*args, intptr_t);
    case R4NV_PTRDIFF: return va_arg(*args, ptrdiff_t);
    case R4NV_MAXINT: return va_arg(*args, intmax_t);
    default: return va_arg(*args, int);
    }
}

static int r4nv_vformat(char *data, size_t capacity, const char *format, va_list input)
{
    if (capacity != 0 && data == NULL) return -1;
    if (capacity != 0) data[0] = '\0';
    if (format == NULL || capacity > R4NV_FORMAT_LIMIT) return -1;
    size_t format_bytes = 0;
    while (format_bytes < R4NV_FORMAT_LIMIT && format[format_bytes] != '\0') ++format_bytes;
    if (format_bytes == R4NV_FORMAT_LIMIT) return -1;
    struct r4nv_fmt_output out = { data, capacity, 0, format_bytes + 1, 0, 0 };
    va_list args;
    va_copy(args, input);
    while (*format != '\0' && !out.failed) {
        if (*format != '%') { r4nv_fmt_repeat(&out, *format++, 1); continue; }
        ++format;
        if (*format == '%') { ++format; r4nv_fmt_repeat(&out, '%', 1); continue; }
        int left = 0, plus = 0, space = 0, alternate = 0, zero = 0;
        for (;;) {
            if (*format == '-') left = 1;
            else if (*format == '+') plus = 1;
            else if (*format == ' ') space = 1;
            else if (*format == '#') alternate = 1;
            else if (*format == '0') zero = 1;
            else break;
            ++format;
        }
        unsigned width;
        if (*format == '*') {
            int value = va_arg(args, int);
            ++format;
            if (value == INT_MIN) { out.failed = 1; break; }
            if (value < 0) { left = 1; value = -value; }
            width = (unsigned)value;
        } else width = r4nv_fmt_decimal(&format, &out.failed);
        int precise = 0;
        unsigned precision = 0;
        if (*format == '.') {
            ++format; precise = 1;
            if (*format == '*') {
                int value = va_arg(args, int);
                ++format;
                if (value < 0) precise = 0;
                else precision = (unsigned)value;
            } else precision = r4nv_fmt_decimal(&format, &out.failed);
        }
        enum r4nv_fmt_length length = R4NV_INT;
        if (*format == 'h') {
            ++format; length = R4NV_SHORT;
            if (*format == 'h') { ++format; length = R4NV_CHAR; }
        } else if (*format == 'l') {
            ++format; length = R4NV_LONG;
            if (*format == 'l') { ++format; length = R4NV_LLONG; }
        } else if (*format == 'z') { ++format; length = R4NV_SIZE; }
        else if (*format == 't') { ++format; length = R4NV_PTRDIFF; }
        else if (*format == 'j') { ++format; length = R4NV_MAXINT; }
        if (out.failed || *format == '\0') { out.failed = 1; break; }
        char conversion = *format++;
        if (conversion == 's' || conversion == 'c') {
            if (length != R4NV_INT) { out.failed = 1; break; }
            char character = 0;
            const char *text;
            unsigned bytes = 0;
            if (conversion == 'c') {
                character = (char)va_arg(args, int); text = &character; bytes = 1;
            } else {
                text = va_arg(args, const char *);
                if (text == NULL) text = "(null)";
                while (!precise || bytes < precision) {
                    if (out.scanned == R4NV_FORMAT_LIMIT) { out.failed = 1; break; }
                    ++out.scanned;
                    if (text[bytes] == '\0') break;
                    ++bytes;
                }
            }
            unsigned padding = width > bytes ? width - bytes : 0;
            if (!left) r4nv_fmt_repeat(&out, ' ', padding);
            r4nv_fmt_bytes(&out, text, bytes);
            if (left) r4nv_fmt_repeat(&out, ' ', padding);
            continue;
        }
        unsigned radix = 10;
        uint64_t value;
        char sign = 0, prefix[2];
        unsigned prefix_bytes = 0;
        int pointer = conversion == 'p';
        if (pointer) {
            /* Print raw addresses explicitly on this trusted OS. Linux's
             * hashed pointers and type-dependent %p extensions are not used. */
            if (length != R4NV_INT || (*format >= 'A' && *format <= 'Z') ||
                (*format >= 'a' && *format <= 'z') || (*format >= '0' && *format <= '9')) {
                out.failed = 1; break;
            }
            value = (uintptr_t)va_arg(args, void *);
            radix = 16;
            // Upstream RM frequently supplies its own "0x%p" prefix.
            if (alternate) { prefix[0] = '0'; prefix[1] = 'x'; prefix_bytes = 2; }
            if (!precise) { precise = 1; precision = sizeof(void *) * 2; }
        } else if (conversion == 'd' || conversion == 'i') {
            int64_t signed_value = r4nv_fmt_signed(&args, length);
            value = (uint64_t)signed_value;
            if (signed_value < 0) { sign = '-'; value = (uint64_t)0 - value; }
            else if (plus) sign = '+';
            else if (space) sign = ' ';
        } else if (conversion == 'u' || conversion == 'o' || conversion == 'x' || conversion == 'X') {
            value = r4nv_fmt_unsigned(&args, length);
            if (conversion == 'o') radix = 8;
            if (conversion == 'x' || conversion == 'X') {
                radix = 16;
                if (alternate && value != 0) { prefix[0] = '0'; prefix[1] = conversion; prefix_bytes = 2; }
            }
        } else { out.failed = 1; break; }
        char digits[64];
        unsigned digit_count = 0;
        const char *alphabet = conversion == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
        if (value != 0 || !precise || precision != 0) {
            do { digits[digit_count++] = alphabet[value % radix]; value /= radix; } while (value != 0);
        }
        unsigned zeroes = precise && precision > digit_count ? precision - digit_count : 0;
        if (conversion == 'o' && alternate && zeroes == 0 &&
            (digit_count == 0 || digits[digit_count - 1] != '0')) zeroes = 1;
        uint64_t total = (uint64_t)digit_count + zeroes + prefix_bytes + (sign != 0);
        if (total > INT_MAX) { out.failed = 1; break; }
        unsigned padding = width > total ? width - (unsigned)total : 0;
        if (!left && !(zero && !precise)) r4nv_fmt_repeat(&out, ' ', padding);
        if (sign != 0) r4nv_fmt_repeat(&out, sign, 1);
        r4nv_fmt_bytes(&out, prefix, prefix_bytes);
        if (!left && zero && !precise) r4nv_fmt_repeat(&out, '0', padding);
        r4nv_fmt_repeat(&out, '0', zeroes);
        while (digit_count != 0) r4nv_fmt_repeat(&out, digits[--digit_count], 1);
        if (left) r4nv_fmt_repeat(&out, ' ', padding);
    }
    va_end(args);
    if (capacity != 0) data[out.failed ? 0 : out.used] = '\0';
    return out.failed ? -1 : (int)out.count;
}
#endif
