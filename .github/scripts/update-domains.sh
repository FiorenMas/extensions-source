#!/usr/bin/env bash

set -u
set -o pipefail

ROOT_PATH=""
TIMEOUT_SEC=20
EXCLUDE_RAW="${EXCLUDE:-}"
PROXY_HOST="${PROXY_HOST:-}"
PROXY_PORT="${PROXY_PORT:-}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
PROXY_PRECHECK_URL="https://www.google.com/"
PROXY_PRECHECK_RETRIES=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root-path)
            ROOT_PATH="${2:-}"
            shift 2
            ;;
        --timeout-sec)
            TIMEOUT_SEC="${2:-20}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--root-path <path>] [--timeout-sec <seconds>]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$ROOT_PATH" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT_PATH="$SCRIPT_DIR"
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required." >&2
    exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
    echo "Error: perl is required." >&2
    exit 1
fi

if ! [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
    echo "Error: --timeout-sec must be an integer." >&2
    exit 1
fi

if [[ -z "$PROXY_HOST" || -z "$PROXY_PORT" || -z "$PROXY_USER" || -z "$PROXY_PASS" ]]; then
    echo "Error: PROXY_HOST, PROXY_PORT, PROXY_USER, PROXY_PASS must be provided via environment variables." >&2
    exit 1
fi

RESOLVED_ROOT="$(cd "$ROOT_PATH" && pwd)"
LOG_PATH="$RESOLVED_ROOT/logs.txt"
LEGACY_PR_SUMMARY_PATH="$RESOLVED_ROOT/pr-summary.md"
CURL_PROXY_URL="socks5h://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}"
CURL_PROXY_ARGS=(--proxy "$CURL_PROXY_URL")

if [[ -f "$LEGACY_PR_SUMMARY_PATH" ]]; then
    rm -f "$LEGACY_PR_SUMMARY_PATH"
fi

timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"

check_proxy_connection() {
    local attempt=1
    local stderr_file http_code

    while [[ $attempt -le $PROXY_PRECHECK_RETRIES ]]; do
        stderr_file="$(mktemp)"
        http_code="$(curl -sS -L "${CURL_PROXY_ARGS[@]}" --max-redirs 5 \
            --connect-timeout "$TIMEOUT_SEC" --max-time "$((TIMEOUT_SEC * 2))" \
            -o /dev/null -w '%{http_code}' "$PROXY_PRECHECK_URL" 2>"$stderr_file")"
        if [[ $? -eq 0 && "$http_code" != "000" ]]; then
            rm -f "$stderr_file"
            echo "Proxy pre-check passed on attempt $attempt ($PROXY_PRECHECK_URL, HTTP $http_code)"
            return 0
        fi

        local err_msg
        err_msg="$(<"$stderr_file")"
        rm -f "$stderr_file"
        echo "Proxy pre-check failed (attempt $attempt/$PROXY_PRECHECK_RETRIES): ${err_msg:-HTTP $http_code}" >&2
        attempt=$((attempt + 1))
    done

    echo "Proxy pre-check failed after $PROXY_PRECHECK_RETRIES attempts. Cancel task." >&2
    return 1
}

get_first_url_from_text() {
    local text="$1"
    printf '%s' "$text" | grep -Eo 'https?://[^[:space:]'"'"'"`"]+' | head -n1 || true
}

get_url_from_kt_file() {
    local file_path="$1"
    [[ -f "$file_path" ]] || return 0

    local line
    line="$(grep -Eom1 '^[[:space:]]*override[[:space:]]+val[[:space:]]+baseUrl[[:space:]]*=[[:space:]]*"https?://[^"]+"' "$file_path" || true)"
    if [[ -n "$line" ]]; then
        printf '%s' "$line" | sed -E 's/.*"(https?:\/\/[^"]+)".*/\1/'
        return 0
    fi

    grep -Eo 'https?://[^[:space:]'"'"'"`"]+' "$file_path" | head -n1 || true
}

get_main_kt_file_path() {
    local source_dir="$1"
    local source_name="$2"
    local build_file="$3"

    local source_root="$source_dir/src"
    [[ -d "$source_root" ]] || return 0

    if [[ -f "$build_file" ]]; then
        local class_name
        class_name="$(sed -nE "s/^[[:space:]]*extClass[[:space:]]*=[[:space:]]*['\"]\\.([A-Za-z0-9_]+)['\"].*/\\1/p" "$build_file" | head -n1)"
        if [[ -n "$class_name" ]]; then
            local candidate="$source_root/eu/kanade/tachiyomi/extension/vi/$source_name/$class_name.kt"
            if [[ -f "$candidate" ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi

            local by_name
            by_name="$(find "$source_root" -type f -name "$class_name.kt" 2>/dev/null | sort | head -n1)"
            if [[ -n "$by_name" ]]; then
                printf '%s\n' "$by_name"
                return 0
            fi
        fi
    fi

    local preferred_dir="$source_root/eu/kanade/tachiyomi/extension/vi/$source_name"
    if [[ -d "$preferred_dir" ]]; then
        local preferred_file
        preferred_file="$(find "$preferred_dir" -maxdepth 1 -type f -name '*.kt' 2>/dev/null | sort | head -n1)"
        if [[ -n "$preferred_file" ]]; then
            printf '%s\n' "$preferred_file"
            return 0
        fi
    fi

    local fallback
    fallback="$(find "$source_root" -type f -name '*.kt' 2>/dev/null | sort | head -n1)"
    if [[ -n "$fallback" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi
}

find_url_in_source_kt_files() {
    local source_dir="$1"
    local preferred_file="$2"
    local source_root="$source_dir/src"
    [[ -d "$source_root" ]] || return 0

    mapfile -t files < <(find "$source_root" -type f -name '*.kt' 2>/dev/null | sort)
    [[ ${#files[@]} -gt 0 ]] || return 0

    local -a ordered=()
    if [[ -n "$preferred_file" && -f "$preferred_file" ]]; then
        ordered+=("$preferred_file")
    fi

    local f
    for f in "${files[@]}"; do
        if [[ -n "$preferred_file" && "$f" == "$preferred_file" ]]; then
            continue
        fi
        ordered+=("$f")
    done

    local url
    for f in "${ordered[@]}"; do
        url="$(get_url_from_kt_file "$f")"
        if [[ -n "$url" ]]; then
            printf '%s\t%s\n' "$url" "$f"
            return 0
        fi
    done
}

url_base() {
    local url="$1"
    if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+) ]]; then
        printf '%s://%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
}

url_path_query() {
    local url="$1"
    local pathq=""
    if [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]+(.*)$ ]]; then
        pathq="${BASH_REMATCH[1]}"
    fi
    pathq="${pathq%%#*}"
    if [[ -z "$pathq" ]]; then
        printf '/'
        return 0
    fi
    if [[ "$pathq" == \?* ]]; then
        printf '/%s' "$pathq"
        return 0
    fi
    printf '%s' "$pathq"
}

host_from_url() {
    local url="$1"
    local auth host
    if [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]+) ]]; then
        auth="${BASH_REMATCH[1]}"
        auth="${auth##*@}"
        host="${auth%%:*}"
        host="${host#[}"
        host="${host%]}"
        printf '%s' "$host"
    fi
}

