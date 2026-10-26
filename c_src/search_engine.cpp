#include "search_engine.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace fs = std::filesystem;

static thread_local std::string tls_search_json;

// ==============================================================================
// String, Tokenization & Fuzzy Edit-Distance Utilities
// ==============================================================================

static inline char to_lower_ascii(char c) {
    return (c >= 'A' && c <= 'Z') ? static_cast<char>(c + ('a' - 'A')) : c;
}

static std::string to_lower_str(std::string_view sv) {
    std::string out;
    out.resize(sv.size());
    for (size_t i = 0; i < sv.size(); ++i) {
        out[i] = to_lower_ascii(sv[i]);
    }
    return out;
}

static inline bool is_ident_char(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
}

static inline bool is_word_boundary_at(std::string_view line, size_t pos, size_t len) {
    bool left_ok = (pos == 0) || !is_ident_char(line[pos - 1]);
    bool right_ok = (pos + len >= line.size()) || !is_ident_char(line[pos + len]);
    return left_ok && right_ok;
}

static std::string json_escape(std::string_view sv) {
    std::string out;
    out.reserve(sv.size() + 8);
    for (char c : sv) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += " "; break;
            default:
                if (static_cast<unsigned char>(c) >= 0x20) {
                    out += c;
                }
                break;
        }
    }
    return out;
}

static std::string trim_str(std::string_view sv) {
    size_t start = 0;
    while (start < sv.size() && std::isspace(static_cast<unsigned char>(sv[start]))) {
        ++start;
    }
    size_t end = sv.size();
    while (end > start && std::isspace(static_cast<unsigned char>(sv[end - 1]))) {
        --end;
    }
    return std::string(sv.substr(start, end - start));
}

// Extract JSON string array: ["path1", "path2"]
static std::vector<std::string> parse_json_string_array(std::string_view json) {
    std::vector<std::string> res;
    size_t pos = json.find('[');
    if (pos == std::string_view::npos) return res;
    size_t end = json.find(']', pos);
    if (end == std::string_view::npos) return res;
    std::string_view body = json.substr(pos + 1, end - pos - 1);
    size_t cur = 0;
    while (true) {
        size_t q1 = body.find('"', cur);
        if (q1 == std::string_view::npos) break;
        size_t q2 = body.find('"', q1 + 1);
        while (q2 != std::string_view::npos && body[q2 - 1] == '\\') {
            q2 = body.find('"', q2 + 1);
        }
        if (q2 == std::string_view::npos) break;
        std::string item(body.substr(q1 + 1, q2 - q1 - 1));
        if (!item.empty()) res.push_back(item);
        cur = q2 + 1;
    }
    return res;
}

// Split camelCase, PascalCase, snake_case, kebab-case, and dot/colon paths into lowercase sub-tokens
static std::vector<std::string> split_subtokens(std::string_view text) {
    std::vector<std::string> out;
    std::string cur;
    for (size_t i = 0; i < text.size(); ++i) {
        char c = text[i];
        if (!std::isalnum(static_cast<unsigned char>(c))) {
            if (!cur.empty()) {
                out.push_back(to_lower_str(cur));
                cur.clear();
            }
            continue;
        }
        // CamelCase boundary: lowercase followed by uppercase, or uppercase followed by uppercase+lowercase
        if (!cur.empty() && std::isupper(static_cast<unsigned char>(c))) {
            char prev = cur.back();
            bool prev_lower = std::islower(static_cast<unsigned char>(prev)) != 0;
            bool next_lower = (i + 1 < text.size()) && (std::islower(static_cast<unsigned char>(text[i + 1])) != 0);
            if (prev_lower || ( std::isupper(static_cast<unsigned char>(prev)) && next_lower )) {
                out.push_back(to_lower_str(cur));
                cur.clear();
            }
        }
        cur.push_back(c);
    }
    if (!cur.empty()) {
        out.push_back(to_lower_str(cur));
    }
    return out;
}

static bool is_stop_word(const std::string& w) {
    static const std::unordered_set<std::string> stops = {
        "where", "did", "we", "implement", "implementation", "the", "a", "an",
        "in", "is", "of", "to", "and", "or", "for", "with", "find", "show",
        "me", "how", "what", "which", "can", "you", "at", "on", "from", "by",
        "this", "that", "there", "are", "was", "our", "us", "it", "its", "my",
        "locate", "look", "up", "into", "when", "why", "does", "do"
    };
    return stops.find(w) != stops.end();
}

// Bounded Damerau-Levenshtein distance (returns max_dist + 1 if exceeded)
static int bounded_edit_distance(std::string_view a, std::string_view b, int max_dist) {
    int n = static_cast<int>(a.size());
    int m = static_cast<int>(b.size());
    if (std::abs(n - m) > max_dist) return max_dist + 1;
    if (n == 0) return m;
    if (m == 0) return n;

    std::vector<int> prev(m + 1), cur(m + 1), prev2(m + 1);
    for (int j = 0; j <= m; ++j) prev[j] = j;

    for (int i = 1; i <= n; ++i) {
        cur[0] = i;
        int row_min = cur[0];
        for (int j = 1; j <= m; ++j) {
            int cost = (to_lower_ascii(a[i - 1]) == to_lower_ascii(b[j - 1])) ? 0 : 1;
            int val = std::min({
                prev[j] + 1,      // deletion
                cur[j - 1] + 1,   // insertion
                prev[j - 1] + cost // substitution
            });
            if (i > 1 && j > 1 &&
                to_lower_ascii(a[i - 1]) == to_lower_ascii(b[j - 2]) &&
                to_lower_ascii(a[i - 2]) == to_lower_ascii(b[j - 1])) {
                val = std::min(val, prev2[j - 2] + 1); // transposition
            }
            cur[j] = val;
            if (val < row_min) row_min = val;
        }
        if (row_min > max_dist) return max_dist + 1;
        prev2 = prev;
        prev = cur;
    }
    return prev[m];
}

// ==============================================================================
// Stage 1: Smith-Waterman / FZF Affine-Gap Fuzzy Path & Filename Scoring
// ==============================================================================

struct PathMatchResult {
    double score = 0.0;
    int col = 1;
    bool matched = false;
};

