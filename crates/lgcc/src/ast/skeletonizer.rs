use crate::{count_braces_outside_strings, estimate_tokens};
use regex::Regex;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Default)]
pub struct SkeletonMetrics {
    pub orig_chars: usize,
    pub skel_chars: usize,
    pub orig_tokens: usize,
    pub skel_tokens: usize,
    pub orig_lines: usize,
    pub skel_lines: usize,
    pub char_reduction: f64,
    pub token_reduction: f64,
}

pub struct Skeletonizer;

impl Skeletonizer {
    /*

    SPEC(ir-contract-skeletonizer | tier:A | status:APPROVED | blocks:[lgcc-dep-bundle]):
      action:    Replace function and method bodies with stubs while retaining complete type annotations, docstring invariants, and interface definitions.
      requires:  [ir-ast-extractor]
      ensures:   review: "Skeletonizer achieves >70% character and token reduction on target modules while preserving all exported signatures"
      invariant: "Exported public signatures remain byte-identical before and after skeletonization"
      modifies:  [crates/lgcc/src/ast/skeletonizer.rs]

    [lean:spec]
    def ir_contract_skeletonizer : Bool := ir_ast_extractor
    theorem ir_contract_skeletonizer_verified : ir_contract_skeletonizer = true := by rfl

    */
    pub fn skeletonize(path: &Path) -> String {
        let content = match fs::read_to_string(path) {
            Ok(c) => c,
            Err(_) => return String::new(),
        };

        let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
        match ext {
            "cpp" | "hpp" | "h" | "cc" | "cxx" => Self::skeletonize_cpp(&content),
            "lua" => Self::skeletonize_lua(&content),
            "py" => Self::skeletonize_python(&content),
            "rs" => Self::skeletonize_rust(&content),
            _ => content,
        }
    }

    pub fn compute_metrics(path: &Path) -> SkeletonMetrics {
        let orig = fs::read_to_string(path).unwrap_or_default();
        let skel = Self::skeletonize(path);

        let orig_chars = orig.len();
        let skel_chars = skel.len();
        let orig_tokens = estimate_tokens(&orig);
        let skel_tokens = estimate_tokens(&skel);
        let orig_lines = orig.lines().count();
        let skel_lines = skel.lines().count();

        let char_reduction = if orig_chars > 0 {
            (1.0 - (skel_chars as f64 / orig_chars as f64)) * 100.0
        } else {
            0.0
        };

        let token_reduction = if orig_tokens > 0 {
            (1.0 - (skel_tokens as f64 / orig_tokens as f64)) * 100.0
        } else {
            0.0
        };

        SkeletonMetrics {
            orig_chars,
            skel_chars,
            orig_tokens,
            skel_tokens,
            orig_lines,
            skel_lines,
            char_reduction,
            token_reduction,
        }
    }

    fn skeletonize_cpp(content: &str) -> String {
        let mut result = String::new();
        let mut brace_depth = 0;
        let mut namespace_depth = 0;
        let mut in_fn_body = false;

        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if trimmed.starts_with("//") && !trimmed.starts_with("///") {
                continue;
            }

            let (open_b, close_b) = count_braces_outside_strings(line);

            if !in_fn_body && trimmed.starts_with("namespace ") && open_b > 0 {
                namespace_depth += 1;
                brace_depth += open_b - close_b;
                result.push_str(line);
                result.push('\n');
                continue;
            }

            if !in_fn_body && brace_depth == namespace_depth {
                if open_b > 0
                    && !trimmed.contains("class ")
                    && !trimmed.contains("struct ")
                    && !trimmed.contains("enum ")
                    && !trimmed.contains("namespace ")
                {
                    if let Some(brace_pos) = line.rfind('{') {
                        let is_init = line[..brace_pos].contains('=');
                        result.push_str(&line[..brace_pos]);
                        if is_init {
                            result.push_str("{ /* init */ };\n");
                        } else {
                            result.push_str(" { /* stub */ }\n");
                        }
                        brace_depth += open_b - close_b;
                        if brace_depth > namespace_depth {
                            in_fn_body = true;
                        }
                        continue;
                    }
                }
            }

            if in_fn_body {
                brace_depth += open_b - close_b;
                if brace_depth <= namespace_depth {
                    brace_depth = namespace_depth;
                    in_fn_body = false;
                }
                continue;
            }

            brace_depth += open_b - close_b;
            result.push_str(line);
            result.push('\n');
        }

