#ifndef RIPGREP_FFI_H
#define RIPGREP_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rg_search_options {
    bool include_hidden;
    bool follow_symlinks;
    bool respect_gitignore;
    bool case_insensitive;
} rg_search_options_t;

/*
 * A single search result. The `path` and `line` buffers are borrowed:
 * they are only valid for the duration of the callback invocation that
 * delivers this structure. Receivers must copy the bytes before returning.
 *
 * `match_start` / `match_end` are zero-based UTF-8 byte offsets into `line`.
 */
typedef struct rg_match {
    const uint8_t *path;
    size_t path_len;

    uint64_t line_number;

    const uint8_t *line;
    size_t line_len;

    size_t match_start;
    size_t match_end;
} rg_match_t;

/*
 * Return true to continue the search, false to cancel it as soon as
 * practical. When false is returned, rg_search finishes with
 * RG_STATUS_CANCELLED.
 */
typedef bool (*rg_match_callback_t)(
    void *context,
    const rg_match_t *match
);

typedef enum rg_status {
    RG_STATUS_OK = 0,
    RG_STATUS_CANCELLED = 1,
    RG_STATUS_INVALID_ARGUMENT = 2,
    RG_STATUS_INVALID_PATTERN = 3,
    RG_STATUS_IO_ERROR = 4,
    RG_STATUS_INTERNAL_ERROR = 255
} rg_status_t;

/*
 * Synchronously search `root` for `pattern`, delivering each match through
 * `callback(context, match)`. All input byte ranges are borrowed for the
 * duration of the call only. On failure, if `error_message` is non-null it
 * receives a heap-allocated, NUL-terminated UTF-8 string that the caller
 * must release with rg_free_string. Never panics across the FFI boundary.
 */
rg_status_t rg_search(
    const uint8_t *root,
    size_t root_len,

    const uint8_t *pattern,
    size_t pattern_len,

    const rg_search_options_t *options,

    rg_match_callback_t callback,
    void *context,

    char **error_message
);

/* Releases a string previously produced by rg_search via error_message. */
void rg_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif /* RIPGREP_FFI_H */