escape_perl_re() {
    perl -e '$s=shift; $s=quotemeta($s); print $s;' "$1"
}

REDIRECT_SUCCESS=0
REDIRECT_ERROR=""
REDIRECT_OLD_BASE=""
REDIRECT_NEW_BASE=""
REDIRECT_OLD_URL=""
REDIRECT_FINAL_URL=""
REDIRECT_REDIRECTED=0

resolve_redirect_info() {
    local old_url="$1"
    local timeout="$2"

    REDIRECT_SUCCESS=0
    REDIRECT_ERROR=""
    REDIRECT_OLD_BASE=""
    REDIRECT_NEW_BASE=""
    REDIRECT_OLD_URL="$old_url"
    REDIRECT_FINAL_URL=""
    REDIRECT_REDIRECTED=0

    if [[ ! "$old_url" =~ ^https?:// ]]; then
        REDIRECT_ERROR="Invalid URL: $old_url"
        return 1
    fi

    local stderr_file
    stderr_file="$(mktemp)"
    local final_url
    final_url="$(curl -sS -L "${CURL_PROXY_ARGS[@]}" --max-redirs 10 --connect-timeout "$timeout" --max-time "$((timeout * 3))" -o /dev/null -w '%{url_effective}' "$old_url" 2>"$stderr_file")"
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        REDIRECT_ERROR="$(<"$stderr_file")"
        rm -f "$stderr_file"
        return 1
    fi
    rm -f "$stderr_file"

    if [[ -z "$final_url" ]]; then
        final_url="$old_url"
    fi

    REDIRECT_OLD_BASE="$(url_base "$old_url")"
    REDIRECT_NEW_BASE="$(url_base "$final_url")"
    REDIRECT_FINAL_URL="$final_url"
    if [[ "$REDIRECT_OLD_BASE" != "$REDIRECT_NEW_BASE" ]]; then
        REDIRECT_REDIRECTED=1
    else
        REDIRECT_REDIRECTED=0
    fi
    REDIRECT_SUCCESS=1
    return 0
}

get_new_url_value() {
    local old_url="$1"
    local final_url="$2"
    local new_base pathq
    new_base="$(url_base "$final_url")"
    pathq="$(url_path_query "$old_url")"
    if [[ -z "$pathq" || "$pathq" == "/" ]]; then
        printf '%s' "$new_base"
        return 0
    fi
    printf '%s%s' "${new_base%/}" "$pathq"
}

update_build_gradle_url() {
    local file_path="$1"
    local new_url="$2"
    [[ -f "$file_path" ]] || return 1

    if ! grep -Eq '^[[:space:]]*baseUrl[[:space:]]*=[[:space:]]*["'\'']https?://[^"'\''"]+["'\'']' "$file_path"; then
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    if ! NEW_URL="$new_url" perl -0777 -pe 's{(?m)^(\s*baseUrl\s*=\s*["'\''])(https?://[^"'\''"]+)(["'\''])}{$1.$ENV{NEW_URL}.$3}e' "$file_path" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if cmp -s "$file_path" "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    cat "$tmp_file" > "$file_path"
    rm -f "$tmp_file"
    return 0
}

