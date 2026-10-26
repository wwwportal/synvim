#include "anchor_engine.h"

#include <string>
#include <string_view>
#include <vector>
#include <algorithm>
#include <cstring>
#include <cctype>
#include <cmath>

namespace {

// In-place whitespace trimmer for string_view
std::string_view trim_sv(std::string_view sv) {
    while (!sv.empty() && (std::isspace(static_cast<unsigned char>(sv.front())) || sv.front() == '\r')) {
        sv.remove_prefix(1);
    }
    while (!sv.empty() && (std::isspace(static_cast<unsigned char>(sv.back())) || sv.back() == '\r')) {
        sv.remove_suffix(1);
    }
    return sv;
}

// Split string by newline into vector of string_view (zero copy)
std::vector<std::string_view> split_lines(std::string_view s) {
    std::vector<std::string_view> lines;
    if (s.empty()) return lines;

    size_t start = 0;
    while (start < s.size()) {
        size_t end = s.find('\n', start);
        if (end == std::string_view::npos) {
            std::string_view l = s.substr(start);
            if (!l.empty() && l.back() == '\r') l.remove_suffix(1);
            lines.push_back(l);
            break;
        }
        std::string_view l = s.substr(start, end - start);
        if (!l.empty() && l.back() == '\r') l.remove_suffix(1);
        lines.push_back(l);
        start = end + 1;
    }
    return lines;
}

// Case-insensitive substring search in string_view
bool contains_ci(std::string_view haystack, std::string_view needle) {
    if (needle.empty()) return true;
    if (needle.size() > haystack.size()) return false;

    auto it = std::search(
        haystack.begin(), haystack.end(),
        needle.begin(), needle.end(),
        [](char ch1, char ch2) {
            return std::tolower(static_cast<unsigned char>(ch1)) ==
                   std::tolower(static_cast<unsigned char>(ch2));
        }
    );
    return it != haystack.end();
}

// Normalized line equality (ignoring leading/trailing indentation differences)
bool lines_equal_normalized(std::string_view a, std::string_view b) {
    return trim_sv(a) == trim_sv(b);
}

// Fuzzy string similarity (Levenshtein distance normalized to 0.0 - 1.0)
double line_similarity(std::string_view s1, std::string_view s2) {
    s1 = trim_sv(s1);
    s2 = trim_sv(s2);
    if (s1 == s2) return 1.0;
    if (s1.empty() || s2.empty()) return 0.0;

    const size_t len1 = s1.size();
    const size_t len2 = s2.size();
    if (std::max(len1, len2) > 256) {
        if (s1.substr(0, 32) == s2.substr(0, 32)) return 0.85;
        return 0.0;
    }

    std::vector<int> col(len2 + 1);
    for (size_t j = 0; j <= len2; ++j) col[j] = static_cast<int>(j);

    for (size_t i = 1; i <= len1; ++i) {
        col[0] = static_cast<int>(i);
        int prev = static_cast<int>(i - 1);
        for (size_t j = 1; j <= len2; ++j) {
            int current = col[j];
            int cost = (std::tolower(static_cast<unsigned char>(s1[i - 1])) ==
                        std::tolower(static_cast<unsigned char>(s2[j - 1]))) ? 0 : 1;
            col[j] = std::min({ col[j] + 1, col[j - 1] + 1, prev + cost });
            prev = current;
        }
    }

    int dist = col[len2];
    double max_len = static_cast<double>(std::max(len1, len2));
    return 1.0 - (static_cast<double>(dist) / max_len);
}

} // namespace

