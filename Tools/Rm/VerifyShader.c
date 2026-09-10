/* Original R4OS host verifier. The linked XZ Embedded sources retain their
 * original notices in the supplied NVIDIA source tree. No GPU is accessed. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvidia-3d-imports.h"
#include "xz.h"

void *nv3dImportAlloc(size_t size) { return malloc(size); }
void nv3dImportFree(void *ptr) { free(ptr); }
int nv3dImportMemCmp(const void *a, const void *b, size_t size) { return memcmp(a, b, size); }
void nv3dImportMemSet(void *ptr, int value, size_t size) { memset(ptr, value, size); }
void nv3dImportMemCpy(void *dst, const void *src, size_t size) { memcpy(dst, src, size); }
void nv3dImportMemMove(void *dst, const void *src, size_t size) { memmove(dst, src, size); }

static unsigned char *read_file(const char *path, size_t *size)
{
    FILE *file = fopen(path, "rb");
    unsigned char *data = NULL;
    if (file == NULL) return NULL;
    if (fseek(file, 0, SEEK_END) != 0) goto done;
    long length = ftell(file);
    if (length < 1 || length > 1024 * 1024) goto done;
    if (fseek(file, 0, SEEK_SET) != 0) goto done;
    data = malloc((size_t)length);
    if (data == NULL) goto done;
    if (fread(data, 1, (size_t)length, file) != (size_t)length || fgetc(file) != EOF || ferror(file)) {
        free(data);
        data = NULL;
        goto done;
    }
    *size = (size_t)length;
done:
    fclose(file);
    return data;
}

int main(int argc, char **argv)
{
    if (argc != 3) return 2;
    size_t compressed_size = 0, original_size = 0;
    unsigned char *compressed = read_file(argv[1], &compressed_size);
    unsigned char *original = read_file(argv[2], &original_size);
    unsigned char *decoded = NULL;
    struct xz_dec *state = NULL;
    int result = 3;
    if (compressed == NULL || original == NULL) goto done;
    result = 4;
    /* The original NVKMS build explicitly uses --check=none. */
    if (compressed_size < 12 || compressed[6] != 0 || compressed[7] != 0) goto done;
    decoded = malloc(original_size);
    if (decoded == NULL) goto done;
    xz_crc32_init();
    state = xz_dec_init(XZ_SINGLE, 0);
    if (state == NULL) goto done;
    struct xz_buf buffer = {
        .in = compressed, .in_pos = 0, .in_size = compressed_size,
        .out = decoded, .out_pos = 0, .out_size = original_size,
    };
    enum xz_ret status = xz_dec_run(state, &buffer);
    result = 5;
    if (status != XZ_STREAM_END || buffer.in_pos != compressed_size || buffer.out_pos != original_size) goto done;
    result = 6;
    if (memcmp(decoded, original, original_size) != 0) goto done;
    printf("Original NVIDIA XZ_SINGLE decoder: %zu -> %zu bytes, complete and byte-identical\n", compressed_size, original_size);
    result = 0;
done:
    xz_dec_end(state);
    free(decoded);
    free(original);
    free(compressed);
    return result;
}
