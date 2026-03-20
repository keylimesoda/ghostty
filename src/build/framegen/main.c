#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#endif
#include <errno.h>
#include <zlib.h>

#define SEPARATOR '\x01'
#define CHUNK_SIZE 16384

#ifdef _WIN32
static int filter_frames(const char *name) {
    size_t len = strlen(name);
    return len > 4 && strcmp(name + len - 4, ".txt") == 0;
}

static int compare_frames(const void *a, const void *b) {
    const char *const *name_a = a;
    const char *const *name_b = b;
    return strcmp(*name_a, *name_b);
}
#else
static int filter_frames(const struct dirent *entry) {
    const char *name = entry->d_name;
    size_t len = strlen(name);
    return len > 4 && strcmp(name + len - 4, ".txt") == 0;
}

static int compare_frames(const struct dirent **a, const struct dirent **b) {
    return strcmp((*a)->d_name, (*b)->d_name);
}
#endif

static char *read_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Failed to open %s: %s\n", path, strerror(errno));
        return NULL;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    char *buf = malloc(size);
    if (!buf) {
        return NULL;
    }

    if (fread(buf, 1, size, f) != (size_t)size) {
        fprintf(stderr, "Failed to read %s\n", path);
        return NULL;
    }

    fclose(f);
    *out_size = size;
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <frames_dir> <output_file>\n", argv[0]);
        return 1;
    }

    const char *frames_dir = argv[1];
    const char *output_file = argv[2];

#ifdef _WIN32
    int n = 0;
    char **frame_names = NULL;
    char search_pattern[4096];
    snprintf(search_pattern, sizeof(search_pattern), "%s\\*", frames_dir);

    WIN32_FIND_DATAA find_data;
    HANDLE find_handle = FindFirstFileA(search_pattern, &find_data);
    if (find_handle == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "Failed to scan directory %s (error %lu)\n", frames_dir, GetLastError());
        return 1;
    }

    size_t capacity = 16;
    frame_names = malloc(capacity * sizeof(char *));
    if (!frame_names) {
        fprintf(stderr, "Failed to allocate frame name list\n");
        FindClose(find_handle);
        return 1;
    }

    do {
        const char *name = find_data.cFileName;
        if ((find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            continue;
        }
        if (!filter_frames(name)) {
            continue;
        }

        if ((size_t)n == capacity) {
            size_t new_capacity = capacity * 2;
            char **new_names = realloc(frame_names, new_capacity * sizeof(char *));
            if (!new_names) {
                fprintf(stderr, "Failed to grow frame name list\n");
                FindClose(find_handle);
                return 1;
            }
            frame_names = new_names;
            capacity = new_capacity;
        }

        frame_names[n] = _strdup(name);
        if (!frame_names[n]) {
            fprintf(stderr, "Failed to copy frame file name\n");
            FindClose(find_handle);
            return 1;
        }

        n++;
    } while (FindNextFileA(find_handle, &find_data) != 0);

    DWORD scan_result = GetLastError();
    FindClose(find_handle);
    if (scan_result != ERROR_NO_MORE_FILES) {
        fprintf(stderr, "Failed during directory scan of %s (error %lu)\n", frames_dir, scan_result);
        return 1;
    }

    qsort(frame_names, n, sizeof(char *), compare_frames);
#else
    struct dirent **namelist;
    int n = scandir(frames_dir, &namelist, filter_frames, compare_frames);
    if (n < 0) {
        fprintf(stderr, "Failed to scan directory %s: %s\n", frames_dir, strerror(errno));
        return 1;
    }
#endif

    if (n == 0) {
        fprintf(stderr, "No frame files found in %s\n", frames_dir);
        return 1;
    }

    size_t total_size = 0;
    char **frame_contents = calloc(n, sizeof(char*));
    size_t *frame_sizes = calloc(n, sizeof(size_t));

    for (int i = 0; i < n; i++) {
        char path[4096];
        const char *frame_name;
#ifdef _WIN32
        frame_name = frame_names[i];
        snprintf(path, sizeof(path), "%s\\%s", frames_dir, frame_name);
#else
        frame_name = namelist[i]->d_name;
        snprintf(path, sizeof(path), "%s/%s", frames_dir, frame_name);
#endif
        
        frame_contents[i] = read_file(path, &frame_sizes[i]);
        if (!frame_contents[i]) {
            return 1;
        }
        
        total_size += frame_sizes[i];
        if (i < n - 1) total_size++;
    }

    char *joined = malloc(total_size);
    if (!joined) {
        fprintf(stderr, "Failed to allocate joined buffer\n");
        return 1;
    }

    size_t offset = 0;
    for (int i = 0; i < n; i++) {
        memcpy(joined + offset, frame_contents[i], frame_sizes[i]);
        offset += frame_sizes[i];
        if (i < n - 1) {
            joined[offset++] = SEPARATOR;
        }
    }

    uLongf compressed_size = compressBound(total_size);
    unsigned char *compressed = malloc(compressed_size);
    if (!compressed) {
        fprintf(stderr, "Failed to allocate compression buffer\n");
        return 1;
    }

    z_stream stream = {0};
    stream.next_in = (unsigned char*)joined;
    stream.avail_in = total_size;
    stream.next_out = compressed;
    stream.avail_out = compressed_size;

    // Use -MAX_WBITS for raw DEFLATE (no zlib wrapper)
    int ret = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    if (ret != Z_OK) {
        fprintf(stderr, "deflateInit2 failed: %d\n", ret);
        return 1;
    }

    ret = deflate(&stream, Z_FINISH);
    if (ret != Z_STREAM_END) {
        fprintf(stderr, "deflate failed: %d\n", ret);
        deflateEnd(&stream);
        return 1;
    }

    compressed_size = stream.total_out;
    deflateEnd(&stream);
    
    FILE *out = fopen(output_file, "wb");
    if (!out) {
        fprintf(stderr, "Failed to create %s: %s\n", output_file, strerror(errno));
        return 1;
    }

    if (fwrite(compressed, 1, compressed_size, out) != compressed_size) {
        fprintf(stderr, "Failed to write compressed data\n");
        return 1;
    }

    fclose(out);

    return 0;
}