extern "C" {

const char* synvim_anchor_version(void) {
    return "1.0.0-anchor-ffi";
}

SynvimAnchorResult synvim_find_context_anchor(
    const char* buffer_text,
    const char* context_before,
    const char* target_lines,
    const char* context_after,
    const char* new_lines,
    const char* identifier_slug
) {
    SynvimAnchorResult res;
    res.start_line = 1;
    res.end_line = 1;
    res.confidence = 0.0;
    res.is_already_applied = 0;
    res.duplicate_line = 0;
    std::strncpy(res.match_mode, "none", sizeof(res.match_mode) - 1);
    res.match_mode[sizeof(res.match_mode) - 1] = '\0';

    if (!buffer_text) return res;

    std::string_view buf_sv(buffer_text);
    std::vector<std::string_view> buf_lines = split_lines(buf_sv);
    if (buf_lines.empty()) return res;

    std::vector<std::string_view> before_lines = split_lines(context_before ? context_before : "");
    std::vector<std::string_view> target_list = split_lines(target_lines ? target_lines : "");
    std::vector<std::string_view> after_lines = split_lines(context_after ? context_after : "");
    std::vector<std::string_view> new_list = split_lines(new_lines ? new_lines : "");
    std::string_view slug_sv = identifier_slug ? trim_sv(identifier_slug) : std::string_view{};

    const int total_lines = static_cast<int>(buf_lines.size());

    // ─────────────────────────────────────────────────────────────────────────────
    // STEP 1: Fast Duplicate / Identifier Sentinel Scan
    // Check if the task ID or function identifier already exists in the buffer
    // ─────────────────────────────────────────────────────────────────────────────
    if (!slug_sv.empty() && slug_sv != "task") {
        for (int i = 0; i < total_lines; ++i) {
            std::string_view bl = buf_lines[i];
            if (contains_ci(bl, slug_sv)) {
                if (contains_ci(bl, "TODO(") || contains_ci(bl, "SPEC(") ||
                    contains_ci(bl, "CONTRACT(") || contains_ci(bl, "FIXME(") ||
                    contains_ci(bl, "def ") || contains_ci(bl, "function ") ||
                    contains_ci(bl, "fn ") || contains_ci(bl, "class ")) {
                    res.duplicate_line = i + 1;
                    break;
                } else if (res.duplicate_line == 0) {
                    res.duplicate_line = i + 1;
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // STEP 2: Check if new_lines is ALREADY APPLIED verbatim anywhere in the buffer
    // ─────────────────────────────────────────────────────────────────────────────
    if (!new_list.empty()) {
        const int n_len = static_cast<int>(new_list.size());
        for (int i = 0; i <= total_lines - n_len; ++i) {
            bool matches_all = true;
            for (int k = 0; k < n_len; ++k) {
                if (!lines_equal_normalized(buf_lines[i + k], new_list[k])) {
                    matches_all = false;
                    break;
                }
            }
            if (matches_all) {
                res.start_line = i + 1;
                res.end_line = i + n_len;
                res.confidence = 1.0;
                res.is_already_applied = 1;
                std::strncpy(res.match_mode, "already_applied", sizeof(res.match_mode) - 1);
                return res;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // STEP 3: 3-Point Sandwich Matching (context_before + target + context_after)
    // ─────────────────────────────────────────────────────────────────────────────
    const int b_len = static_cast<int>(before_lines.size());
    const int t_len = static_cast<int>(target_list.size());
    const int a_len = static_cast<int>(after_lines.size());

    if (b_len > 0 || a_len > 0) {
        for (int i = 0; i < total_lines; ++i) {
            bool before_ok = true;
            if (b_len > 0) {
                // Find effective end of preceding context (allowing optional blank lines)
                int before_end = i;
                while (before_end > 0 && trim_sv(buf_lines[before_end - 1]).empty()) {
                    before_end--;
                }
                if (before_end < b_len) {
                    before_ok = false;
                } else {
                    for (int k = 0; k < b_len; ++k) {
                        if (!lines_equal_normalized(buf_lines[before_end - b_len + k], before_lines[k])) {
                            before_ok = false;
                            break;
                        }
                    }
                }
            }

            if (!before_ok) continue;

            // Target lines check (if target lines provided)
            bool target_ok = true;
            if (t_len > 0) {
                if (i + t_len > total_lines) {
                    target_ok = false;
                } else {
                    for (int k = 0; k < t_len; ++k) {
                        if (!lines_equal_normalized(buf_lines[i + k], target_list[k])) {
                            target_ok = false;
                            break;
                        }
                    }
                }
            }

            if (!target_ok) continue;

            // After lines check (allowing optional blank lines)
            bool after_ok = true;
            if (a_len > 0) {
                int after_start = i + t_len;
                while (after_start < total_lines && trim_sv(buf_lines[after_start]).empty()) {
                    after_start++;
                }
                if (after_start + a_len > total_lines) {
                    after_ok = false;
                } else {
                    for (int k = 0; k < a_len; ++k) {
                        if (!lines_equal_normalized(buf_lines[after_start + k], after_lines[k])) {
                            after_ok = false;
                            break;
                        }
                    }
                }
            }

            if (after_ok) {
                res.start_line = i + 1;
                res.end_line = std::max(i + 1, i + t_len);
                res.confidence = 1.0;
                if (t_len == 0) {
                    std::strncpy(res.match_mode, "junction", sizeof(res.match_mode) - 1);
                } else {
                    std::strncpy(res.match_mode, "sandwich", sizeof(res.match_mode) - 1);
                }
                return res;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // STEP 4: Exact Target Block Search (in case context drifted)
    // ─────────────────────────────────────────────────────────────────────────────
    if (t_len > 0) {
        for (int i = 0; i <= total_lines - t_len; ++i) {
            bool matched = true;
            for (int k = 0; k < t_len; ++k) {
                if (!lines_equal_normalized(buf_lines[i + k], target_list[k])) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                res.start_line = i + 1;
                res.end_line = i + t_len;
                res.confidence = 0.95;
                std::strncpy(res.match_mode, "exact_target", sizeof(res.match_mode) - 1);
                return res;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // STEP 5: Duplicate Snap (Anti-Reduplication Guard)
    // If target was not found verbatim, but duplicate_line exists, snap to it!
    // ─────────────────────────────────────────────────────────────────────────────
    if (res.duplicate_line > 0) {
        res.start_line = res.duplicate_line;
        res.end_line = res.duplicate_line;
        res.confidence = 0.85;
        std::strncpy(res.match_mode, "duplicate_snap", sizeof(res.match_mode) - 1);
        return res;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // STEP 6: Fuzzy Sliding Window Fallback
    // ─────────────────────────────────────────────────────────────────────────────
    if (t_len > 0) {
        double best_sim = 0.0;
        int best_pos = -1;

        for (int i = 0; i <= total_lines - t_len; ++i) {
            double current_sim = 0.0;
            for (int k = 0; k < t_len; ++k) {
                current_sim += line_similarity(buf_lines[i + k], target_list[k]);
            }
            current_sim /= t_len;
            if (current_sim > best_sim) {
                best_sim = current_sim;
                best_pos = i;
            }
        }

        if (best_sim >= 0.75 && best_pos >= 0) {
            res.start_line = best_pos + 1;
            res.end_line = best_pos + t_len;
            res.confidence = best_sim;
            std::strncpy(res.match_mode, "fuzzy", sizeof(res.match_mode) - 1);
            return res;
        }
    }

    return res;
}

} // extern "C"