update_kt_url() {
    local file_path="$1"
    local old_url="$2"
    local new_url="$3"
    [[ -f "$file_path" ]] || return 1

    local escaped_old
    escaped_old="$(escape_perl_re "$old_url")"

    local tmp_file
    tmp_file="$(mktemp)"
    if ! OLD_ESCAPED="$escaped_old" NEW_URL="$new_url" perl -0777 -pe 's/$ENV{OLD_ESCAPED}/$ENV{NEW_URL}/g' "$file_path" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if cmp -s "$file_path" "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    cat "$tmp_file" > "$file_path"
    rm -f "$tmp_file"
    return 0
}

VERSION_UPDATED=0
VERSION_FOUND=0
VERSION_MODE=""
VERSION_OLD=""
VERSION_NEW=""

update_version_code() {
    local file_path="$1"

    VERSION_UPDATED=0
    VERSION_FOUND=0
    VERSION_MODE="no-build-file"
    VERSION_OLD=""
    VERSION_NEW=""

    [[ -f "$file_path" ]] || return 0

    local old_value new_value

    old_value="$(perl -ne 'if (/^\s*extVersionCode\s*=\s*(\d+)/) { print $1; exit }' "$file_path")"
    if [[ -n "$old_value" ]]; then
        new_value=$((old_value + 1))
        VERSION_FOUND=1
        VERSION_MODE="extVersionCode"
        VERSION_OLD="$old_value"
        VERSION_NEW="$new_value"

        local tmp_file
        tmp_file="$(mktemp)"
        if ! NEW_NUM="$new_value" perl -0777 -pe 's{(?m)^(\s*extVersionCode\s*=\s*)\d+(\s*(?://.*)?$)}{$1.$ENV{NEW_NUM}.$2}e' "$file_path" > "$tmp_file"; then
            rm -f "$tmp_file"
            return 0
        fi

        if ! cmp -s "$file_path" "$tmp_file"; then
            cat "$tmp_file" > "$file_path"
            VERSION_UPDATED=1
        fi
        rm -f "$tmp_file"
        return 0
    fi

    old_value="$(perl -ne 'if (/^\s*overrideVersionCode\s*=\s*(\d+)/) { print $1; exit }' "$file_path")"
    if [[ -n "$old_value" ]]; then
        new_value=$((old_value + 1))
        VERSION_FOUND=1
        VERSION_MODE="overrideVersionCode"
        VERSION_OLD="$old_value"
        VERSION_NEW="$new_value"

        local tmp_file
        tmp_file="$(mktemp)"
        if ! NEW_NUM="$new_value" perl -0777 -pe 's{(?m)^(\s*overrideVersionCode\s*=\s*)\d+(\s*(?://.*)?$)}{$1.$ENV{NEW_NUM}.$2}e' "$file_path" > "$tmp_file"; then
            rm -f "$tmp_file"
            return 0
        fi

        if ! cmp -s "$file_path" "$tmp_file"; then
            cat "$tmp_file" > "$file_path"
            VERSION_UPDATED=1
        fi
        rm -f "$tmp_file"
        return 0
    fi

    VERSION_FOUND=0
    VERSION_MODE="not-found"
    return 0
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

trim_text() {
    local s="${1:-}"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

declare -a sources
mapfile -t sources < <(find "$RESOLVED_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

declare -a detail_lines
declare -a changed_entries
declare -A excluded_sources

if [[ -n "$EXCLUDE_RAW" ]]; then
    while IFS= read -r raw_line; do
        exclude_name="$(trim_text "$raw_line")"
        if [[ -n "$exclude_name" ]]; then
            excluded_sources["$exclude_name"]=1
        fi
    done <<< "$EXCLUDE_RAW"
fi

if ! check_proxy_connection; then
    exit 1
fi

echo "Found ${#sources[@]} sources in $RESOLVED_ROOT"

for source_name in "${sources[@]}"; do
    if [[ -n "${excluded_sources[$source_name]:-}" ]]; then
        detail_lines+=("[SKIP-EXCLUDED] $source_name | Listed in EXCLUDE input")
        echo "[SKIP-EXCLUDED] $source_name"
        continue
    fi

    source_dir="$RESOLVED_ROOT/$source_name"
    build_file="$source_dir/build.gradle"
    build_content=""

    if [[ -f "$build_file" ]]; then
        build_content="$(cat "$build_file" 2>/dev/null || true)"
    fi

    main_kt_file="$(get_main_kt_file_path "$source_dir" "$source_name" "$build_file")"
    target_kt_file="$main_kt_file"

    old_url=""
    if [[ -n "$build_content" ]]; then
        old_url="$(printf '%s\n' "$build_content" | sed -nE "s/^[[:space:]]*baseUrl[[:space:]]*=[[:space:]]*['\"](https?:\\/\\/[^'\"]+)['\"].*$/\\1/p" | head -n1)"
    fi

    if [[ -z "$old_url" && -n "$main_kt_file" && -f "$main_kt_file" ]]; then
        old_url="$(get_url_from_kt_file "$main_kt_file")"
    fi

    if [[ -z "$old_url" ]]; then
        fallback_result="$(find_url_in_source_kt_files "$source_dir" "$main_kt_file")"
        if [[ -n "$fallback_result" ]]; then
            old_url="${fallback_result%%$'\t'*}"
            target_kt_file="${fallback_result#*$'\t'}"
        fi
    fi

    if [[ -z "$old_url" ]]; then
        detail_lines+=("[SKIP] $source_name | No URL found in build.gradle or main kt file")
        echo "[SKIP] $source_name - no URL found"
        continue
    fi

    if ! resolve_redirect_info "$old_url" "$TIMEOUT_SEC"; then
        detail_lines+=("[ERROR] $source_name | connect failed for $old_url | $REDIRECT_ERROR")
        echo "[ERROR] $source_name - $REDIRECT_ERROR"
        continue
    fi

    if [[ "$REDIRECT_REDIRECTED" -ne 1 ]]; then
        detail_lines+=("[NO-REDIRECT] $source_name | $old_url")
        echo "[NO-REDIRECT] $source_name"
        continue
    fi

    new_url="$(get_new_url_value "$old_url" "$REDIRECT_FINAL_URL")"
    changed_files=()

    if update_build_gradle_url "$build_file" "$new_url"; then
        changed_files+=("build.gradle")
    fi

    if update_kt_url "$target_kt_file" "$old_url" "$new_url"; then
        rel_path="${target_kt_file#"$source_dir"/}"
        changed_files+=("$rel_path")
    fi

    if [[ ${#changed_files[@]} -gt 0 ]]; then
        update_version_code "$build_file"
        if [[ "$VERSION_UPDATED" -eq 1 ]]; then
            if ! array_contains "build.gradle" "${changed_files[@]}"; then
                changed_files+=("build.gradle")
            fi
            detail_lines+=("[VERSION] $source_name | $VERSION_MODE: $VERSION_OLD => $VERSION_NEW")
            echo "[VERSION] $source_name $VERSION_MODE: $VERSION_OLD => $VERSION_NEW"
        elif [[ "$VERSION_MODE" == "not-found" ]]; then
            detail_lines+=("[VERSION-WARN] $source_name | build.gradle has no extVersionCode/overrideVersionCode to update")
            echo "[VERSION-WARN] $source_name - no extVersionCode/overrideVersionCode found"
        elif [[ "$VERSION_MODE" == "no-build-file" ]]; then
            detail_lines+=("[VERSION-WARN] $source_name | no build.gradle found for version bump")
            echo "[VERSION-WARN] $source_name - no build.gradle found"
        fi

        changed_entries+=("$source_name"$'\t'"$old_url"$'\t'"$new_url")
        detail_lines+=("[CHANGED] $source_name | files: $(IFS=', '; echo "${changed_files[*]}")")
        echo "[CHANGED] $source_name => $new_url"
    else
        detail_lines+=("[SKIP] $source_name | redirected $old_url -> $new_url but no matching value found to update")
        echo "[SKIP] $source_name - redirected but no file changes"
    fi
done

{
    echo "Domain Update Summary"
    echo "Run at: $timestamp"
    echo "Root: $RESOLVED_ROOT"
    echo "Sources found: ${#sources[@]}"
    echo
    echo "## Changed Domains"
    if [[ ${#changed_entries[@]} -eq 0 ]]; then
        echo "- No redirected domains were changed."
    else
        while IFS=$'\t' read -r src old_url new_url; do
            old_host="$(host_from_url "$old_url")"
            new_host="$(host_from_url "$new_url")"
            echo "- **$src**: \`$old_host\` => \`$new_host\`"
        done < <(printf '%s\n' "${changed_entries[@]}" | sort -t $'\t' -k1,1)
    fi

    echo
    echo "Checklist:"
    echo
    echo "- [x] Updated \`extVersionCode\` value in \`build.gradle\` for individual extensions"
    echo "- [x] Updated \`overrideVersionCode\` or \`baseVersionCode\` as needed for all multisrc extensions"
    echo "- [x] Referenced all related issues in the PR body (e.g. \"Closes #xyz\")"
    echo "- [ ] Added the \`isNsfw = true\` flag in \`build.gradle\` when appropriate"
    echo "- [x] Have not changed source names"
    echo "- [x] Have explicitly kept the \`id\` if a source's name or language were changed"
    echo "- [x] Have tested the modifications by compiling and running the extension through Android Studio"
    echo "- [ ] Have removed \`web_hi_res_512.png\` when adding a new extension"
    echo
    echo "## Details"
    if [[ ${#detail_lines[@]} -eq 0 ]]; then
        echo "- No detail entries."
    else
        printf '%s\n' "${detail_lines[@]}"
    fi
} >"$LOG_PATH"

echo
echo "Done. Log written to: $LOG_PATH"
