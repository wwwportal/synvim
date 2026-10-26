#include "dtl_engine.h"

#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <queue>
#include <regex>
#include <sstream>
#include <algorithm>
#include <cctype>

// Thread-local buffers for thread-safe FFI string returns to Lua
static thread_local std::string tls_err_msg;
static thread_local std::string tls_ctd_action;
static thread_local std::string tls_sorted_json;
static thread_local std::string tls_cycle_id;

// ==============================================================================
// Lightweight JSON & Pattern Utilities
// ==============================================================================

// Convert simple glob pattern (e.g. "src/*.py" or "**/*.rs") to regex
static std::string glob_to_regex(const std::string& glob) {
    std::string rx = "^";
    for (size_t i = 0; i < glob.size(); ++i) {
        char c = glob[i];
        if (c == '*' && i + 1 < glob.size() && glob[i + 1] == '*') {
            rx += ".*";
            ++i; // skip second *
            if (i + 1 < glob.size() && glob[i + 1] == '/') {
                rx += "(/.*)?";
                ++i;
            }
        } else if (c == '*') {
            rx += "[^/]*";
        } else if (c == '?') {
            rx += "[^/]";
        } else if (c == '.' || c == '+' || c == '(' || c == ')' || c == '[' || c == ']' ||
                   c == '{' || c == '}' || c == '^' || c == '$' || c == '|' || c == '\\') {
            rx += '\\';
            rx += c;
        } else {
            rx += c;
        }
    }
    rx += "$";
    return rx;
}

static bool matches_pattern(const std::string& path, const std::string& pattern) {
    if (pattern.empty()) return false;
    try {
        // Direct regex if pattern starts with ^ or /
        if (pattern.front() == '^') {
            return std::regex_search(path, std::regex(pattern));
        }
        std::string rx_str = glob_to_regex(pattern);
        if (std::regex_match(path, std::regex(rx_str))) {
            return true;
        }
        // Also check if path ends with pattern (simple suffix matching)
        if (path.size() >= pattern.size() &&
            path.compare(path.size() - pattern.size(), pattern.size(), pattern) == 0) {
            return true;
        }
    } catch (...) {
        return path == pattern;
    }
    return false;
}

// Extract string array for a key from simple JSON object, e.g. "allow": ["a.py", "b.py"]
static std::vector<std::string> extract_json_string_array(const std::string& json, const std::string& key) {
    std::vector<std::string> results;
    std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return results;

    pos = json.find('[', pos);
    if (pos == std::string::npos) return results;

    size_t end_pos = json.find(']', pos);
    if (end_pos == std::string::npos) return results;

    std::string array_content = json.substr(pos + 1, end_pos - pos - 1);
    size_t cur = 0;
    while (true) {
        size_t q1 = array_content.find('"', cur);
        if (q1 == std::string::npos) break;
        size_t q2 = array_content.find('"', q1 + 1);
        if (q2 == std::string::npos) break;
        results.push_back(array_content.substr(q1 + 1, q2 - q1 - 1));
        cur = q2 + 1;
    }
    return results;
}

// Extract single string field from JSON: "key": "value"
static std::string extract_json_field(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return "";

    pos = json.find(':', pos);
    if (pos == std::string::npos) return "";

    size_t quote_start = json.find('"', pos);
    if (quote_start == std::string::npos) return "";

    size_t quote_end = json.find('"', quote_start + 1);
    if (quote_end == std::string::npos) return "";

    return json.substr(quote_start + 1, quote_end - quote_start - 1);
}

// ==============================================================================
// Deontic Verification Implementation
// ==============================================================================

