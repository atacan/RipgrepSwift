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

/*
 * Optional progress reporting. Invoked after each read chunk with the
 * cumulative number of regular files whose search has started and the
 * cumulative number of bytes read so far. May be NULL.
 */
typedef void (*rg_progress_callback_t)(
    void *context,
    uint64_t files_visited,
    uint64_t bytes_searched
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
 * Opaque cancellation token, owned by the caller.
 *
 * Create with rg_cancel_token_create and release with
 * rg_cancel_token_free exactly once. A token must outlive every rg_search
 * call that received it; freeing a token while a search is still using it
 * is a caller error. The token may be cancelled from any thread while a
 * search is in flight; cancellation is atomic and idempotent.
 */
typedef struct rg_cancel_token rg_cancel_token_t;

/* Creates a cancellation token. Returns NULL only on allocation failure. */
rg_cancel_token_t *rg_cancel_token_create(void);

/*
 * Requests cancellation: every rg_search call using this token stops as
 * soon as practical — between files, before each read chunk inside a file,
 * or immediately when parked on a match callback — and finishes with
 * RG_STATUS_CANCELLED. Idempotent; safe from any thread. Passing NULL does
 * nothing.
 */
void rg_cancel_token_cancel(rg_cancel_token_t *token);

/*
 * Releases a token previously produced by rg_cancel_token_create. Passing
 * NULL does nothing. Must not be called while any rg_search call is still
 * using the token.
 */
void rg_cancel_token_free(rg_cancel_token_t *token);

/*
 * Synchronously search `root` for `pattern`, delivering each match through
 * `callback(context, match)`. All input byte ranges are borrowed for the
 * duration of the call only.
 *
 * `cancel_token` may be NULL (the search then cannot be cancelled except
 * by the callback returning false). Cancellation requested through the
 * token surfaces as RG_STATUS_CANCELLED, never as an error.
 *
 * `progress` may be NULL; when non-null it receives cumulative traversal
 * progress as described above.
 *
 * On failure, if `error_message` is non-null it receives a heap-allocated,
 * NUL-terminated UTF-8 string that the caller must release with
 * rg_free_string. Never panics across the FFI boundary.
 */
rg_status_t rg_search(
    const uint8_t *root,
    size_t root_len,

    const uint8_t *pattern,
    size_t pattern_len,

    const rg_search_options_t *options,

    const rg_cancel_token_t *cancel_token,

    rg_match_callback_t callback,
    void *context,

    rg_progress_callback_t progress,
    void *progress_context,

    char **error_message
);

/* Releases a string previously produced by rg_search via error_message. */
void rg_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif /* RIPGREP_FFI_H */