static double fzf_subsequence_score(std::string_view text, std::string_view pattern, int* first_col_out = nullptr) {
    if (pattern.empty() || text.empty() || pattern.size() > text.size()) return 0.0;

    // Quick subsequence pre-check (case-insensitive)
    size_t p_idx = 0;
    int first_pos = -1;
    int prev_pos = -1;
    int consecutive = 0;
    double score = 0.0;

    for (size_t t_idx = 0; t_idx < text.size() && p_idx < pattern.size(); ++t_idx) {
        char tc = to_lower_ascii(text[t_idx]);
        char pc = to_lower_ascii(pattern[p_idx]);
        if (tc == pc) {
            if (first_pos < 0) first_pos = static_cast<int>(t_idx);
            double char_score = 16.0;

            // Word boundary bonus (start of string, after '/', '_', '-', '.', or camelCase hump)
            if (t_idx == 0) {
                char_score += 28.0;
            } else {
                char prev_c = text[t_idx - 1];
                if (prev_c == '/' || prev_c == '_' || prev_c == '-' || prev_c == '.') {
                    char_score += 24.0;
                } else if (std::islower(static_cast<unsigned char>(prev_c)) &&
                           std::isupper(static_cast<unsigned char>(text[t_idx]))) {
                    char_score += 20.0;
                }
            }

            // Consecutive match bonus vs affine gap penalty
            if (prev_pos >= 0 && static_cast<int>(t_idx) == prev_pos + 1) {
                consecutive++;
                char_score += 14.0 + std::min(consecutive * 2.0, 12.0);
            } else if (prev_pos >= 0) {
                int gap = static_cast<int>(t_idx) - prev_pos - 1;
                consecutive = 0;
                char_score -= (3.0 + 1.0 * gap);
            }

            // Exact case match bonus
            if (text[t_idx] == pattern[p_idx]) {
                char_score += 2.0;
            }

            score += char_score;
            prev_pos = static_cast<int>(t_idx);
            p_idx++;
        }
    }

    if (p_idx < pattern.size()) return 0.0; // Not a subsequence

    // Density check: prevent scattered matches across very long strings
    int span = prev_pos - first_pos + 1;
    double density = static_cast<double>(pattern.size()) / static_cast<double>(std::max(1, span));
    if (pattern.size() <= 3 && density < 0.6) return 0.0;
    if (density < 0.28) return 0.0;

    if (first_col_out && first_pos >= 0) {
        *first_col_out = first_pos + 1;
    }
    return std::max(0.0, score * (0.5 + 0.5 * density));
}

static PathMatchResult score_filepath(
    std::string_view rel_path,
    std::string_view raw_query_clean,
    const std::vector<std::string>& tokens,
    const std::vector<std::string>& subtokens
) {
    PathMatchResult res;
    std::string path_low = to_lower_str(rel_path);
    size_t slash_pos = rel_path.rfind('/');
    std::string_view basename = (slash_pos == std::string_view::npos) ? rel_path : rel_path.substr(slash_pos + 1);
    std::string base_low = to_lower_str(basename);

    size_t dot_pos = base_low.rfind('.');
    std::string base_stem = (dot_pos == std::string::npos) ? base_low : base_low.substr(0, dot_pos);

    std::string q_low = to_lower_str(raw_query_clean);
    // Strip spaces if query looks like a path or single identifier
    bool single_term = (q_low.find(' ') == std::string::npos);

    double score = 0.0;

    // 1. Direct exact / substring matches on basename and full path
    if (single_term && !q_low.empty()) {
        bool suffix_path_match = (path_low.size() > q_low.size() &&
                                  path_low.rfind("/" + q_low) == path_low.size() - q_low.size() - 1);
        if (base_low == q_low || path_low == q_low || suffix_path_match) {
            score += 750.0;
            res.matched = true;
        } else if (base_stem == q_low) {
            score += 480.0;
            res.matched = true;
        } else if (base_low.find(q_low) == 0) {
            score += 280.0;
            res.matched = true;
        } else if (base_low.find(q_low) != std::string::npos) {
            score += 220.0;
            res.matched = true;
        } else if (path_low.find(q_low) != std::string::npos) {
            score += 170.0;
            res.matched = true;
        } else if (q_low.size() >= 3) {
            // FZF affine-gap subsequence alignment on basename (2x weight) and path
            int col_b = 1;
            double fzf_base = fzf_subsequence_score(basename, raw_query_clean, &col_b);
            if (fzf_base > 25.0) {
                score += fzf_base * 1.8;
                res.col = col_b;
                res.matched = true;
            } else {
                int col_p = 1;
                double fzf_path = fzf_subsequence_score(rel_path, raw_query_clean, &col_p);
                if (fzf_path > 35.0) {
                    score += fzf_path * 1.1;
                    res.col = col_p;
                    res.matched = true;
                }
            }
        }
    }

    // 2. Multi-token / subtoken coverage across path segments
    std::vector<std::string> path_parts = split_subtokens(rel_path);
    std::unordered_set<std::string> path_part_set(path_parts.begin(), path_parts.end());

    const auto& check_list = !subtokens.empty() ? subtokens : tokens;
    if (!check_list.empty()) {
        int hits = 0;
        int base_hits = 0;
        for (const auto& tk : check_list) {
            if (tk.size() < 2) continue;
            if (base_low.find(tk) != std::string::npos) {
                hits++;
                base_hits++;
            } else if (path_low.find(tk) != std::string::npos || path_part_set.count(tk)) {
                hits++;
            } else if (tk.size() >= 5) {
                // Check bounded edit distance against path subtokens (typo tolerance on filenames!)
                for (const auto& pp : path_parts) {
                    if (bounded_edit_distance(tk, pp, 1) <= 1) {
                        hits++;
                        if (base_low.find(pp) != std::string::npos) base_hits++;
                        break;
                    }
                }
            }
        }
        if (hits > 0) {
            double coverage = static_cast<double>(hits) / static_cast<double>(check_list.size());
            score += hits * 35.0 + base_hits * 30.0 + (coverage * coverage * 90.0);
            if (coverage >= 0.5 || base_hits >= 1) {
                res.matched = true;
            }
        }
    }

    // Slight preference for shorter, shallower source paths
    if (res.matched && score > 0.0) {
        score -= std::min(25.0, static_cast<double>(rel_path.size()) * 0.25);
    }
    res.score = std::max(0.0, score);
    return res;
}

// ==============================================================================
// Stage 2: Zero-Regex O(1) Multi-Language Structural Symbol Definition Scanner
// ==============================================================================