extern "C" DtlValidationResult dtl_validate_patch(
    const char* task_json_raw,
    const char* target_file_raw,
    const char* patch_diff_raw
) {
    std::string task_json = task_json_raw ? task_json_raw : "{}";
    std::string target_file = target_file_raw ? target_file_raw : "";
    std::string patch_diff = patch_diff_raw ? patch_diff_raw : "";

    // Normalize filepath (strip leading ./)
    if (target_file.rfind("./", 0) == 0) {
        target_file = target_file.substr(2);
    }

    // 1. Prohibitions (F): Global inviolable files
    static const std::vector<std::string> global_prohibitions = {
        R"(\.env($|\..*))",
        R"(.*Cargo\.lock$)",
        R"(.*package-lock\.json$)",
        R"(.*yarn\.lock$)",
        R"(.*\.pem$)",
        R"(.*\.key$)",
        R"(.*id_rsa($|\.pub$))"
    };

    for (const auto& pat : global_prohibitions) {
        try {
            if (std::regex_search(target_file, std::regex(pat))) {
                tls_err_msg = "PROHIBITION VIOLATION (F): Write access forbidden on sensitive file: " + target_file;
                tls_ctd_action = "auto_revert;mark_revise";
                return { DTL_ERR_PROHIBITION, tls_err_msg.c_str(), tls_ctd_action.c_str() };
            }
        } catch (...) {}
    }

    // Task-specific Prohibitions (deny / forbid list)
    std::vector<std::string> deny_list = extract_json_string_array(task_json, "deny");
    std::vector<std::string> forbid_list = extract_json_string_array(task_json, "forbid");
    for (const auto& f : forbid_list) deny_list.push_back(f);
    for (const auto& pattern : deny_list) {
        if (matches_pattern(target_file, pattern)) {
            tls_err_msg = "PROHIBITION VIOLATION (F): File '" + target_file + "' matches task deny policy '" + pattern + "'";
            tls_ctd_action = "auto_revert;mark_revise";
            return { DTL_ERR_PROHIBITION, tls_err_msg.c_str(), tls_ctd_action.c_str() };
        }
    }

    // 2. Permissions (P): Explicit allow/modifies list
    std::vector<std::string> allow_list = extract_json_string_array(task_json, "allow");
    if (allow_list.empty()) {
        allow_list = extract_json_string_array(task_json, "modifies");
    }

    if (!allow_list.empty()) {
        bool permitted = false;
        for (const auto& pattern : allow_list) {
            if (matches_pattern(target_file, pattern)) {
                permitted = true;
                break;
            }
        }
        if (!permitted) {
            tls_err_msg = "PERMISSION VIOLATION (P): File '" + target_file + "' is outside task modification scope";
            tls_ctd_action = "revert_patch;mark_revise";
            return { DTL_ERR_PERMISSION, tls_err_msg.c_str(), tls_ctd_action.c_str() };
        }
    }

    // 3. Temporal Invariants (Box): Secret leak detection & hygiene checks
    static const std::vector<std::pair<std::string, std::string>> invariant_rules = {
        { R"(-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----)", "Private key material detected in diff" },
        { R"(AKIA[0-9A-Z]{16})", "AWS Access Key ID detected in diff" },
        { R"(ghp_[0-9a-zA-Z]{36})", "GitHub personal access token detected in diff" },
        { R"(xox[baprs]-[0-9a-zA-Z]{10,48})", "Slack API token detected in diff" }
    };

    for (const auto& rule : invariant_rules) {
        try {
            if (std::regex_search(patch_diff, std::regex(rule.first))) {
                tls_err_msg = "INVARIANT VIOLATION (Box): Safety invariant broken: " + rule.second;
                tls_ctd_action = "purge_diff;alert_human";
                return { DTL_ERR_INVARIANT, tls_err_msg.c_str(), tls_ctd_action.c_str() };
            }
        } catch (...) {}
    }

    // All normative contracts satisfied
    return { DTL_OK, nullptr, nullptr };
}

