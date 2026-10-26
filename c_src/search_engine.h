#ifndef SYNVIM_SEARCH_ENGINE_H
#define SYNVIM_SEARCH_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Execute hybrid repository search across both file names/paths and file contents.
 *
 * Algorithms combined:
 *   1. Smith-Waterman / FZF affine-gap fuzzy path & filename alignment
 *      (with word-boundary, camelCase/snake_case hump, and basename multipliers)
 *   2. Okapi BM25 content scoring with corpus IDF weighting, 5-line sliding window
 *      multi-term proximity, and bounded Levenshtein typo tolerance
 *   3. Multi-language structural symbol definition detection (Lua, Python, Rust,
 *      C/C++, Go, TS/JS, Lean, and Synvim CONTRACT/SPEC/TODO headers)
 *   4. Cross-signal path + content score fusion and per-file non-maximum suppression
 *
 * @param root_dir       Repository root directory
 * @param query_raw      Search query string
 * @param locations_json Optional JSON array of paths/directories/globs to scope search
 * @param max_results    Maximum number of ranked results to return
 * @return Thread-local JSON string array of ranked matches
 */
const char* synvim_search_repo(
    const char* root_dir,
    const char* query_raw,
    const char* locations_json,
    int max_results
);

/**
 * Returns search engine version string.
 */
const char* synvim_search_version(void);

#ifdef __cplusplus
}
#endif

#endif // SYNVIM_SEARCH_ENGINE_H