static std::string extract_defined_symbol_fast(std::string_view line_raw) {
    // 1. Check for Synvim CONTRACT(slug) / SPEC(slug) / TODO(slug) / FIXME(slug)
    for (std::string_view tag : { "CONTRACT(", "SPEC(", "TODO(", "FIXME(" }) {
        size_t pos = line_raw.find(tag);
        if (pos != std::string_view::npos) {
            size_t start = pos + tag.size();
            size_t end = start;
            while (end < line_raw.size() &&
                   (std::isalnum(static_cast<unsigned char>(line_raw[end])) ||
                    line_raw[end] == '_' || line_raw[end] == '-')) {
                end++;
            }
            if (end > start) {
                return to_lower_str(line_raw.substr(start, end - start));
            }
        }
    }

    // Trim leading whitespace and count indentation
    size_t idx = 0;
    size_t indent = 0;
    while (idx < line_raw.size() && (line_raw[idx] == ' ' || line_raw[idx] == '\t')) {
        indent += (line_raw[idx] == '\t') ? 2 : 1;
        idx++;
    }
    if (idx >= line_raw.size() || indent > 16) return "";

    std::string_view sv = line_raw.substr(idx);
    // Skip regular comments
    if (sv.rfind("//", 0) == 0 || sv.rfind("#", 0) == 0 ||
        sv.rfind("--", 0) == 0 || sv.rfind("/*", 0) == 0 || sv[0] == '*') {
        return "";
    }

    auto read_word = [](std::string_view s, size_t& p) -> std::string_view {
        while (p < s.size() && (s[p] == ' ' || s[p] == '\t')) p++;
        size_t start = p;
        while (p < s.size() &&
               (std::isalnum(static_cast<unsigned char>(s[p])) ||
                s[p] == '_' || s[p] == '.' || s[p] == ':')) {
            p++;
        }
        return s.substr(start, p - start);
    };

    auto strip_qualifier = [](std::string_view sym) -> std::string {
        size_t last_sep = sym.find_last_of(".:");
        if (last_sep != std::string_view::npos && last_sep + 1 < sym.size()) {
            sym = sym.substr(last_sep + 1);
        }
        return to_lower_str(sym);
    };

    size_t p = 0;
    std::string_view w1 = read_word(sv, p);
    if (w1.empty()) return "";

    // Check for Lua `M.foo = function(` or `foo = function(`
    {
        size_t eq_pos = sv.find('=');
        if (eq_pos != std::string_view::npos && eq_pos > p - w1.size()) {
            size_t after_eq = eq_pos + 1;
            std::string_view rhs = read_word(sv, after_eq);
            if (rhs == "function") {
                return strip_qualifier(w1);
            }
        }
    }

    // Skip declaration modifiers (Rust/C++/Python/Lean/JS/TS)
    std::string_view kw = w1;
    for (int step = 0; step < 5; ++step) {
        if (kw == "local" || kw == "pub" || kw == "export" || kw == "default" ||
            kw == "async" || kw == "unsafe" || kw == "static" || kw == "inline" ||
            kw == "virtual" || kw == "constexpr" || kw == "const" || kw == "private" ||
            kw == "protected" || kw == "noncomputable" || kw == "partial" ||
            kw == "scoped" || kw == "extern") {
            // Skip optional `(crate)` or `"C"` after `pub` / `extern`
            while (p < sv.size() && (sv[p] == ' ' || sv[p] == '\t')) p++;
            if (p < sv.size() && (sv[p] == '(' || sv[p] == '"')) {
                char close_c = (sv[p] == '(') ? ')' : '"';
                p++;
                while (p < sv.size() && sv[p] != close_c) p++;
                if (p < sv.size()) p++;
            }
            kw = read_word(sv, p);
        } else {
            break;
        }
    }

    // Direct definition keywords across Lua, Python, Rust, Go, C++, JS/TS, Lean 4
    if (kw == "function" || kw == "fn" || kw == "def" || kw == "func" ||
        kw == "class" || kw == "struct" || kw == "enum" || kw == "trait" ||
        kw == "interface" || kw == "theorem" || kw == "lemma" || kw == "axiom" ||
        kw == "inductive" || kw == "structure" || kw == "abbrev" || kw == "opaque" ||
        kw == "instance" || kw == "type" || kw == "typedef") {
        while (p < sv.size() && (sv[p] == ' ' || sv[p] == '\t')) p++;
        // Go receiver: `func (r *Type) Method(`
        if (kw == "func" && p < sv.size() && sv[p] == '(') {
            while (p < sv.size() && sv[p] != ')') p++;
            if (p < sv.size()) p++;
        }
        std::string_view sym = read_word(sv, p);
        if (!sym.empty()) {
            return strip_qualifier(sym);
        }
    }

    // C / C++ top-level function definition: `<return_type> <name>(...)` at indent <= 4
    if (indent <= 4 && sv.find('(') != std::string_view::npos && sv.back() != ';') {
        size_t paren = sv.find('(');
        // Walk backward from '(' to extract the function identifier
        size_t name_end = paren;
        while (name_end > 0 && (sv[name_end - 1] == ' ' || sv[name_end - 1] == '\t')) name_end--;
        size_t name_start = name_end;
        while (name_start > 0 &&
               (std::isalnum(static_cast<unsigned char>(sv[name_start - 1])) ||
                sv[name_start - 1] == '_' || sv[name_start - 1] == ':')) {
            name_start--;
        }
        if (name_start > 0 && name_end > name_start) {
            // Check that there is a return-type token before name_start
            size_t before = name_start;
            while (before > 0 && (sv[before - 1] == ' ' || sv[before - 1] == '\t' ||
                                  sv[before - 1] == '*' || sv[before - 1] == '&')) {
                before--;
            }
            if (before > 0 && (std::isalnum(static_cast<unsigned char>(sv[before - 1])) ||
                               sv[before - 1] == '_' || sv[before - 1] == '>')) {
                std::string cand = strip_qualifier(sv.substr(name_start, name_end - name_start));
                if (cand != "if" && cand != "for" && cand != "while" && cand != "switch" &&
                    cand != "catch" && cand != "return" && cand != "sizeof" && cand != "alignof") {
                    return cand;
                }
            }
        }
    }

    return "";
}

static double score_symbol_definition(
    std::string_view line_raw,
    std::string_view line_low,
    const std::vector<std::string>& tokens,
    const std::vector<std::string>& subtokens,
    bool* is_symbol_out
) {
    (void)line_low;
    *is_symbol_out = false;
    std::string defined_sym = extract_defined_symbol_fast(line_raw);
    if (defined_sym.empty()) return 0.0;

    if (defined_sym == "if" || defined_sym == "for" || defined_sym == "while" ||
        defined_sym == "switch" || defined_sym == "catch" || defined_sym == "return") {
        return 0.0;
    }

    *is_symbol_out = true;
    double boost = 45.0; // Base structural definition boost

    auto strip_seps = [](std::string_view s) {
        std::string out;
        out.reserve(s.size());
        for (char c : s) {
            if (c != '_' && c != '-') out.push_back(to_lower_ascii(c));
        }
        return out;
    };
    std::string sym_norm = strip_seps(defined_sym);

    // Check if defined_sym matches query tokens or subtokens (including camelCase<->snake_case & typo tolerance)
    for (const auto& tk : tokens) {
        std::string tk_norm = strip_seps(tk);
        if (defined_sym == tk || (!sym_norm.empty() && sym_norm == tk_norm)) {
            return 260.0;
        }
        int max_d = (tk_norm.size() >= 7) ? 2 : 1;
        if (tk_norm.size() >= 5 && bounded_edit_distance(sym_norm, tk_norm, max_d) <= max_d) {
            return 235.0;
        }
        if (defined_sym.find(tk) != std::string::npos || tk.find(defined_sym) != std::string::npos ||
            (!tk_norm.empty() && sym_norm.find(tk_norm) != std::string::npos)) {
            boost = std::max(boost, 175.0);
        }
    }

    if (subtokens.size() > 1) {
        std::vector<std::string> sym_parts = split_subtokens(defined_sym);
        int matched_parts = 0;
        for (const auto& st : subtokens) {
            if (st.size() < 2) continue;
            if (defined_sym.find(st) != std::string::npos) {
                matched_parts++;
            } else {
                for (const auto& sp : sym_parts) {
                    if (sp == st || (st.size() >= 5 && bounded_edit_distance(sp, st, 1) <= 1)) {
                        matched_parts++;
                        break;
                    }
                }
            }
        }
        if (matched_parts > 0) {
            double ratio = static_cast<double>(matched_parts) / static_cast<double>(subtokens.size());
            boost = std::max(boost, 70.0 + ratio * 150.0);
        }
    }

    return boost;
}