extern "C" DtlValidationResult dtl_validate_spawned_task(
    const char* parent_task_json_raw,
    const char* target_file_raw,
    const char* stub_text_raw
) {
    std::string task_json = parent_task_json_raw ? parent_task_json_raw : "{}";
    std::string target_file = target_file_raw ? target_file_raw : "";
    std::string stub_text = stub_text_raw ? stub_text_raw : "";

    if (target_file.rfind("./", 0) == 0) {
        target_file = target_file.substr(2);
    }

    // 1. Prohibitions (F): Global inviolable files (.env*, lockfiles, private keys)
    static const std::vector<std::string> global_prohibitions = {
        R"(\.env($|\..*))",
        R"(.*Cargo\.lock$)",
        R"(.*package-lock\.json$)",
        R"(.*yarn\.lock$)",
        R"(.*\.pem$)",
        R"(.*\.key$)",
        R"(.*id_rsa($|\.pub$))"
    };

    for (const auto& pat : global_prohibitions) {
        try {
            if (std::regex_search(target_file, std::regex(pat))) {
                tls_err_msg = "PROHIBITION VIOLATION (F): Spawned task stub forbidden on sensitive file: " + target_file;
                tls_ctd_action = "skip_spawn;alert_human";
                return { DTL_ERR_PROHIBITION, tls_err_msg.c_str(), tls_ctd_action.c_str() };
            }
        } catch (...) {}
    }

    // 2. Task-specific Prohibitions (deny / forbid list)
    std::vector<std::string> deny_list = extract_json_string_array(task_json, "deny");
    std::vector<std::string> forbid_list = extract_json_string_array(task_json, "forbid");
    for (const auto& f : forbid_list) deny_list.push_back(f);
    for (const auto& pattern : deny_list) {
        if (matches_pattern(target_file, pattern)) {
            tls_err_msg = "PROHIBITION VIOLATION (F): Spawned task target '" + target_file + "' matches deny policy '" + pattern + "'";
            tls_ctd_action = "skip_spawn;alert_human";
            return { DTL_ERR_PROHIBITION, tls_err_msg.c_str(), tls_ctd_action.c_str() };
        }
    }

    // 3. Temporal Invariants (Box): Ensure stub text contains no secrets
    static const std::vector<std::pair<std::string, std::string>> invariant_rules = {
        { R"(-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----)", "Private key material detected in spawned task stub" },
        { R"(AKIA[0-9A-Z]{16})", "AWS Access Key ID detected in spawned task stub" },
        { R"(ghp_[0-9a-zA-Z]{36})", "GitHub personal access token detected in spawned task stub" },
        { R"(xox[baprs]-[0-9a-zA-Z]{10,48})", "Slack API token detected in spawned task stub" }
    };

    for (const auto& rule : invariant_rules) {
        try {
            if (std::regex_search(stub_text, std::regex(rule.first))) {
                tls_err_msg = "INVARIANT VIOLATION (Box): " + rule.second;
                tls_ctd_action = "purge_stub;alert_human";
                return { DTL_ERR_INVARIANT, tls_err_msg.c_str(), tls_ctd_action.c_str() };
            }
        } catch (...) {}
    }

    // Note: Permissions (P) allow-list is intentionally bypassed for spawned task stubs
    // because follow-up tasks are meant to be created in other files across the repository
    // (with status:TODO, without auto-starting them).
    return { DTL_OK, nullptr, nullptr };
}

// ==============================================================================
// Topological DAG Sorter & Cycle Detector (Kahn's Algorithm)
// ==============================================================================

struct TaskNode {
    std::string id;
    std::vector<std::string> blocks;     // Outgoing edges (this blocks target)
    std::vector<std::string> depends_on; // Incoming edges (this depends on target)
    int in_degree = 0;
};