        result
    }

    fn skeletonize_lua(content: &str) -> String {
        let mut result = String::new();
        let mut in_block = false;
        let mut block_indent = 0;
        let mut block_closer = "end";

        let fn_re = Regex::new(r"^\s*(local\s+function\s+([a-zA-Z0-9_]+)\s*\((.*?)\)|function\s+([a-zA-Z0-9_\.:]+)\s*\((.*?)\)|(?:local\s+)?([a-zA-Z0-9_\.:]+)\s*=\s*function\s*\((.*?)\))").unwrap();
        let cmd_re = Regex::new(r"^\s*vim\.api\.nvim_create_(user_command|autocmd)\s*\(").unwrap();

        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            let indent = line.chars().take_while(|c| *c == ' ' || *c == '\t').count();

            if !in_block {
                if trimmed.starts_with("--") && !trimmed.starts_with("---") {
                    continue;
                }

                if fn_re.is_match(line) {
                    if trimmed.ends_with("end") {
                        result.push_str(line);
                        result.push('\n');
                    } else {
                        result.push_str(line);
                        result.push_str(" -- [stub] end\n");
                        in_block = true;
                        block_indent = indent;
                        block_closer = "end";
                    }
                    continue;
                }

                if indent == 0 && cmd_re.is_match(line) {
                    result.push_str(line);
                    result.push_str(" -- [stub] })\n");
                    in_block = true;
                    block_indent = indent;
                    block_closer = "})";
                    continue;
                }

                if indent == 0 && trimmed.ends_with('{') && !trimmed.contains("function") {
                    result.push_str(line);
                    result.push_str(" -- [table] }\n");
                    in_block = true;
                    block_indent = indent;
                    block_closer = "}";
                    continue;
                }

                result.push_str(line);
                result.push('\n');
            } else {
                if indent == block_indent {
                    if block_closer == "end"
                        && (trimmed == "end"
                            || trimmed.starts_with("end)")
                            || trimmed.starts_with("end,"))
                    {
                        in_block = false;
                    } else if block_closer == "})"
                        && (trimmed == "})" || trimmed.starts_with("})"))
                    {
                        in_block = false;
                    } else if block_closer == "}"
                        && (trimmed == "}" || trimmed.starts_with("}"))
                    {
                        in_block = false;
                    }
                }
            }
        }

        if result.is_empty() {
            content.to_string()
        } else {
            result
        }
    }

    fn skeletonize_python(content: &str) -> String {
        let mut result = String::new();
        let mut in_docstring = false;
        let mut in_def = false;
        let mut def_indent = 0;

        let def_re = Regex::new(r"^([ \t]*)(?:async[ \t]+)?def[ \t]+[a-zA-Z0-9_]+\s*\([^)]*\)").unwrap();

        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }

            let indent = line.chars().take_while(|c| *c == ' ' || *c == '\t').count();

            if def_re.is_match(line) {
                result.push_str(line);
                result.push('\n');
                in_def = true;
                def_indent = indent;
                continue;
            }

            if in_def {
                if indent <= def_indent {
                    in_def = false;
                    result.push_str(line);
                    result.push('\n');
                } else {
                    if line.contains("\"\"\"") || line.contains("'''") {
                        result.push_str(line);
                        result.push('\n');
                        in_docstring = !in_docstring;
                    } else if in_docstring {
                        result.push_str(line);
                        result.push('\n');
                    } else if !result.ends_with("    ...\n") {
                        result.push_str(&" ".repeat(def_indent + 4));
                        result.push_str("...\n");
                    }
                }
            } else {
                result.push_str(line);
                result.push('\n');
            }
        }

        result
    }

    fn skeletonize_rust(content: &str) -> String {
        let mut result = String::new();
        let mut brace_depth = 0;
        let mut in_fn_header = false;
        let mut in_fn_body = false;
        let mut fn_entry_brace = 0;

        let fn_re = Regex::new(r#"^[ \t]*(?:pub[ \t]+)?(?:unsafe[ \t]+)?(?:extern[ \t]+"C"[ \t]+)?fn[ \t]+[a-zA-Z0-9_]+\s*\("#).unwrap();

        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if trimmed.starts_with("//") && !trimmed.starts_with("///") {
                continue;
            }

            let (open_b, close_b) = count_braces_outside_strings(line);

            if !in_fn_body && (in_fn_header || fn_re.is_match(line)) {
                if open_b > 0 {
                    if let Some(bpos) = line.rfind('{') {
                        result.push_str(&line[..bpos]);
                        result.push_str("{ /* stub */ }\n");
                        fn_entry_brace = brace_depth;
                        brace_depth += open_b - close_b;
                        in_fn_header = false;
                        if brace_depth > fn_entry_brace {
                            in_fn_body = true;
                        }
                        continue;
                    }
                } else if trimmed.ends_with(';') {
                    in_fn_header = false;
                    result.push_str(line);
                    result.push('\n');
                    continue;
                } else {
                    in_fn_header = true;
                    result.push_str(line);
                    result.push('\n');
                    continue;
                }
            }

            if in_fn_body {
                brace_depth += open_b - close_b;
                if brace_depth <= fn_entry_brace {
                    brace_depth = fn_entry_brace;
                    in_fn_body = false;
                }
                continue;
            }

            brace_depth += open_b - close_b;
            result.push_str(line);
            result.push('\n');
        }

        result
    }
}