// ==============================================================================
// Stage 3: File Filtering, Glob Matching & In-Memory Repository Corpus Cache
// ==============================================================================

static bool is_ignored_dir(std::string_view name) {
    if (name.empty()) return true;
    // Ignore all hidden directories (.git, .lake, .elan, .cargo, .venv, .cache, .agent, etc.)
    if (name[0] == '.' && name != "." && name != "..") return true;
    return name == "node_modules" || name == "target" || name == "build" ||
           name == "__pycache__" || name == "venv" || name == "lake-packages" ||
           name == "logs" || name == "dist" || name == "out" || name == "vendor" ||
           name == "third_party" || name == "deps" || name == "_build" ||
           name == "artifacts" || name == "coverage" || name == "site-packages";
}

static bool is_binary_or_ignored_ext(std::string_view path) {
    size_t dot = path.rfind('.');
    if (dot == std::string_view::npos) return false;
    std::string ext = to_lower_str(path.substr(dot));
    static const std::unordered_set<std::string> bad_exts = {
        ".so", ".o", ".a", ".dylib", ".dll", ".exe", ".bin", ".olean", ".ilean",
        ".trace", ".hash", ".dep", ".d", ".rlib", ".rmeta", ".wasm", ".bc",
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".svg",
        ".zip", ".tar", ".gz", ".xz", ".bz2", ".7z", ".pyc", ".pyo",
        ".jsonl", ".log", ".lock", ".ipynb", ".woff", ".woff2", ".ttf"
    };
    return bad_exts.count(ext) > 0;
}

static bool is_code_source_ext(std::string_view path) {
    size_t dot = path.rfind('.');
    if (dot == std::string_view::npos) return false;
    std::string ext = to_lower_str(path.substr(dot));
    static const std::unordered_set<std::string> code_exts = {
        ".lua", ".py", ".rs", ".cpp", ".cc", ".c", ".h", ".hpp",
        ".go", ".ts", ".tsx", ".js", ".jsx", ".lean", ".sh", ".bash",
        ".zsh", ".rb", ".java", ".zig", ".hs", ".sql", ".vim"
    };
    return code_exts.count(ext) > 0;
}

static std::string glob_to_regex_str(std::string_view glob) {
    std::string rx = "^";
    for (size_t i = 0; i < glob.size(); ++i) {
        char c = glob[i];
        if (c == '*' && i + 1 < glob.size() && glob[i + 1] == '*') {
            rx += ".*";
            ++i;
            if (i + 1 < glob.size() && glob[i + 1] == '/') ++i;
        } else if (c == '*') {
            rx += "[^/]*";
        } else if (c == '?') {
            rx += "[^/]";
        } else if (std::strchr(".+()[]{}^$|\\", c)) {
            rx += '\\';
            rx += c;
        } else {
            rx += c;
        }
    }
    rx += "$";
    return rx;
}

static bool path_matches_locations(
    std::string_view rel_path,
    std::string_view abs_path,
    const std::vector<std::string>& locations,
    bool is_explicit_only = false
) {
    if (locations.empty()) return !is_explicit_only;
    size_t slash = rel_path.rfind('/');
    std::string_view basename = (slash == std::string_view::npos) ? rel_path : rel_path.substr(slash + 1);

    for (const auto& loc_raw : locations) {
        std::string loc = loc_raw;
        while (loc.rfind("./", 0) == 0) loc = loc.substr(2);
        while (!loc.empty() && loc.back() == '/') loc.pop_back();
        if (loc.empty() || loc == ".") return true;

        // 1. Exact file or directory prefix match
        if (rel_path == loc || abs_path == loc || basename == loc) return true;
        if (rel_path.size() > loc.size() &&
            rel_path.rfind(loc, 0) == 0 &&
            rel_path[loc.size()] == '/') {
            return true;
        }
        if (abs_path.size() > loc.size() &&
            abs_path.rfind(loc, 0) == 0 &&
            abs_path[loc.size()] == '/') {
            return true;
        }

        // 2. Glob pattern match (if contains * or ?)
        if (loc.find('*') != std::string::npos || loc.find('?') != std::string::npos) {
            try {
                std::regex rx(glob_to_regex_str(loc), std::regex::icase);
                if (std::regex_match(std::string(rel_path), rx) ||
                    std::regex_match(std::string(basename), rx)) {
                    return true;
                }
            } catch (...) {}
        }

        // 3. Substring path component match (e.g. "agent" matches "nvim/lua/agent/tasks.lua")
        if (rel_path.find(loc) != std::string_view::npos) {
            return true;
        }
    }
    return false;
}

struct CachedFile {
    std::string rel_path;
    std::string abs_path;
    std::string path_low;
    bool is_code_file = false;
    bool is_test_file = false;
    bool is_doc_file = false;
    bool is_core_dir = false;
    bool is_explicit_only = false;
    std::string content_low;
    std::vector<std::string> lines;
    std::vector<std::string> lines_low;
};

struct RepoCorpusCache {
    std::string root_dir;
    std::chrono::steady_clock::time_point loaded_at{};
    std::vector<CachedFile> files;
    std::vector<std::string> vocab;
    std::unordered_set<std::string> visited_abs;
    std::unordered_set<std::string> loaded_explicit_locs;
    size_t total_lines_count = 0;
    size_t total_chars_count = 0;
};

static RepoCorpusCache g_corpus_cache;

