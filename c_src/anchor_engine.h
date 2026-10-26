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
 * Get version string of the anchor engine
 */
const char* synvim_anchor_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SYNVIM_ANCHOR_ENGINE_H */
