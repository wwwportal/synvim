#!/usr/bin/env bash
# ==============================================================================
# generate_diagrams.sh: Render PlantUML (.puml) architecture diagrams to SVG/PNG
#
# Usage:
#   ./docs/architecture/generate_diagrams.sh [options] [file1.puml ...]
#
# Options:
#   -f, --format <svg|png|all>    Output format (default: all)
#   -e, --engine <auto|local|docker|kroki>
#                                 Rendering engine to use (default: auto)
#   -o, --output-dir <path>       Output directory (default: docs/architecture)
#   -h, --help                    Display this help message
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"
FORMAT="all"
ENGINE="auto"
FILES=()

# Terminal colors
BOLD="\033[1m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [file1.puml ...]

Options:
  -f, --format <svg|png|all>     Image format to generate (default: all)
  -e, --engine <auto|local|docker|kroki>
                                 Rendering engine (default: auto)
  -o, --output-dir <dir>         Target output directory (default: same as script)
  -h, --help                     Show this help message

Engines:
  local   - Uses local 'plantuml' binary or 'java -jar plantuml.jar'
  docker  - Uses docker image 'plantuml/plantuml'
  kroki   - Streams directly to Kroki PlantUML REST endpoint (no local dependencies)
  auto    - Automatically tries local -> docker -> kroki
EOF
    exit 0
}

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--format)
            FORMAT="$2"
            shift 2
            ;;
        -e|--engine)
            ENGINE="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *.puml)
            FILES+=("$1")
            shift
            ;;
        *)
            echo -e "${RED}Error: Unknown argument: $1${RESET}" >&2
            usage
            ;;
    esac
done

# If no specific files provided, find all *.puml in SCRIPT_DIR
if [[ ${#FILES[@]} -eq 0 ]]; then
    while IFS= read -r -d '' puml_file; do
        FILES+=("$puml_file")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "*.puml" -print0 | sort -z)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No .puml diagram files found in $SCRIPT_DIR.${RESET}"
    exit 0
fi

# Detect engine if set to auto
detect_engine() {
    if [[ "$ENGINE" != "auto" ]]; then
        echo "$ENGINE"
        return
    fi

    if command -v plantuml >/dev/null 2>&1; then
        echo "local"
    elif [[ -n "${PLANTUML_JAR:-}" && -f "${PLANTUML_JAR}" ]] && command -v java >/dev/null 2>&1; then
        echo "local"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
    elif command -v curl >/dev/null 2>&1; then
        echo "kroki"
    else
        echo "none"
    fi
}

RESOLVED_ENGINE=$(detect_engine)

if [[ "$RESOLVED_ENGINE" == "none" ]]; then
    echo -e "${RED}Error: Could not find any rendering mechanism (plantuml, docker, or curl).${RESET}" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo -e "${BOLD}${BLUE}=== synvim Architecture Diagram Generator ===${RESET}"
echo -e "Engine:  ${GREEN}${RESOLVED_ENGINE}${RESET}"
echo -e "Format:  ${GREEN}${FORMAT}${RESET}"
echo -e "Output:  ${GREEN}${OUTPUT_DIR}${RESET}"
echo "--------------------------------------------------"

render_file_kroki() {
    local src="$1"
    local fmt="$2"
    local base
    base="$(basename "$src" .puml)"
    local out="$OUTPUT_DIR/${base}.${fmt}"

    local http_code
    http_code=$(curl -s -w "%{http_code}" -X POST \
        --data-binary "@$src" \
        -H "Content-Type: text/plain" \
        -o "$out" \
        "https://kroki.io/plantuml/${fmt}")

    if [[ "$http_code" == "200" ]]; then
        echo -e "  [${GREEN}✓${RESET}] Generated ${fmt^^}: ${out}"
    else
        rm -f "$out"
        echo -e "  [${RED}✗${RESET}] Failed to render ${fmt^^} for ${src} (HTTP ${http_code})" >&2
        return 1
    fi
}

render_file_local() {
    local src="$1"
    local fmt="$2"
    local base
    base="$(basename "$src" .puml)"

    if command -v plantuml >/dev/null 2>&1; then
        plantuml "-t${fmt}" -o "$OUTPUT_DIR" "$src"
    elif [[ -n "${PLANTUML_JAR:-}" ]] && command -v java >/dev/null 2>&1; then
        java -jar "${PLANTUML_JAR}" "-t${fmt}" -o "$OUTPUT_DIR" "$src"
    fi
    echo -e "  [${GREEN}✓${RESET}] Generated ${fmt^^}: ${OUTPUT_DIR}/${base}.${fmt}"
}

render_file_docker() {
    local src="$1"
    local fmt="$2"
    local base
    base="$(basename "$src" .puml)"
    local abs_src
    abs_src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"

    docker run --rm -v "$(dirname "$abs_src")":/data -v "$OUTPUT_DIR":/out plantuml/plantuml \
        "-t${fmt}" -o /out "/data/$(basename "$src")"
    echo -e "  [${GREEN}✓${RESET}] Generated ${fmt^^}: ${OUTPUT_DIR}/${base}.${fmt}"
}

render_diagram() {
    local src="$1"
    local fmt="$2"

    case "$RESOLVED_ENGINE" in
        kroki)
            render_file_kroki "$src" "$fmt"
            ;;
        local)
            render_file_local "$src" "$fmt"
            ;;
        docker)
            render_file_docker "$src" "$fmt"
            ;;
        *)
            echo -e "${RED}Unsupported engine: ${RESOLVED_ENGINE}${RESET}" >&2
            return 1
            ;;
    esac
}

FORMATS=()
if [[ "$FORMAT" == "all" ]]; then
    FORMATS=("svg" "png")
else
    FORMATS=("$FORMAT")
fi

TOTAL_SUCCESS=0
for f in "${FILES[@]}"; do
    echo -e "${BOLD}Processing $(basename "$f")...${RESET}"
    for fmt in "${FORMATS[@]}"; do
        if render_diagram "$f" "$fmt"; then
            TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
        fi
    done
done

echo "--------------------------------------------------"
echo -e "${BOLD}${GREEN}Successfully generated ${TOTAL_SUCCESS} diagram image(s).${RESET}"