static void load_file_into_cache(
    const fs::path& p,
    const std::string& root_dir,
    bool force_include,
    std::unordered_set<std::string>& visited_abs,
    std::unordered_set<std::string>& vocab_set,
    RepoCorpusCache& cache,
    bool is_explicit_only = false
) {
    if (cache.files.size() >= (is_explicit_only ? 10000 : 6000) && !force_include) return; // Hard cap on file count
    std::error_code ec;
    if (!fs::is_regular_file(p, ec)) return;
    std::string abs_p = p.lexically_normal().string();
    if (!visited_abs.insert(abs_p).second) return;

    std::string rel_p = abs_p;
    if (abs_p.rfind(root_dir + "/", 0) == 0) {
        rel_p = abs_p.substr(root_dir.size() + 1);
    }
    if (!force_include && is_binary_or_ignored_ext(rel_p)) return;

    auto fsize = fs::file_size(p, ec);
    if (ec || fsize > 512 * 1024) return; // Skip huge generated files > 512KB

    std::ifstream in(abs_p, std::ios::in | std::ios::binary);
    if (!in.is_open()) return;

    std::string content((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    size_t check_len = std::min<size_t>(content.size(), 4096);
    if (std::memchr(content.data(), '\0', check_len) != nullptr) return;

    CachedFile cf;
    cf.rel_path = std::move(rel_p);
    cf.abs_path = std::move(abs_p);
    cf.path_low = to_lower_str(cf.rel_path);
    cf.is_code_file = is_code_source_ext(cf.rel_path);
    cf.is_test_file = (cf.path_low.find("test") != std::string::npos);
    cf.is_doc_file = (
        (cf.path_low.size() >= 3 && cf.path_low.rfind(".md") == cf.path_low.size() - 3) ||
        (cf.path_low.size() >= 4 && (
            cf.path_low.rfind(".txt") == cf.path_low.size() - 4 ||
            cf.path_low.rfind(".tex") == cf.path_low.size() - 4 ||
            cf.path_low.rfind(".rst") == cf.path_low.size() - 4
        ))
    );
    cf.is_core_dir = (
        cf.path_low.rfind("src/", 0) == 0 ||
        cf.path_low.rfind("lib/", 0) == 0 ||
        cf.path_low.rfind("include/", 0) == 0 ||
        cf.path_low.rfind("c_src/", 0) == 0 ||
        cf.path_low.rfind("nvim/lua/", 0) == 0 ||
        cf.path_low.rfind("bin/", 0) == 0
    );
    cf.is_explicit_only = is_explicit_only;
    cf.content_low = to_lower_str(content);

    size_t start = 0;
    while (start <= content.size()) {
        size_t nl = content.find('\n', start);
        std::string_view line_sv = (nl == std::string::npos)
            ? std::string_view(content).substr(start)
            : std::string_view(content).substr(start, nl - start);
        std::string_view line_low_sv = (nl == std::string::npos)
            ? std::string_view(cf.content_low).substr(start)
            : std::string_view(cf.content_low).substr(start, nl - start);

        if (!line_sv.empty() && line_sv.back() == '\r') {
            line_sv.remove_suffix(1);
            line_low_sv.remove_suffix(1);
        }

        // Collect identifier vocabulary once during cache build (capped at 15,000 words)
        if (!cf.is_test_file && vocab_set.size() < 15000 && line_sv.size() <= 240) {
            size_t ws = 0;
            while (ws < line_low_sv.size()) {
                while (ws < line_low_sv.size() && !is_ident_char(line_low_sv[ws])) ws++;
                size_t we = ws;
                while (we < line_low_sv.size() && is_ident_char(line_low_sv[we])) we++;
                size_t wlen = we - ws;
                if (wlen >= 3 && wlen <= 48 && vocab_set.size() < 15000) {
                    vocab_set.emplace(line_low_sv.substr(ws, wlen));
                }
                ws = we + 1;
            }
        }

        cache.total_lines_count++;
        cache.total_chars_count += line_sv.size();
        cf.lines.emplace_back(line_sv);
        cf.lines_low.emplace_back(line_low_sv);

        if (nl == std::string::npos) break;
        start = nl + 1;
    }

    cache.files.push_back(std::move(cf));
}

static void load_explicit_location_into_cache(
    const std::string& loc_raw,
    const std::string& root_dir,
    std::unordered_set<std::string>& vocab_set,
    RepoCorpusCache& cache
) {
    std::string loc = loc_raw;
    while (loc.rfind("./", 0) == 0) loc = loc.substr(2);
    while (loc.size() > 1 && loc.back() == '/') loc.pop_back();
    if (loc.empty() || loc == ".") return;
    if (!cache.loaded_explicit_locs.insert(loc).second) return;

    std::error_code ec;
    fs::path target_p = fs::path(loc);
    if (!target_p.is_absolute()) {
        fs::path cand = fs::path(root_dir) / target_p;
        if (fs::exists(cand, ec)) {
            target_p = cand;
        }
    }
    if (!fs::exists(target_p, ec)) return;

    bool is_dep_or_external = false;
    std::string abs_target = target_p.lexically_normal().string();
    if (abs_target.rfind(root_dir + "/", 0) != 0 && abs_target != root_dir) {
        is_dep_or_external = true;
    } else if (abs_target.size() > root_dir.size() + 1) {
        std::string rel_t = abs_target.substr(root_dir.size() + 1);
        size_t sl = rel_t.find('/');
        std::string first_seg = (sl == std::string::npos) ? rel_t : rel_t.substr(0, sl);
        if (is_ignored_dir(first_seg)) {
            is_dep_or_external = true;
        }
    }

    if (fs::is_regular_file(target_p, ec)) {
        load_file_into_cache(target_p, root_dir, true, cache.visited_abs, vocab_set, cache, is_dep_or_external);
        return;
    }
    if (!fs::is_directory(target_p, ec)) return;

    auto it = fs::recursive_directory_iterator(
        target_p, fs::directory_options::skip_permission_denied, ec
    );
    auto end = fs::recursive_directory_iterator();
    while (it != end) {
        const fs::path& p = it->path();
        std::string fname = p.filename().string();
        if (it->is_directory(ec)) {
            if (fname == ".git" || fname == ".hg" || fname == ".svn" ||
                fname == "__pycache__" || fname == ".cache" || fname == "build") {
                it.disable_recursion_pending();
            }
        } else if (it->is_regular_file(ec)) {
            load_file_into_cache(p, root_dir, false, cache.visited_abs, vocab_set, cache, is_dep_or_external);
            if (cache.files.size() >= (is_dep_or_external ? 10000 : 6000)) break;
        }
        it.increment(ec);
        if (ec) break;
    }
}

static const RepoCorpusCache& get_or_load_corpus(const std::string& root_dir, const std::vector<std::string>& locations) {
    auto now = std::chrono::steady_clock::now();
    bool cache_valid = (
        g_corpus_cache.root_dir == root_dir &&
        !g_corpus_cache.files.empty() &&
        std::chrono::duration_cast<std::chrono::milliseconds>(now - g_corpus_cache.loaded_at).count() < 4000
    );

    if (!cache_valid) {
        g_corpus_cache = RepoCorpusCache{};
        g_corpus_cache.root_dir = root_dir;
        g_corpus_cache.loaded_at = now;

        std::unordered_set<std::string> vocab_set;
        std::error_code ec;
        auto it = fs::recursive_directory_iterator(
            root_dir, fs::directory_options::skip_permission_denied, ec
        );
        auto end = fs::recursive_directory_iterator();
        while (it != end) {
            const fs::path& p = it->path();
            std::string fname = p.filename().string();
            if (it->is_directory(ec)) {
                if (is_ignored_dir(fname)) {
                    it.disable_recursion_pending();
                }
            } else if (it->is_regular_file(ec)) {
                load_file_into_cache(p, root_dir, false, g_corpus_cache.visited_abs, vocab_set, g_corpus_cache);
                if (g_corpus_cache.files.size() >= 6000) break;
            }
            it.increment(ec);
            if (ec) break;
        }
        g_corpus_cache.vocab.assign(vocab_set.begin(), vocab_set.end());
    }

    // If explicit locations are requested (e.g. `@deps` -> `.lake/packages`, `$VIMRUNTIME/doc`, or a newly created dir),
    // incrementally load any explicit location not yet present in the corpus cache.
    if (!locations.empty()) {
        std::unordered_set<std::string> vocab_set(g_corpus_cache.vocab.begin(), g_corpus_cache.vocab.end());
        size_t prev_files = g_corpus_cache.files.size();
        for (const auto& loc : locations) {
            bool has_match = false;
            for (const auto& cf : g_corpus_cache.files) {
                if (path_matches_locations(cf.rel_path, cf.abs_path, {loc})) {
                    has_match = true;
                    break;
                }
            }
            if (!has_match) {
                load_explicit_location_into_cache(loc, root_dir, vocab_set, g_corpus_cache);
            }
        }
        if (g_corpus_cache.files.size() != prev_files) {
            g_corpus_cache.vocab.assign(vocab_set.begin(), vocab_set.end());
        }
    }

    return g_corpus_cache;
}

struct SearchCandidate {
    std::string path;
    int line = 1;
    int col = 1;
    double score = 0.0;
    std::string match_type; // "symbol", "content", "file"
    std::string description;
};

// ==============================================================================
// Main Hybrid Repository Search Entrypoint
// ==============================================================================

extern "C" const char* synvim_search_repo(
    const char* root_dir_raw,
    const char* query_raw_cstr,
    const char* locations_json_raw,
    int max_results
) {
    if (max_results <= 0) max_results = 50;
    std::string root_dir = trim_str(root_dir_raw ? root_dir_raw : ".");
    while (root_dir.size() > 1 && root_dir.back() == '/') root_dir.pop_back();

    std::string raw_query = trim_str(query_raw_cstr ? query_raw_cstr : "");
    std::vector<std::string> locations = parse_json_string_array(locations_json_raw ? locations_json_raw : "[]");

    const RepoCorpusCache& cache = get_or_load_corpus(root_dir, locations);

    // Fast path for empty query: return top source files matching `locations` immediately
    if (raw_query.empty()) {
        std::ostringstream oss;
        oss << "[";
        int count = 0;
        for (const auto& cf : cache.files) {
            if (!path_matches_locations(cf.rel_path, cf.abs_path, locations, cf.is_explicit_only)) continue;
            if (count > 0) oss << ",";
            oss << "{\"path\":\"" << json_escape(cf.rel_path) << "\","
                << "\"line\":1,\"col\":1,\"score\":100.0,"
                << "\"match_type\":\"file\","
                << "\"description\":\"[FILE] " << json_escape(cf.rel_path) << "\"}";
            if (++count >= max_results) break;
        }
        oss << "]";
        tls_search_json = oss.str();
        return tls_search_json.c_str();
    }

    // Check if query has `:line` suffix (e.g. `tasks.lua:120`) without std::regex
    int explicit_line = -1;
    {
        size_t first_space = raw_query.find(' ');
        std::string_view first_tok = (first_space == std::string::npos)
            ? std::string_view(raw_query)
            : std::string_view(raw_query).substr(0, first_space);
        size_t colon = first_tok.rfind(':');
        if (colon != std::string_view::npos && colon > 0 && colon + 1 < first_tok.size()) {
            bool all_digits = true;
            for (size_t di = colon + 1; di < first_tok.size(); ++di) {
                if (!std::isdigit(static_cast<unsigned char>(first_tok[di]))) {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                std::string file_part(first_tok.substr(0, colon));
                explicit_line = std::stoi(std::string(first_tok.substr(colon + 1)));
                std::string rest_part = (first_space == std::string::npos)
                    ? ""
                    : trim_str(std::string_view(raw_query).substr(first_space + 1));
                locations.push_back(file_part);
                raw_query = rest_part.empty() ? file_part : rest_part;
            }
        }
    }

    // Tokenize query into primary tokens and camelCase/snake_case subtokens
    std::vector<std::string> raw_words;
    {
        std::string cur;
        for (char c : raw_query) {
            if (std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-' || c == '.' || c == ':') {
                cur.push_back(c);
            } else if (!cur.empty()) {
                raw_words.push_back(cur);
                cur.clear();
            }
        }
        if (!cur.empty()) raw_words.push_back(cur);
    }

    std::vector<std::string> tokens;
    std::vector<std::string> subtokens;
    std::unordered_set<std::string> seen_tok, seen_sub;

    for (const auto& rw : raw_words) {
        std::string low = to_lower_str(rw);
        while (!low.empty() && (low.front() == '.' || low.front() == ':' || low.front() == '-')) low.erase(low.begin());
        while (!low.empty() && (low.back() == '.' || low.back() == ':' || low.back() == '-')) low.pop_back();
        if (low.empty()) continue;

        if (!is_stop_word(low) && seen_tok.insert(low).second) {
            tokens.push_back(low);
        }
        for (const auto& st : split_subtokens(rw)) {
            size_t min_st_len = (rw.size() >= 5) ? 3 : 2;
            if (st.size() >= min_st_len && !is_stop_word(st) && seen_sub.insert(st).second) {
                subtokens.push_back(st);
            }
        }
    }

    if (tokens.empty()) {
        for (const auto& rw : raw_words) {
            std::string low = to_lower_str(rw);
            if (!low.empty() && seen_tok.insert(low).second) tokens.push_back(low);
            if (!low.empty() && seen_sub.insert(low).second) subtokens.push_back(low);
        }
    }

    std::string query_low = to_lower_str(raw_query);

    // 1. Score file paths across location-matching files in the cache
    struct ScoredFileRef {
        const CachedFile* cf;
        double path_score;
        int path_col;
        bool path_matched;
        double priority;
    };
    std::vector<ScoredFileRef> active_files;
    active_files.reserve(cache.files.size());

    for (const auto& cf : cache.files) {
        if (!path_matches_locations(cf.rel_path, cf.abs_path, locations, cf.is_explicit_only)) continue;
        PathMatchResult pm = score_filepath(cf.rel_path, raw_query, tokens, subtokens);
        double prio = pm.score + (cf.is_core_dir ? 35.0 : 0.0) + (cf.is_code_file ? 25.0 : 0.0) - (cf.is_test_file ? 80.0 : 0.0);
        active_files.push_back(ScoredFileRef{ &cf, pm.score, pm.col, pm.matched, prio });
    }

    // Sort active files by priority so core source files & path matches are evaluated first
    std::sort(active_files.begin(), active_files.end(), [](const ScoredFileRef& a, const ScoredFileRef& b) {
        if (std::abs(a.priority - b.priority) > 1e-6) return a.priority > b.priority;
        return a.cf->rel_path < b.cf->rel_path;
    });

    // 2. Emit standalone [FILE] candidates for strong path/filename matches
    std::vector<SearchCandidate> results;
    for (const auto& sf : active_files) {
        if (sf.path_matched && (sf.path_score >= 65.0 || raw_query.size() == 1)) {
            results.push_back(SearchCandidate{
                sf.cf->rel_path,
                (explicit_line > 0) ? explicit_line : 1,
                sf.path_col,
                sf.path_score,
                "file",
                "[FILE] " + sf.cf->rel_path
            });
        }
    }

    // For 1-character queries (e.g. user just typed 't'), return path matches immediately without full-text scanning
    if (raw_query.size() <= 1 && explicit_line <= 0) {
        std::sort(results.begin(), results.end(), [](const SearchCandidate& a, const SearchCandidate& b) {
            if (std::abs(a.score - b.score) > 1e-6) return a.score > b.score;
            return a.path < b.path;
        });
        if (static_cast<int>(results.size()) > max_results) results.resize(max_results);
        std::ostringstream oss;
        oss << "[";
        for (size_t i = 0; i < results.size(); ++i) {
            const auto& r = results[i];
            if (i > 0) oss << ",";
            oss << "{\"path\":\"" << json_escape(r.path) << "\","
                << "\"line\":" << r.line << ",\"col\":" << r.col << ","
                << "\"score\":" << std::round(r.score * 10.0) / 10.0 << ","
                << "\"match_type\":\"" << r.match_type << "\","
                << "\"description\":\"" << json_escape(r.description) << "\"}";
        }
        oss << "]";
        tls_search_json = oss.str();
        return tls_search_json.c_str();
    }

    // 3. Combine unique search terms and compute corpus IDF using fast whole-file `content_low.find()`
    std::vector<std::string> all_terms = tokens;
    for (const auto& st : subtokens) {
        if (std::find(all_terms.begin(), all_terms.end(), st) == all_terms.end()) {
            all_terms.push_back(st);
        }
    }

    std::vector<int> doc_freq(all_terms.size(), 0);
    std::vector<int> code_doc_freq(all_terms.size(), 0);

    for (const auto& sf : active_files) {
        const CachedFile& cf = *sf.cf;
        for (size_t ti = 0; ti < all_terms.size(); ++ti) {
            if (!all_terms[ti].empty() && cf.content_low.find(all_terms[ti]) != std::string::npos) {
                doc_freq[ti]++;
                if (!cf.is_test_file) code_doc_freq[ti]++;
            }
        }
    }

    // 3b. Typo-Tolerant Vocabulary Resolution using pre-cached vocabulary (zero per-query vocab extraction!)
    bool any_zero_df = false;
    for (size_t ti = 0; ti < all_terms.size(); ++ti) {
        if (code_doc_freq[ti] == 0 && all_terms[ti].size() >= 4) {
            any_zero_df = true;
            break;
        }
    }
    if (any_zero_df && !cache.vocab.empty()) {
        for (size_t ti = 0; ti < all_terms.size(); ++ti) {
            const std::string& qt = all_terms[ti];
            if (code_doc_freq[ti] > 0 || qt.size() < 4) continue;
            int max_d = (qt.size() >= 7) ? 2 : 1;
            int best_d = max_d + 1;
            std::string best_word;
            for (const auto& vw : cache.vocab) {
                if (vw == qt) continue;
                if (std::abs(static_cast<int>(vw.size()) - static_cast<int>(qt.size())) > max_d) continue;
                if (vw.front() != qt.front() && vw.back() != qt.back()) continue;
                int d = bounded_edit_distance(qt, vw, max_d);
                if (d < best_d || (d == best_d && !best_word.empty() &&
                    std::abs(static_cast<int>(vw.size()) - static_cast<int>(qt.size())) <
                    std::abs(static_cast<int>(best_word.size()) - static_cast<int>(qt.size())))) {
                    best_d = d;
                    best_word = vw;
                }
            }
            if (!best_word.empty() && best_d <= max_d) {
                all_terms[ti] = best_word;
                if (ti < tokens.size()) tokens[ti] = best_word;
                int df_count = 0;
                for (const auto& sf : active_files) {
                    if (sf.cf->content_low.find(best_word) != std::string::npos) {
                        df_count++;
                    }
                }
                doc_freq[ti] = df_count;
                code_doc_freq[ti] = df_count;
            }
        }
    }

    double N_docs = std::max(1.0, static_cast<double>(active_files.size()));
    double avg_line_len = (cache.total_lines_count > 0)
        ? static_cast<double>(cache.total_chars_count) / static_cast<double>(cache.total_lines_count)
        : 50.0;

    std::vector<double> idf(all_terms.size(), 1.0);
    for (size_t ti = 0; ti < all_terms.size(); ++ti) {
        double df = static_cast<double>(doc_freq[ti]);
        idf[ti] = std::max(0.45, std::log(1.0 + (N_docs - df + 0.5) / (df + 0.5)));
    }

    // 4. Score matching lines with whole-file SIMD skip + adaptive ubiquitous-term budget
    constexpr double k1 = 1.5;
    constexpr double b_param = 0.5;
    bool query_mentions_test = (query_low.find("test") != std::string::npos);

    const size_t max_ubiquitous_global_lines = (raw_query.size() <= 2) ? 400 : 1800;
    const size_t max_ubiquitous_per_file_lines = 25;
    size_t ubiquitous_scored_lines = 0;
    int ubiquitous_df_threshold = std::max(5, static_cast<int>(active_files.size()) / 2);

    for (const auto& sf : active_files) {
        const CachedFile& cf = *sf.cf;

        // Fast whole-file skip: check if ANY term in `all_terms` (or `query_low`) exists in `cf.content_low`
        std::vector<size_t> active_term_indices;
        active_term_indices.reserve(all_terms.size());
        bool file_has_rare_term = false;
        for (size_t ti = 0; ti < all_terms.size(); ++ti) {
            if (!all_terms[ti].empty() && cf.content_low.find(all_terms[ti]) != std::string::npos) {
                active_term_indices.push_back(ti);
                if (doc_freq[ti] <= ubiquitous_df_threshold) {
                    file_has_rare_term = true;
                }
            }
        }
        if (active_term_indices.empty() && (query_low.empty() || cf.content_low.find(query_low) == std::string::npos)) {
            continue;
        }
        // If this file only matched ubiquitous terms and we already hit the ubiquitous global cap, skip it
        if (!file_has_rare_term && active_term_indices.size() == 1 &&
            ubiquitous_scored_lines >= max_ubiquitous_global_lines && explicit_line <= 0) {
            continue;
        }

        std::vector<SearchCandidate> file_cands;
        size_t num_lines = cf.lines.size();
        size_t file_ubiquitous_lines = 0;

        for (size_t li = 0; li < num_lines; ++li) {
            const std::string& line_raw = cf.lines[li];
            const std::string& line_low = cf.lines_low[li];
            if (line_raw.empty()) continue;

            double bm25_line = 0.0;
            int matched_terms_on_line = 0;
            bool line_has_rare_term = false;
            int first_match_col = -1;
            size_t min_pos = std::string::npos;
            size_t max_end = 0;

            for (size_t ti : active_term_indices) {
                const std::string& term = all_terms[ti];
                size_t pos = line_low.find(term);
                if (pos == std::string::npos) continue;

                matched_terms_on_line++;
                if (doc_freq[ti] <= ubiquitous_df_threshold) {
                    line_has_rare_term = true;
                }
                if (first_match_col < 0 || static_cast<int>(pos) + 1 < first_match_col) {
                    first_match_col = static_cast<int>(pos) + 1;
                }
                if (pos < min_pos) min_pos = pos;
                if (pos + term.size() > max_end) max_end = pos + term.size();

                int tf = 0;
                bool has_word_boundary = false;
                size_t scan = pos;
                while (scan != std::string::npos) {
                    tf++;
                    if (is_word_boundary_at(line_low, scan, term.size())) {
                        has_word_boundary = true;
                    }
                    scan = line_low.find(term, scan + term.size());
                }

                double dl_norm = (1.0 - b_param) + b_param * (static_cast<double>(line_raw.size()) / avg_line_len);
                double tf_norm = (tf * (k1 + 1.0)) / (tf + k1 * dl_norm);
                double boundary_mult = has_word_boundary ? 1.55 : 1.0;
                double primary_mult = (ti < tokens.size()) ? 1.35 : 1.0;

                bm25_line += idf[ti] * tf_norm * boundary_mult * primary_mult * 28.0;
            }

            if (matched_terms_on_line == 0) {
                if (explicit_line > 0 && static_cast<int>(li + 1) == explicit_line) {
                    first_match_col = 1;
                } else if (!query_low.empty() && line_low.find(query_low) != std::string::npos) {
                    first_match_col = static_cast<int>(line_low.find(query_low)) + 1;
                } else {
                    continue;
                }
            }

            bool is_low_info_hit = (!line_has_rare_term && matched_terms_on_line <= 1);
            if (is_low_info_hit && explicit_line <= 0) {
                if (file_ubiquitous_lines >= max_ubiquitous_per_file_lines ||
                    ubiquitous_scored_lines >= max_ubiquitous_global_lines) {
                    continue;
                }
                file_ubiquitous_lines++;
                ubiquitous_scored_lines++;
            }

            double score = bm25_line;

            // Exact / case-insensitive full query phrase match bonus
            size_t exact_pos = line_raw.find(raw_query);
            if (!raw_query.empty() && exact_pos != std::string::npos) {
                score += 150.0;
                first_match_col = static_cast<int>(exact_pos) + 1;
            } else if (!query_low.empty() && line_low.find(query_low) != std::string::npos) {
                size_t ci_pos = line_low.find(query_low);
                score += 105.0;
                if (first_match_col < 0) first_match_col = static_cast<int>(ci_pos) + 1;
            }

            // Same-line multi-term span proximity bonus
            if (matched_terms_on_line >= 2 && max_end > min_pos) {
                size_t span = max_end - min_pos;
                score += 65.0 / (1.0 + 0.03 * static_cast<double>(span));
            }

            // 5-line sliding window [li - 2, li + 2] multi-term coverage
            if (active_term_indices.size() > 1) {
                size_t w_start = (li >= 2) ? (li - 2) : 0;
                size_t w_end = std::min(num_lines - 1, li + 2);
                int window_hits = 0;
                for (size_t ti : active_term_indices) {
                    const std::string& term = all_terms[ti];
                    for (size_t w = w_start; w <= w_end; ++w) {
                        if (cf.lines_low[w].find(term) != std::string::npos) {
                            window_hits++;
                            break;
                        }
                    }
                }
                double win_cov = static_cast<double>(window_hits) / static_cast<double>(all_terms.size());
                score += (win_cov * win_cov) * 110.0;
            }

            // Structural AST / Symbol definition boost (zero-regex O(1) scanner)
            bool is_symbol = false;
            double sym_boost = score_symbol_definition(line_raw, line_low, tokens, subtokens, &is_symbol);
            score += sym_boost;

            if (sf.path_score > 0.0) {
                score += std::min(120.0, sf.path_score * 0.45);
            }

            if (cf.is_code_file) score += 35.0;
            if (cf.is_core_dir) score += 25.0;
            if (cf.is_doc_file || line_raw.size() > 500) score -= 45.0;
            if (cf.is_test_file && !query_mentions_test) {
                score = score * 0.45 - 120.0;
            }

            std::string_view trimmed_low = line_low;
            while (!trimmed_low.empty() && (trimmed_low.front() == ' ' || trimmed_low.front() == '\t')) {
                trimmed_low.remove_prefix(1);
            }
            if (trimmed_low.rfind("#include", 0) == 0 ||
                trimmed_low.rfind("import ", 0) == 0 ||
                trimmed_low.rfind("from ", 0) == 0 ||
                trimmed_low.find("require(") != std::string_view::npos) {
                score -= 30.0;
            }
            if (trimmed_low.find("= nil") != std::string_view::npos ||
                trimmed_low.find("= null") != std::string_view::npos ||
                trimmed_low.find("= none") != std::string_view::npos) {
                score -= 40.0;
            }

            if (explicit_line > 0 && static_cast<int>(li + 1) == explicit_line) {
                score += 500.0;
            }

            file_cands.push_back(SearchCandidate{
                cf.rel_path,
                static_cast<int>(li + 1),
                std::max(1, first_match_col),
                score,
                is_symbol ? "symbol" : "content",
                trim_str(line_raw)
            });
        }

        // Per-file Non-Maximum Suppression (NMS): keep local maxima outside +/- 2 line radius
        std::sort(file_cands.begin(), file_cands.end(), [](const SearchCandidate& a, const SearchCandidate& b) {
            if (std::abs(a.score - b.score) > 1e-6) return a.score > b.score;
            return a.line < b.line;
        });

        std::vector<int> kept_lines;
        for (const auto& fc : file_cands) {
            bool suppressed = false;
            for (int kl : kept_lines) {
                if (std::abs(fc.line - kl) <= 2 && fc.match_type != "symbol") {
                    suppressed = true;
                    break;
                }
            }
            if (!suppressed) {
                kept_lines.push_back(fc.line);
                results.push_back(fc);
                if (kept_lines.size() >= 6) break;
            }
        }
    }

    // 5. Global Sort & Serialization
    std::sort(results.begin(), results.end(), [](const SearchCandidate& a, const SearchCandidate& b) {
        if (std::abs(a.score - b.score) > 1e-6) return a.score > b.score;
        if (a.path != b.path) return a.path < b.path;
        return a.line < b.line;
    });

    if (static_cast<int>(results.size()) > max_results) {
        results.resize(max_results);
    }

    std::ostringstream oss;
    oss << "[";
    for (size_t i = 0; i < results.size(); ++i) {
        const auto& r = results[i];
        if (i > 0) oss << ",";
        oss << "{\"path\":\"" << json_escape(r.path) << "\","
            << "\"line\":" << r.line << ","
            << "\"col\":" << r.col << ","
            << "\"score\":" << std::round(r.score * 10.0) / 10.0 << ","
            << "\"match_type\":\"" << r.match_type << "\","
            << "\"description\":\"" << json_escape(r.description) << "\"}";
    }
    oss << "]";
    tls_search_json = oss.str();
    return tls_search_json.c_str();
}

extern "C" const char* synvim_search_version(void) {
    return "0.2.0-hybrid-bm25-fzf-c++20";
}
