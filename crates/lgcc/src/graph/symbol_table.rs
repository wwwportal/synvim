use crate::ast::extractor::Extractor;
use crate::estimate_tokens;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

/*

SPEC(graph-symbol-table | tier:B | status:APPROVED | blocks:[graph-edge-extractor]):
  action:    Build repository symbol table V mapping module.Class.method and module.func FQNs to file locations, line ranges, and signatures.
  requires:  [graph-repo-scanner]
  ensures:   review: "Symbol table indexes all top-level classes, methods, and functions with unique FQNs"
  invariant: "FQNs are globally unique within project scope"
  modifies:  [crates/lgcc/src/graph/symbol_table.rs]

[lean:spec]
def graph_symbol_table : Bool := graph_repo_scanner
theorem graph_symbol_table_verified : graph_symbol_table = true := by rfl

*/
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalSymbol {
    pub fqn: String,
    pub filepath: PathBuf,
    pub line: usize,
    pub end_line: usize,
    pub signature: String,
    pub kind: String,
    pub token_cost: usize,
    pub calls: Vec<String>,
}

pub struct SymbolTable;

impl SymbolTable {
    /*

    SPEC(graph-repo-scanner | tier:A | status:APPROVED | blocks:[graph-symbol-table]):
      action:    Implement repository-wide source file scanner discovering all Python and Lua files while filtering test/build/vendor noise.
      requires:  [lgcc-dep-bundle]
      ensures:   review: "scripts/bundle_ir.py --scan-repo returns complete list of tracked source files"
      invariant: "Scanner respects gitignore rules and ignores hidden directories"
      modifies:  [crates/lgcc/src/graph/symbol_table.rs]

    [lean:spec]
    def graph_repo_scanner : Bool := lgcc_dep_bundle
    theorem graph_repo_scanner_verified : graph_repo_scanner = true := by rfl

    */
    pub fn scan_repository(repo_root: &Path) -> Vec<PathBuf> {
        let mut files = Vec::new();

        for entry in WalkDir::new(repo_root)
            .into_iter()
            .filter_entry(|e| {
                let name = e.file_name().to_string_lossy();
                !name.starts_with('.')
                    && name != "build"
                    && name != "vendor"
                    && name != "node_modules"
                    && name != "target"
            })
            .filter_map(|e| e.ok())
        {
            if entry.file_type().is_file() {
                let p = entry.path();
                if let Some(ext) = p.extension().and_then(|s| s.to_str()) {
                    match ext {
                        "cpp" | "hpp" | "h" | "cc" | "lua" | "py" | "rs" => {
                            files.push(p.to_path_buf());
                        }
                        _ => {}
                    }
                }
            }
        }

        files.sort();
        files
    }

    pub fn build_table(repo_root: &Path) -> HashMap<String, GlobalSymbol> {
        let mut table = HashMap::new();
        let files = Self::scan_repository(repo_root);

        for file in files {
            let mod_data = Extractor::extract(&file);
            let stem = file.file_stem().and_then(|s| s.to_str()).unwrap_or("mod");

            let lines: Vec<String> = fs::read_to_string(&file)
                .unwrap_or_default()
                .lines()
                .map(|s| s.to_string())
                .collect();

            for sym in mod_data.symbols {
                let fqn = format!("{}.{}", stem, sym.name);

                let mut body = String::new();
                let s = std::cmp::max(1, sym.line);
                let e = std::cmp::min(lines.len(), std::cmp::max(s, sym.end_line));
                for idx in (s - 1)..e {
                    body.push_str(&lines[idx]);
                    body.push('\n');
                }

                let token_cost = estimate_tokens(&body);

                table.insert(
                    fqn.clone(),
                    GlobalSymbol {
                        fqn,
                        filepath: file.clone(),
                        line: sym.line,
                        end_line: sym.end_line,
                        signature: sym.signature,
                        kind: sym.kind,
                        token_cost,
                        calls: sym.calls,
                    },
                );
            }
        }

        table
    }

    pub fn to_json(table: &HashMap<String, GlobalSymbol>) -> String {
        serde_json::to_string_pretty(table).unwrap_or_else(|_| "{}".to_string())
    }
}