extern "C" DtlDagResult dtl_sort_task_dag(const char* tasks_json_raw) {
    std::string json = tasks_json_raw ? tasks_json_raw : "[]";
    std::unordered_map<std::string, TaskNode> nodes;
    std::vector<std::string> insertion_order;

    // Parse array of JSON objects: [{ "id": "task-1", "requires": [...] }, ...]
    std::regex task_obj_regex(R"(\{[^{}]*\})");
    auto begin = std::sregex_iterator(json.begin(), json.end(), task_obj_regex);
    auto end = std::sregex_iterator();

    for (auto it = begin; it != end; ++it) {
        std::string obj_str = it->str();
        std::string id = extract_json_field(obj_str, "id");
        if (id.empty()) {
            id = extract_json_field(obj_str, "task_id");
        }
        if (id.empty()) continue;

        TaskNode node;
        node.id = id;
        node.blocks = extract_json_string_array(obj_str, "blocks");
        node.depends_on = extract_json_string_array(obj_str, "requires");
        if (node.depends_on.empty()) {
            node.depends_on = extract_json_string_array(obj_str, "depends_on");
        }
        if (nodes.find(id) == nodes.end()) {
            insertion_order.push_back(id);
        }
        nodes[id] = node;
    }

    if (nodes.empty()) {
        tls_sorted_json = "[]";
        return { DTL_OK, tls_sorted_json.c_str(), nullptr };
    }

    // Normalize edges bidirectionally:
    // 1. If A blocks B, then B depends_on (requires) A
    // 2. If B depends_on (requires) A, then A blocks B
    for (const auto& id : insertion_order) {
        const auto& node = nodes[id];
        for (const auto& blocked_id : node.blocks) {
            if (nodes.find(blocked_id) != nodes.end()) {
                auto& dep_list = nodes[blocked_id].depends_on;
                if (std::find(dep_list.begin(), dep_list.end(), id) == dep_list.end()) {
                    dep_list.push_back(id);
                }
            }
        }
        for (const auto& req_id : node.depends_on) {
            if (nodes.find(req_id) != nodes.end()) {
                auto& blk_list = nodes[req_id].blocks;
                if (std::find(blk_list.begin(), blk_list.end(), id) == blk_list.end()) {
                    blk_list.push_back(id);
                }
            }
        }
    }

    // Calculate in-degrees based on existing nodes in depends_on / requires
    for (const auto& id : insertion_order) {
        auto& node = nodes[id];
        int deg = 0;
        for (const auto& req_id : node.depends_on) {
            if (nodes.find(req_id) != nodes.end()) {
                deg++;
            }
        }
        node.in_degree = deg;
    }

    // Kahn's algorithm queue (seeded in deterministic insertion_order)
    std::queue<std::string> zero_in_degree_q;
    for (const auto& id : insertion_order) {
        if (nodes[id].in_degree == 0) {
            zero_in_degree_q.push(id);
        }
    }

    std::vector<std::string> sorted_ids;
    while (!zero_in_degree_q.empty()) {
        std::string cur_id = zero_in_degree_q.front();
        zero_in_degree_q.pop();
        sorted_ids.push_back(cur_id);

        for (const auto& blocked_id : nodes[cur_id].blocks) {
            if (nodes.find(blocked_id) != nodes.end()) {
                nodes[blocked_id].in_degree--;
                if (nodes[blocked_id].in_degree == 0) {
                    zero_in_degree_q.push(blocked_id);
                }
            }
        }
    }

    // If cycle detected
    if (sorted_ids.size() < nodes.size()) {
        for (const auto& [id, node] : nodes) {
            if (node.in_degree > 0) {
                tls_cycle_id = id;
                break;
            }
        }
        return { DTL_ERR_CYCLE, nullptr, tls_cycle_id.c_str() };
    }

    // Serialize sorted IDs to JSON
    std::ostringstream ss;
    ss << "[";
    for (size_t i = 0; i < sorted_ids.size(); ++i) {
        ss << "\"" << sorted_ids[i] << "\"";
        if (i + 1 < sorted_ids.size()) ss << ", ";
    }
    ss << "]";
    tls_sorted_json = ss.str();

    return { DTL_OK, tls_sorted_json.c_str(), nullptr };
}

extern "C" const char* dtl_version(void) {
    return "0.1.0-dtl-c++20";
}
