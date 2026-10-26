#ifndef SYNVIM_ANCHOR_ENGINE_H
#define SYNVIM_ANCHOR_ENGINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int start_line;          /* 1-based start line in buffer */
    int end_line;            /* 1-based end line in buffer (inclusive) */
    double confidence;       /* 0.0 to 1.0 match confidence */
    int is_already_applied;  /* 1 if new_lines is already applied at target */
    int duplicate_line;      /* >0 if identifier/symbol already exists elsewhere */
    char match_mode[32];     /* "exact", "sandwich", "fuzzy", "duplicate_snap", "none" */
} SynvimAnchorResult;

/**
 * High-performance, language-agnostic context hunk and anti-duplication anchor engine.
 * Uses zero-copy string views and fast sliding window search to locate edits
 * despite upstream line drift or file resizing.
 */
SynvimAnchorResult synvim_find_context_anchor(
    const char* buffer_text,
    const char* context_before,
    const char* target_lines,
    const char* context_after,
    const char* new_lines,
    const char* identifier_slug
);

/**
 * Locate the 1-based start line of a multi-line `block_text` inside `buffer_text`
 * closest to `hint_line` (1-based).
 * First checks exact line equality; if `normalize_ws` is non-zero and no exact
 * match is found, falls back to trimmed-whitespace line equality.
 * Returns >0 (1-based line number) on match, or 0 if not found.
 */
int synvim_find_nearest_block(
    const char* buffer_text,
    const char* block_text,
    int hint_line,
    int normalize_ws
);

/**
 * Locate the 1-based line number of a task header (TODO/SPEC/CONTRACT/FIXME)
 * matching `task_slug` inside `buffer_text`, closest to `hint_line` (1-based).
 * Returns >0 (1-based line number) on match, or 0 if not found.
 */
int synvim_find_task_line(
    const char* buffer_text,
    const char* task_slug,
    int hint_line
);

typedef struct {
    int start_line;      /* 1-based start line of the task block */
    int line_count;      /* number of lines in THIS single task block (excluding other distinct tasks) */
    int has_contract;    /* 1 if Hoare/DTL contract lines are present */
} SynvimTaskBlockSpan;

/**
 * Compute the exact multi-line span of a single task comment block starting at
 * `start_line` (1-based). Absorbs continuation lines (Hoare contract, DTL policy,
 * blank comment lines) and duplicate headers with the SAME `task_slug`, while
 * strictly stopping before any distinct task header (TODO/FIXME/SPEC/CONTRACT).
 */
SynvimTaskBlockSpan synvim_find_task_block_span(
    const char* buffer_text,
    int start_line,
    const char* task_slug
);

/**
 * Get version string of the anchor engine
 */
const char* synvim_anchor_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SYNVIM_ANCHOR_ENGINE_H */
