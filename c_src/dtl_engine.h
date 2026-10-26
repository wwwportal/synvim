#ifndef SYNVIM_DTL_ENGINE_H
#define SYNVIM_DTL_ENGINE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Status codes representing normative outcomes in Deontic Temporal Logic:
 * - DTL_OK: All obligations, permissions, and invariants satisfied.
 * - DTL_ERR_PROHIBITION: Prohibition (F) violated (e.g. forbidden file or secret key).
 * - DTL_ERR_PERMISSION: Permission (P) violated (e.g. file outside task allow-list).
 * - DTL_ERR_INVARIANT: Temporal Invariant (Box) broken.
 * - DTL_ERR_CYCLE: Temporal deadlock / cyclic dependency detected in task DAG.
 * - DTL_ERR_SYNTAX: Malformed task contract or JSON payload.
 */
typedef enum {
    DTL_OK              = 0,
    DTL_ERR_PROHIBITION = 1,
    DTL_ERR_PERMISSION  = 2,
    DTL_ERR_INVARIANT   = 3,
    DTL_ERR_CYCLE       = 4,
    DTL_ERR_SYNTAX      = 5
} DtlStatusCode;

/**
 * Result structure returned by dtl_validate_patch().
 * Pointers reference thread-local buffers and remain valid until the next FFI call.
 */
typedef struct {
    DtlStatusCode code;
    const char* message;       // Descriptive human-readable violation message (or NULL if OK)
    const char* ctd_action;    // Contrary-to-duty repair action: "revert_and_revise", "auto_revert", "abort"
} DtlValidationResult;

/**
 * Result structure returned by dtl_sort_task_dag().
 */
typedef struct {
    DtlStatusCode code;
    const char* sorted_ids_json; // JSON array of sorted task IDs (e.g. ["task-1", "task-2"])
    const char* cycle_task_id;   // Offending task ID involved in cycle (or NULL if DAG is acyclic)
} DtlDagResult;

/**
 * Validates a proposed code patch against task-level normative contracts:
 * - Permissions (P): checks if target_file matches task allow patterns
 * - Prohibitions (F): checks against global forbidden files and task deny patterns
 * - Invariants (Box): scans patch diff for secret leakage, destructive wipes, or forbidden tokens
 *
 * @param task_json JSON object representing the task contract (allow, deny, invariant, id, etc.)
 * @param target_file Relative or absolute path of the file being modified
 * @param patch_diff Unified diff or new content proposed by the agent
 * @return DtlValidationResult with status, diagnostic, and CTD repair recommendation
 */
DtlValidationResult dtl_validate_patch(
    const char* task_json,
    const char* target_file,
    const char* patch_diff
);

/**
 * Performs topological sort and cycle detection over a collection of tasks.
 *
 * @param tasks_json JSON array of task objects (each with id, blocks, depends_on/requires)
 * @return DtlDagResult with sorted list or cycle error
 */
DtlDagResult dtl_sort_task_dag(const char* tasks_json);

/**
 * Validates a spawned follow-up task stub created elsewhere in the repository
 * during task execution.
 *
 * Task creation (status:TODO stub only, never auto-start) is permitted across
 * any repository file provided it does not target globally forbidden files
 * (.env*, *.pem, *.key, lockfiles) or task-specific deny patterns, and does not
 * contain secret material.
 *
 * @param parent_task_json JSON object of parent task policy (deny/forbid patterns)
 * @param target_file Relative or absolute path where the new task stub is placed
 * @param stub_text The generated comment stub lines
 * @return DtlValidationResult (DTL_OK if allowed, or prohibition/invariant error)
 */
DtlValidationResult dtl_validate_spawned_task(
    const char* parent_task_json,
    const char* target_file,
    const char* stub_text
);

/**
 * Returns library version string.
 */
const char* dtl_version(void);

#ifdef __cplusplus
}
#endif

#endif // SYNVIM_DTL_ENGINE_H
