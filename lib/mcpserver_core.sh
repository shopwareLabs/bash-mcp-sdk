#!/usr/bin/env bash
# MCP Server Core - JSON-RPC 2.0 Protocol Handler
# Based on Model Context Protocol specification
# Requires: bash 5.1+, jq 1.7+

# Pre-flight dependency guards for the two floors the header line declares.
# This block alone uses no construct newer than bash 3.2, sits above the file's
# own `set -euo pipefail`, and diagnoses on stderr. AGENTS.md §Pre-flight
# guards.

# Print remediation lines for a failed dependency check. `dep` is `bash` or
# `jq`. Output lands on stdout so the function stays pure and testable, which
# makes the `>&2` at every call site mandatory: a call site that forgets it
# writes the hint into the JSON-RPC stream. `uname` is the only external command
# reached for, and an absent or failing `uname` falls through to the generic
# line rather than failing the hint.
_mcp_install_hint() {
    local dep="$1"

    local floor="${dep}"
    case "${dep}" in
        bash) floor="bash 5.1 or newer" ;;
        jq) floor="jq 1.7 or newer" ;;
    esac

    local platform=""
    if command -v uname >/dev/null 2>&1; then
        platform=$(uname -s 2>/dev/null) || platform=""
    fi

    case "${platform}" in
        Darwin)
            # Probe for brew, as the Linux arm probes its package managers: a
            # Mac with no Homebrew — MacPorts, nix, a managed image — would
            # otherwise be handed a command that does not exist. The generic
            # line stands in for it, so such a Mac still gets remediation.
            if command -v brew >/dev/null 2>&1; then
                printf '%s\n' "  brew install ${dep}"
            else
                printf '%s\n' "  install ${floor} with your platform's package manager"
            fi
            if [[ "${dep}" == "bash" ]]; then
                # The install on its own changes nothing: macOS keeps 3.2.57 at
                # /bin/bash, and both usual launch paths — a
                # `#!/usr/bin/env bash` shebang, and a host manifest whose
                # command is `bash` — resolve through PATH. A GUI-launched MCP
                # host reads no shell profile, so the PATH it hands the server
                # is the one that has to be ordered. Printed whether or not brew
                # was found: a GUI host hands the server a PATH with no brew on
                # it, and that is precisely the case where the fix is a PATH
                # fix, so this advice cannot sit inside the brew probe.
                printf '%s\n' "  then place its directory before /usr/bin in the PATH the MCP host launches this server with"
            fi
            return 0
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                printf '%s\n' "  apt-get install ${dep}"
                return 0
            fi
            if command -v apk >/dev/null 2>&1; then
                printf '%s\n' "  apk add ${dep}"
                return 0
            fi
            if command -v dnf >/dev/null 2>&1; then
                printf '%s\n' "  dnf install ${dep}"
                return 0
            fi
            ;;
    esac

    printf '%s\n' "  install ${floor} with your platform's package manager"
    return 0
}

# Whether bash <major>.<minor> is at or above the 5.1 floor. Takes the version
# as arguments so a suite can drive it from a table. AGENTS.md §Pre-flight
# guards. A non-numeric or empty component reads as below the floor.
_mcp_bash_meets_floor() {
    local major="${1:-}"
    local minor="${2:-}"

    case "${major}" in ''|*[!0-9]*) return 1 ;; esac
    case "${minor}" in ''|*[!0-9]*) return 1 ;; esac

    # Arithmetic comparison, with `10#` forcing base 10: the guards above admit
    # any all-digit string, and a leading zero is otherwise read as octal, where
    # `08` is not a number and bash writes its own complaint to stderr.
    # `(( ))` rather than `[[ -gt ]]`: both evaluate an operand arithmetically
    # and agree on every value that reaches them here, but ShellCheck's SC2309
    # flags a built-up operand handed to `[[ ]]`'s numeric operators, and the
    # arithmetic form states the intent without needing a directive.
    if (( 10#${major} > 5 )); then
        return 0
    fi
    if (( 10#${major} == 5 && 10#${minor} >= 1 )); then
        return 0
    fi
    return 1
}

# Whether a raw `jq --version` string is at or above the 1.7 floor.
# The comparison is numeric, not lexical: `jq-1.10` is above `jq-1.7` and a
# string comparison gets that backwards. A patch component, and any distro
# suffix — attached to the minor or trailing the patch — is ignored, so
# `jq-1.7.1-Debian-1` and `jq-1.7-Debian-1` are both above the floor.
# Anything that does not parse as `jq-<major>.<minor>` is below it, a
# prerelease included: `jq-1.7rc1` is not evidence of released 1.7 behavior,
# and refusing what cannot be read is the direction that fails loudly.
# The `case`-based technique is the one the test images use
# (docker/debian.Dockerfile, docker/alpine.Dockerfile), but this helper admits a
# non-numeric patch or distro suffix they reject: the images gate their own
# build, where a version they cannot fully parse is a reason to fail it, while
# this helper decides whether a consumer's server may run.
_mcp_jq_meets_floor() {
    local raw="${1:-}"

    case "${raw}" in
        jq-*) ;;
        *) return 1 ;;
    esac

    local version="${raw#jq-}"
    case "${version}" in
        *.*) ;;
        *) return 1 ;;
    esac

    local major="${version%%.*}"
    local rest="${version#*.}"
    local minor="${rest%%.*}"
    # A distro suffix may attach to the minor with no patch component between
    # them (`jq-1.8-1`); strip it so it cannot reach the digit guard and refuse a
    # version that meets the floor. jq's own prereleases append alphanumerics
    # with no hyphen (`jq-1.7rc1`) and stay refused; a hyphenated one would
    # survive this strip, and no jq release carries one. Major is left
    # unstripped: no real version needs it.
    minor="${minor%%-*}"

    case "${major}" in ''|*[!0-9]*) return 1 ;; esac
    case "${minor}" in ''|*[!0-9]*) return 1 ;; esac

    # Same shape and same reason as _mcp_bash_meets_floor: a leading zero would
    # otherwise be read as octal, and `jq-1.08` would fail arithmetically rather
    # than compare.
    if (( 10#${major} > 1 )); then
        return 0
    fi
    if (( 10#${major} == 1 && 10#${minor} >= 7 )); then
        return 0
    fi
    return 1
}

# bash floor. Below the floor the file still parses, so there is no early error
# to go on: without this guard, sourcing it on bash 3.2 dies on the
# `exec {_MCP_PROTOCOL_FD}>&1` redirection with
# `exec: {_MCP_PROTOCOL_FD}: not found` (probed), which an MCP host reports as
# nothing more than a server that failed to start.
if [[ -z "${BASH_VERSINFO[0]:-}" ]] \
    || ! _mcp_bash_meets_floor "${BASH_VERSINFO[0]:-}" "${BASH_VERSINFO[1]:-}"; then
    printf '%s\n' "bash-mcp-sdk: bash 5.1 or newer is required; this shell reports ${BASH_VERSION:-unknown}." >&2
    _mcp_install_hint bash >&2
    # `return` when this file is sourced, `exit` when it is executed; the
    # complaint `return` raises outside a function is suppressed because it is
    # only ever raised on the executed path.
    # Known gap: a consumer that sources this file without `set -e` carries on
    # past the refusal and reaches `run_mcp_server: command not found`, with the
    # message above already on stderr. An unconditional `exit` would close that
    # gap and take the BATS runner down with it — the suites source this file
    # into the test process.
    # shellcheck disable=SC2317 # `return` succeeds only on the sourced path; on the executed path it fails and `exit 1` is what runs.
    return 1 2>/dev/null || exit 1
fi

# jq presence.
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "bash-mcp-sdk: jq was not found on PATH; jq 1.7 or newer is required." >&2
    _mcp_install_hint jq >&2
    # shellcheck disable=SC2317 # `return` succeeds only on the sourced path; on the executed path it fails and `exit 1` is what runs.
    return 1 2>/dev/null || exit 1
fi

# jq floor. Below 1.7 the server starts and answers every request, and the
# damage is silent: `validate_tool_arguments` reads a number back through
# `tojson` to catch a fraction the conversion to a double rounded away, and
# that depends on jq preserving the number literal — jq 1.7's "use decimal
# number literals to preserve precision". Older jq parses every number to a
# double, so `4503599627370496.5` renders whole and passes as an integer.
# Probed once here, at source time, never on the request path.
_mcp_jq_version=$(jq --version 2>/dev/null) || _mcp_jq_version=""
if ! _mcp_jq_meets_floor "${_mcp_jq_version}"; then
    if [[ -z "${_mcp_jq_version}" ]]; then
        # The presence check above resolved a path, so jq is installed; it just
        # did not answer. Wrong architecture, a missing shared library, a file
        # that cannot execute. Naming the resolved path points the operator at
        # the binary that is broken, and neither a version nor the
        # distro-package warning below applies to a jq that is already on the
        # machine.
        printf '%s\n' "bash-mcp-sdk: jq was found on PATH but could not be run; jq 1.7 or newer is required." >&2
        printf '%s\n' "  the jq at $(command -v jq) did not answer 'jq --version'" >&2
    else
        printf '%s\n' "bash-mcp-sdk: jq 1.7 or newer is required; jq reports '${_mcp_jq_version}'." >&2
        printf '%s\n' "  a distribution package may itself sit below the floor; a newer jq may have to come from elsewhere" >&2
    fi
    _mcp_install_hint jq >&2
    # shellcheck disable=SC2317 # `return` succeeds only on the sourced path; on the executed path it fails and `exit 1` is what runs.
    return 1 2>/dev/null || exit 1
fi
unset _mcp_jq_version

set -euo pipefail

: "${MCP_CONFIG_FILE:=config.json}"
: "${MCP_TOOLS_LIST_FILE:=tools.json}"
: "${MCP_LOG_FILE:=/dev/null}"
: "${MCP_EXTRA_LOG_FILE:=}"
: "${MCP_LOG_STDERR:=0}"

# Seconds a cancelled tool call gets to die after SIGTERM before SIGKILL, and
# a tool_<name>_cancel hook gets before it is abandoned. Internal constant:
# the README configuration table lists the MCP_* variables a consumer sets,
# and this is not one of them.
# Guarded so the file can be sourced twice in one shell: a second `readonly` on
# a name the first source already marked fails under `set -e` and takes the
# shell with it.
if [[ -z "${_MCP_CANCEL_GRACE_SECONDS:-}" ]]; then
    readonly _MCP_CANCEL_GRACE_SECONDS=2
fi

# Responses get a private copy of stdout; later writes to fd 1 go to stderr.
if [[ -z "${_MCP_PROTOCOL_FD:-}" ]]; then
    exec {_MCP_PROTOCOL_FD}>&1 1>&2
fi

log() {
    local level="$1"
    local message="$2"
    local line
    local esc_lf='\n' esc_cr='\r'
    message="${message//$'\n'/$esc_lf}"
    message="${message//$'\r'/$esc_cr}"
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    { printf '%s\n' "$line" >> "$MCP_LOG_FILE"; } 2>/dev/null || printf 'mcp: cannot write log file %s\n' "$MCP_LOG_FILE" >&2 || true
    if [[ -n "${MCP_EXTRA_LOG_FILE}" ]]; then
        { printf '%s\n' "$line" >> "$MCP_EXTRA_LOG_FILE"; } 2>/dev/null || printf 'mcp: cannot write log file %s\n' "$MCP_EXTRA_LOG_FILE" >&2 || true
    fi
    if [[ "${MCP_LOG_STDERR}" == "1" ]]; then
        printf '%s\n' "$line" >&2 || true
    fi
    return 0
}

# Configure an additional log file from user config.
# Relative paths are resolved against PROJECT_ROOT.
# If the parent directory does not exist, logs a warning and skips.
_configure_extra_log_file() {
    local raw_path="${1:-}"
    [[ -z "$raw_path" ]] && return 0

    local resolved="$raw_path"
    if [[ "$raw_path" != /* ]]; then
        resolved="${PROJECT_ROOT}/${raw_path}"
    fi

    local parent_dir
    parent_dir="$(dirname "$resolved")"
    if [[ ! -d "$parent_dir" ]]; then
        log "WARN" "log_file parent directory does not exist: ${parent_dir} — extra log file disabled"
        return 0
    fi

    MCP_EXTRA_LOG_FILE="$resolved"
    export MCP_EXTRA_LOG_FILE
    log "INFO" "Extra log file configured: ${MCP_EXTRA_LOG_FILE}"
}

# Read one JSON document from a file and print it compact when it is a JSON
# object; prints nothing and returns 1 otherwise. README.md §API. Its callers
# pipe this output to jq and index it — `.tools` in handle_tools_list and
# _mcp_tool_schema, `.protocolVersion`, `.serverInfo` and `.capabilities` in
# handle_initialize — so only an object is usable: an index of any other type
# either errors or yields `null` in place of the caller's key, and a `null` or
# `false` document is that accident rather than a configuration. Never a
# fallback: each caller answers the failure instead of treating the
# configuration as empty, so a degraded result is not passed off as a correct
# one. `jq -e` is not used to decide the parse — its exit status comes from the
# truthiness of the output rather than from whether the input parsed, and the
# object test this function needs is made explicitly in the program below.
read_json_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log "ERROR" "File not found: $file"
        return 1
    fi
    local parsed
    if ! parsed=$(jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else ("expected exactly one JSON object" | halt_error) end' -- "$file" 2>/dev/null); then
        log "ERROR" "Not exactly one parseable JSON object: ${file}"
        return 1
    fi
    printf '%s\n' "$parsed"
}

create_response() {
    local id="$1"
    local result="$2"

    # The result goes on stdin: as an argument, one above the OS argument limit fails the exec with E2BIG.
    printf '%s' "$result" | jq -c -s \
        --argjson id "$id" \
        'if length == 1 then {"jsonrpc": "2.0", "id": $id, "result": .[0]} else error("create_response: result must be exactly one JSON document") end'
}

create_error_response() {
    local id="$1"
    local code="$2"
    local message="$3"
    local data="${4:-}"

    if [[ -z "$data" ]]; then
        jq -n -c \
            --argjson id "$id" \
            --argjson code "$code" \
            --arg message "$message" \
            '{"jsonrpc": "2.0", "id": $id, "error": {"code": $code, "message": $message}}'
    else
        # The data goes on stdin for the same E2BIG reason as create_response's result.
        printf '%s' "$data" | jq -c -s \
            --argjson id "$id" \
            --argjson code "$code" \
            --arg message "$message" \
            'if length == 1 then {"jsonrpc": "2.0", "id": $id, "error": {"code": $code, "message": $message, "data": .[0]}} else error("create_error_response: data must be exactly one JSON document") end'
    fi
}

# Print a compact tool result: $1 is the isError flag (true|false), $2 the text.
_mcp_tool_text_result() {
    # The text goes on stdin to stay clear of E2BIG; --rawfile, not -Rs, because -R splits a multibyte character at a read-chunk boundary below jq 1.8.2 (jq#3389).
    printf '%s' "$2" | jq -n -c \
        --argjson is_error "$1" \
        --rawfile text /dev/stdin \
        '{"content": [{"type": "text", "text": $text}], "isError": $is_error}'
}

# Print the response carrying a tool result: $1 is the request id, $2 the isError flag (true|false), $3 the text.
_mcp_tool_text_response() {
    local result
    result=$(_mcp_tool_text_result "$2" "$3")
    create_response "$1" "$result"
}

handle_initialize() {
    local id="$1"

    log "INFO" "Handling initialize request"

    local config
    if ! config=$(read_json_file "$MCP_CONFIG_FILE"); then
        create_error_response "$id" -32603 "Cannot read server configuration: ${MCP_CONFIG_FILE}"
        return
    fi

    local result
    result=$(printf '%s' "$config" | jq -c \
        '{
            "protocolVersion": (.protocolVersion // "2024-11-05"),
            "serverInfo": (.serverInfo // {"name": "mcp-server", "version": "1.0.0"}),
            "capabilities": (.capabilities // {"tools": {}})
        }')

    create_response "$id" "$result"
}

handle_tools_list() {
    local id="$1"

    log "INFO" "Handling tools/list request"

    local tools_config
    if ! tools_config=$(read_json_file "$MCP_TOOLS_LIST_FILE"); then
        create_error_response "$id" -32603 "Cannot read tools list: ${MCP_TOOLS_LIST_FILE}"
        return
    fi

    local result
    result=$(printf '%s' "$tools_config" | jq -c '{"tools": (.tools // [])}')

    create_response "$id" "$result"
}

# Look up a tool's entry in the tools list and print its inputSchema, compact.
# The list is the authority on which tools exist: handle_tools_call answers
# from this lookup before it resolves a function, and validate_tool_arguments
# validates through it, so a name one of them treats as declared is never a
# name the other cannot find. The iteration is `.tools[]?`, which also walks
# an object's values, so `{"tools": {"k": {...}}}` declares the entries it holds.
# Args: $1 = tool name
# Outputs: the schema on status 0, and the caller's rejection message otherwise.
# Returns: 0 for exactly one entry carrying a non-null inputSchema; 2 when no
#   entry names the tool; 1 when the list cannot be read or searched, names the
#   tool more than once, or its one entry declares no inputSchema.
_mcp_tool_schema() {
    local tool_name="$1"

    local tools_config lookup count schema rc
    # Each failure below is handled explicitly rather than left to errexit,
    # because whether errexit applies here depends on the caller's shape. A
    # tools list that cannot be read is a rejection and never a skip: a
    # validator that could not read its schemas has not validated anything, and
    # reporting success there would wave every declared constraint through.
    # The jq failure below is a second such branch. read_json_file's object
    # gate catches a file-borne document that is not an object in the branch
    # above, but the jq branch stays reachable through a file: an object whose
    # `tools` holds a non-object element other than `null` passes the gate, and
    # `select` then errors on that element — the trailing `?` guards only the
    # iteration.
    rc=0
    tools_config=$(read_json_file "$MCP_TOOLS_LIST_FILE" 2>/dev/null) || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s' "Cannot validate arguments for ${tool_name}: the tool list at ${MCP_TOOLS_LIST_FILE} is missing or does not hold one JSON object."
        return 1
    fi
    # One line, `<match count> <first match's inputSchema as JSON>`, so the
    # count and the schema come out of a single read of the list. `tojson`
    # renders an absent inputSchema and a present null alike as `null`.
    rc=0
    lookup=$(printf '%s\n' "$tools_config" | jq -r --arg n "$tool_name" \
        '[.tools[]? | select(.name == $n)] | "\(length) \(.[0].inputSchema | tojson)"' 2>/dev/null) || rc=$?
    count="${lookup%% *}"
    schema="${lookup#* }"
    if [[ $rc -ne 0 || ! "$count" =~ ^[0-9]+$ ]]; then
        printf '%s' "Cannot validate arguments for ${tool_name}: the tool list at ${MCP_TOOLS_LIST_FILE} does not hold a usable tools list."
        return 1
    fi
    if [[ "$count" == "0" ]]; then
        printf '%s' "Cannot validate arguments for ${tool_name}: the tool list at ${MCP_TOOLS_LIST_FILE} does not declare it."
        return 2
    fi
    # Two entries for one name would leave the schema that applies to depend on
    # which entry a reader takes first.
    if [[ "$count" != "1" ]]; then
        printf '%s' "Cannot validate arguments for ${tool_name}: the tool list at ${MCP_TOOLS_LIST_FILE} declares it more than once."
        return 1
    fi
    if [[ "$schema" == "null" ]]; then
        printf '%s' "Cannot validate arguments for ${tool_name}: its entry in ${MCP_TOOLS_LIST_FILE} declares no inputSchema."
        return 1
    fi
    printf '%s' "$schema"
}

# Validate call arguments against the tool's declared inputSchema, rejecting
# arguments that are not a JSON object. The enforced keywords, their accepted
# value types, the union-type rule, the range-bound rule and the diagnostic
# precedence order are docs/server-contract.md §Tool functions.
# The schema comes from _mcp_tool_schema, so a tool the tools list does not
# declare exactly once with a non-null inputSchema is rejected rather than
# skipped, and so is a tools list that cannot be read, whether it is missing,
# unparseable, or holds a document that is not a JSON object.
# Args: $1 = tool name, $2 = arguments JSON
# On violation: prints a human-readable message to stdout and returns 1.
validate_tool_arguments() {
    local tool_name="$1"
    local arguments="$2"

    local schema rc
    rc=0
    schema=$(_mcp_tool_schema "$tool_name") || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s' "$schema"
        return 1
    fi
    _mcp_validate_against_schema "$schema" "$arguments" "$tool_name"
}

# Check arguments against one inputSchema; validate_tool_arguments' contract
# applies, minus the tools-list lookup its caller has already made.
# A declared `integer` is satisfied by a whole-valued number, decided from the
# number as jq renders it and not from its double value alone, so a fractional
# literal at or above 2^52 = 4503599627370496 is rejected instead of being read
# as whole; a rendering that carries an exponent keeps the double-based verdict,
# which admits a fractional value below the smallest subnormal double.
# A jq failure is a rejection and never a skip:
# a validator that could not evaluate its input has not validated it, and
# reporting success there would wave every constraint through. That branch is
# defense-in-depth for a direct call rather than a live remote-input guard —
# process_request admits only one JSON document per line and answers anything
# that is not a JSON object before dispatch, so arguments arriving over the
# protocol are always parseable JSON. The non-object branch is NOT in that
# category: `null`, `false` and every other JSON scalar are parseable, and
# `arguments` may be any JSON value, so a client can send them and they reach
# this validator.
# Args: $1 = inputSchema JSON, $2 = arguments JSON, $3 = tool name, which only
#       the evaluation-failure message names
# On violation: prints a human-readable message to stdout and returns 1.
_mcp_validate_against_schema() {
    local schema="$1"
    local arguments="$2"
    local tool_name="$3"

    # A non-object `arguments` is rejected in its own branch because `check`
    # applies `required`, `properties` and `additionalProperties` only to an
    # object value, so a non-object would otherwise skip all three.
    local message rc
    rc=0
    # Schema and arguments go on stdin as two documents, clear of the E2BIG an oversized argument hits.
    message=$(printf '%s\n%s' "$schema" "$arguments" | jq -s -r --arg tool "$tool_name" \
        '
        if length == 2 then . else error("expected one schema and one arguments document") end
        | .[0] as $schema | .[1] as $args |
        # A declared `type` is one name or a list of alternatives, so it is
        # normalized to a list and one comparison serves both forms.
        # `"integer"` treats a whole-valued JSON number as satisfying it (JSON
        # has no distinct integer type); every other name is a plain jq `type`
        # comparison.
        def type_names(want):
            if (want | type) == "array" then want else [want] end;
        # The whole-value test reads the number as jq renders it as well as its
        # double value. `floor` converts its input to an IEEE-754 double, and at
        # or above 2^52 = 4503599627370496 the double spacing reaches 1, so a
        # literal such as `4503599627370496.5` is already whole as a double and
        # `floor` cannot see the fraction the check exists to find. `tojson`
        # renders the number from the literal jq parsed, which still carries it.
        # `floor` is kept as a conjunct rather than replaced: it rejects, at the
        # cost of one comparison, every non-integer whose fraction survives the
        # conversion to a double, leaving the literal test only what the double
        # rounded away.
        # Known gap, not an oversight: expanding an exponent rendering exactly
        # would mean decimal arithmetic in jq, so a rendering that keeps an
        # exponent falls back to the double-based verdict alone. jq renders an
        # exponent when the value is an exact multiple of ten — necessarily an
        # integer, so no gap there — or when its magnitude is below about
        # 1e-6, where `floor` still rejects a fraction unless the double
        # underflows to zero. What the gap admits is therefore a fractional
        # value smaller than the smallest subnormal double: `1.5e-400` is
        # accepted as an integer.
        def type_ok(want; val):
            any(type_names(want)[];
                if . == "integer" then
                    (val | type) == "number"
                    and (val == (val | floor))
                    and ((val | tojson) as $literal
                         | if ($literal | test("[eE]")) then true
                           else ($literal | test("\\.[0-9]*[1-9]") | not)
                           end)
                else
                    (val | type) == .
                end);
        # Only reached after `type_ok` failed, so a number here has already
        # failed every declared alternative: with `integer` offered it is
        # necessarily non-integer and reads "number (non-integer)".
        def type_label(want; val):
            if (val | type) == "number"
               and (type_names(want) | index("integer")) != null then
                "number (non-integer)"
              else
                (val | type)
              end;
        def type_expected(want):
            type_names(want) | join(" or ");
        def sub_path($base; $k):
            if $base == "" then $k else $base + "." + $k end;
        # Emit one violation record per defect in value $v against schema $s,
        # each tagged with its diagnostic class in `.c`. Every schema position
        # (the root, a `properties` value, a schema-valued
        # `additionalProperties`, `items`, a `oneOf` branch) is checked by this
        # one function. `shape` has already refused every wrong-typed keyword,
        # so a `// empty` or `//` default here sees an absent keyword only. A
        # keyword read with `// empty` sits in its own comma-separated branch,
        # so an absent one drops that keyword alone. $item marks an array element,
        # whose own `type` and `enum` defects keep the `items` class and its
        # formats.
        def check($s; $v; $path; $item):
            [ ($s.type // empty) as $t
              | select((type_ok($t; $v)) | not)
              | {c: (if $item then "items" else "type" end), issue: "type", p: $path,
                 expected: type_expected($t), actual: type_label($t; $v), v: $v}
            ] as $type_violations
            | $type_violations[],
              ( ($s.pattern // empty) as $pat
                | select(($v | type) == "string")
                | select(($v | test($pat)) | not)
                | {c: "pattern", p: $path, pattern: $pat, v: $v} ),
              # The number gate mirrors how `pattern` skips a non-string value.
              # Where a `type` is declared, a non-number already failed the type
              # check; where none is, a range keyword must not start rejecting
              # strings. jq types `true` as "boolean", so a boolean is skipped
              # here too and never coerced to 1 or 0.
              ( select(($v | type) == "number")
                | ( ($s.minimum          // empty | {rel: "below minimum",              bound: ., ok: ($v >= .)}),
                    ($s.maximum          // empty | {rel: "above maximum",              bound: ., ok: ($v <= .)}),
                    ($s.exclusiveMinimum // empty | {rel: "not above exclusiveMinimum", bound: ., ok: ($v >  .)}),
                    ($s.exclusiveMaximum // empty | {rel: "not below exclusiveMaximum", bound: ., ok: ($v <  .)}) )
                | select(.ok | not)
                | {c: "range", p: $path, rel: .rel, bound: .bound, v: $v} ),
              # An element reports an `enum` defect only when its `type` held.
              ( ($s.enum // empty) as $e
                | select($e | any(.[]; . == $v) | not)
                | if $item then
                    select(($type_violations | length) == 0)
                    | {c: "items", issue: "enum", p: $path, enum: $e, v: $v}
                  else
                    {c: "enum", p: $path, enum: $e, v: $v}
                  end ),
              ( select(($v | type) == "object")
                | ($v | keys)                    as $present
                | ($s.properties // {})          as $props
                | ($props | keys)                as $allowed
                | ( ($s.required // [])[] | . as $r
                    | select(($present | index($r)) == null)
                    | {c: "missing", p: sub_path($path; $r)} ),
                  ( select($s.additionalProperties == false)
                    | [ $present[] | . as $p | select(($allowed | index($p)) == null) ] as $unknown
                    | select(($unknown | length) > 0)
                    | {c: "unknown", ps: ($unknown | map(sub_path($path; .))),
                       allowed: ($allowed | map(sub_path($path; .)))} ),
                  ( $present[] as $k
                    | if ($allowed | index($k)) != null then
                        check($props[$k]; $v[$k]; sub_path($path; $k); false)
                      elif $s.additionalProperties == null
                           or ($s.additionalProperties | type) == "boolean" then
                        empty
                      else
                        check($s.additionalProperties; $v[$k]; sub_path($path; $k); false)
                      end ) ),
              ( select(($v | type) == "array")
                | ($s.items // empty) as $items
                | range(0; $v | length) as $i
                | check($items; $v[$i]; $path + "[" + ($i | tostring) + "]"; true) ),
              # A branch is satisfied when checking against it yields nothing;
              # what failed inside a branch is not reported.
              ( ($s.oneOf // empty) as $branches
                | ([ $branches[] | select(([check(.; $v; $path; false)] | length) == 0) ] | length) as $n
                | select($n != 1)
                | {c: "oneOf", p: $path, n: $n, v: $v} );
        # Dotted paths of every schema key outside the keywords `check` enforces
        # and the annotations it ignores, walked over the same positions.
        # It descends only into positions of the right type and yields nothing
        # for any other, so a wrong-typed position is left for `shape` to name.
        def unenforced($s; $path):
            if ($s | type) != "object" then empty else
            ($s | keys[]) as $k
            | sub_path($path; $k) as $kp
            | if ($k | IN("type", "properties", "required", "additionalProperties",
                          "items", "enum", "pattern", "minimum", "maximum",
                          "exclusiveMinimum", "exclusiveMaximum", "oneOf",
                          "title", "description", "default", "examples", "format",
                          "$schema", "$id", "$comment", "deprecated", "readOnly",
                          "writeOnly") | not) then
                $kp
              elif $k == "properties" then
                if ($s.properties | type) != "object" then empty else
                ($s.properties | keys[]) as $pk
                | unenforced($s.properties[$pk]; $kp + "." + $pk) end
              elif $k == "additionalProperties" or $k == "items" then
                unenforced($s[$k]; $kp)
              elif $k == "oneOf" then
                if ($s.oneOf | type) != "array" then empty else
                range(0; $s.oneOf | length) as $i
                | unenforced($s.oneOf[$i]; $kp + "[" + ($i | tostring) + "]") end
              else empty end
            end;
        # One record per keyword whose value has the wrong type, walked over
        # the same positions in the same key order as `unenforced`, so `check`
        # only ever reads a keyword of the type it expects. A position of the
        # wrong type is reported and not descended into.
        def shape($s; $path):
            if ($s | type) != "object" then
              {p: (if $path == "" then "inputSchema" else $path end), want: "an object"}
            else
              ($s | keys[]) as $k
              | $s[$k] as $kv
              | sub_path($path; $k) as $kp
              | if $k == "type" then
                  select(($kv | type) != "string"
                         and (($kv | type) != "array" or ($kv | length) == 0
                              or any($kv[]; type != "string")))
                  | {p: $kp, want: "a string or a non-empty array of strings"}
                elif ($k | IN("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum")) then
                  select(($kv | type) != "number")
                  | {p: $kp, want: "a number"}
                elif $k == "pattern" then
                  select(($kv | type) != "string"
                         or (try ("" | test($kv) | false) catch true))
                  | {p: $kp, want: "a string holding a valid regular expression"}
                elif $k == "required" then
                  select(($kv | type) != "array" or any($kv[]; type != "string"))
                  | {p: $kp, want: "an array of strings"}
                elif $k == "enum" then
                  select(($kv | type) != "array")
                  | {p: $kp, want: "an array"}
                elif $k == "properties" then
                  if ($kv | type) != "object" then {p: $kp, want: "an object"}
                  else ($kv | keys[]) as $pk | shape($kv[$pk]; $kp + "." + $pk) end
                elif $k == "items" then
                  shape($kv; $kp)
                elif $k == "additionalProperties" then
                  if ($kv | type) == "boolean" then empty
                  elif ($kv | type) == "object" then shape($kv; $kp)
                  else {p: $kp, want: "a boolean or an object"} end
                elif $k == "oneOf" then
                  if ($kv | type) != "array" or any($kv[]; type != "object") then
                    {p: $kp, want: "an array of objects"}
                  else
                    range(0; $kv | length) as $i
                    | shape($kv[$i]; $kp + "[" + ($i | tostring) + "]")
                  end
                else empty end
            end;
        # When both walks report, the unenforced-keyword message answers: the
        # schema needs a validator that enforces it whatever the other keywords hold.
        [ unenforced($schema; "") ] as $unenforced
        | [ shape($schema; "") ] as $shape
        | if ($unenforced | length) > 0 then
            "Cannot validate arguments for " + $tool
            + ": its inputSchema uses keyword(s) this validator does not enforce: "
            + ($unenforced | join(", ")) + "."
          elif ($shape | length) > 0 then
            "Cannot validate arguments for " + $tool
            + ": its inputSchema keyword(s) have the wrong type: "
            + ($shape | map(.p + " must be " + .want) | join("; ")) + "."
          elif ($args | type) != "object" then
            "Invalid arguments: expected a JSON object, got "
            + ($args | type) + "."
          else
            # The highest-ranked class present anywhere in the tree decides the
            # message, and every violation of that class is named in tree order.
            # A violation at the root schema has an empty path and reads `arguments`.
            [ check($schema; $args; ""; false) ] as $all
            | def of($c): $all | map(select(.c == $c));
            def shown: if . == "" then "arguments" else . end;
            if (of("missing") | length) > 0 then
              "Missing required parameter(s): " + (of("missing") | map(.p) | join(", ")) + "."
            elif (of("unknown") | length) > 0 then
              "Unknown parameter(s): " + (of("unknown") | map(.ps[]) | join(", "))
              + ". Allowed parameters: " + (of("unknown") | map(.allowed[]) | join(", ")) + "."
            elif (of("type") | length) > 0 then
              "Invalid type(s): " + (of("type") | map(
                  (.p | shown) + " expected " + .expected + ", got " + .actual
                  + " (" + (.v | tojson) + ")"
                ) | join("; ")) + "."
            elif (of("pattern") | length) > 0 then
              "Invalid value(s): " + (of("pattern") | map(
                  .p + "=" + (.v | tojson) + " does not match pattern " + .pattern
                ) | join("; ")) + "."
            elif (of("range") | length) > 0 then
              "Out-of-range value(s): " + (of("range") | map(
                  .p + "=" + (.v | tojson) + " " + .rel + " " + (.bound | tojson)
                ) | join("; ")) + "."
            elif (of("items") | length) > 0 then
              "Invalid array item(s): " + (of("items") | map(
                  if .issue == "type" then
                    .p + " expected " + .expected
                    + ", got " + .actual + " (" + (.v | tojson) + ")"
                  else
                    .p + "=" + (.v | tojson)
                    + " (allowed: " + (.enum | map(if type == "string" then . else tojson end) | join(", ")) + ")"
                  end
                ) | join("; ")) + "."
            elif (of("enum") | length) > 0 then
              "Invalid value(s): " + (of("enum") | map(
                  (.p | shown) + "=\"" + (.v | tostring) + "\" (allowed: " + (.enum | map(if type == "string" then . else tojson end) | join(", ")) + ")"
                ) | join("; ")) + "."
            elif (of("oneOf") | length) > 0 then
              "Invalid value(s): " + (of("oneOf") | map(
                  (.p | shown) + "=" + (.v | tojson)
                  + (if .n == 0 then " matches no oneOf alternative"
                     else " matches " + (.n | tostring) + " oneOf alternatives" end)
                ) | join("; ")) + "."
            else "" end
          end
        ' 2>/dev/null) || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s' "Cannot validate arguments for ${tool_name}: they could not be evaluated against its schema."
        return 1
    fi

    if [[ -n "$message" ]]; then
        printf '%s' "$message"
        return 1
    fi
    return 0
}

# Clear what a tool body must not inherit from the dispatch that runs it: the
# monitor flag, which would let the tool's children leave the call's process
# group, and the server-loop state, which a nested dispatch would act on to
# stop the server as soon as the outer call returned.
# docs/architecture.md §Tool containment.
# A nested dispatch needing cancellation or deferred replay of its own is out of
# scope; this restores the plain-call shape a direct caller gets.
_reset_tool_dispatch_state() {
    # The wrapper inherits the monitor flag from the `set -m` in
    # handle_tools_call, and the hook's option restore would otherwise turn job
    # control on, which moves the tool's children out of the call's process group.
    set +m
    _MCP_IN_SERVER_LOOP=0
    unset _MCP_SHUTDOWN_FLAG_FILE _MCP_INFLIGHT_FILE _MCP_PARTIAL_FILE
}

handle_tools_call() {
    local id="$1"
    local params="$2"

    # A tools/call carries its arguments in a params object, so a params of any
    # other type is an Invalid params. This gate runs before `.name` and
    # `.arguments` are read, so those extractions only ever see an object and
    # none of them can fail, whoever the caller is: under `set -o posix` bash
    # inherits errexit into the command substitution those extractions run in,
    # and a failed one would end the whole server instead of answering. It also
    # keeps a non-object params' `Cannot index ...` jq diagnostics off the
    # process's stderr, unrouted through `log`. And it makes handle_tools_call
    # safe as a direct public entry point on its own: a caller passing invalid
    # JSON makes the `type` substitution print nothing, which is not "object",
    # so the gate fails closed.
    if [[ "$(printf '%s\n' "$params" | jq -r 'type')" != "object" ]]; then
        log "ERROR" "tools/call params is not a JSON object"
        create_error_response "$id" -32602 "Invalid params: expected an object"
        return
    fi

    # The type is tested before the name is printed: `jq -r` prints `null`,
    # `false` and `true` as identifiers the regex below accepts, so a non-string
    # name would dispatch a tool declared under that word.
    if [[ "$(printf '%s\n' "$params" | jq -r '.name | type')" != "string" ]]; then
        log "ERROR" "tools/call name is not a string"
        create_error_response "$id" -32602 "Invalid params: name must be a string"
        return
    fi

    # A name that command substitution would alter (a trailing newline, or a
    # NUL that bash drops) is printed JSON-encoded instead: the quote
    # characters make it fail the identifier regex below, which an altered
    # name such as `echo` from `"echo\n"` would pass.
    local tool_name
    tool_name=$(echo "$params" | jq -r '.name | if (explode | any(. == 0)) or endswith("\n") then tojson else . end')

    # `.arguments // {}` would substitute {} for a present `null` or `false`,
    # because jq's `//` treats both as absent — the validator's non-object
    # branch would then never see either. Only a genuinely absent key defaults.
    local arguments
    arguments=$(echo "$params" | jq -c 'if has("arguments") then .arguments else {} end')

    log "INFO" "Handling tools/call: $tool_name"

    # Prevents command injection via tool name
    if [[ ! "$tool_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        create_error_response "$id" -32602 "Invalid tool name: $tool_name"
        return
    fi

    # The tools list decides which tools exist, not the shell: a sourced
    # `tool_*` function the list does not declare, a `tool_<name>_cancel` hook
    # included, is not a tool. The lookup also returns the schema the validation
    # below runs against, so the list is read once per call.
    local schema lookup_rc
    lookup_rc=0
    schema=$(_mcp_tool_schema "$tool_name") || lookup_rc=$?
    if [[ $lookup_rc -eq 2 ]]; then
        create_error_response "$id" -32601 "Tool not found: $tool_name"
        return
    fi
    if [[ $lookup_rc -ne 0 ]]; then
        log "ERROR" "Tool $tool_name argument validation failed: $schema"
        _mcp_tool_text_response "$id" true "$schema"
        return
    fi

    # `declare -F` matches a shell function only: `type` would also match an
    # executable, alias or builtin of that name, so a `tool_x` on PATH would
    # answer for a tool the server never defined.
    local func_name="tool_${tool_name}"
    if ! declare -F "$func_name" >/dev/null; then
        create_error_response "$id" -32601 "Tool not found: $tool_name"
        return
    fi

    local validation_error validation_rc
    validation_rc=0
    validation_error=$(_mcp_validate_against_schema "$schema" "$arguments" "$tool_name") || validation_rc=$?
    if [[ $validation_rc -ne 0 ]]; then
        log "ERROR" "Tool $tool_name argument validation failed: $validation_error"
        _mcp_tool_text_response "$id" true "$validation_error"
        return
    fi

    # Every file of the call lives in one root that `mktemp -d` creates mode 700
    # and exclusively, so no other user can place anything at a name inside it
    # and the files below are written with a plain `>`.
    # docs/architecture.md §Tool containment.
    local setup_failure="Cannot run ${tool_name}: its call directory could not be created."
    local call_root root_rc=0
    call_root=$(mktemp -d "${TMPDIR:-/tmp}/mcp-call.XXXXXX" 2>&1) || root_rc=$?
    if [[ $root_rc -ne 0 ]]; then
        log "ERROR" "Tool $tool_name not run: cannot create its call directory in ${TMPDIR:-/tmp}: ${call_root}"
        _mcp_tool_text_response "$id" true "$setup_failure"
        return
    fi
    # A relative TMPDIR yields a relative root, and a hook that changes
    # directory would then miss its own capture file and hand the tool a
    # MCP_CALL_TMPDIR that names nothing from where it runs.
    [[ $call_root == /* ]] || call_root="$PWD/$call_root"
    # The in-flight record holds the output file's path alone, so every reader
    # derives the root as its directory; the names below are that contract.
    local output_file="$call_root/output"
    local sentinel_file="$call_root/sentinel"
    local call_tmpdir="$call_root/tmp"
    local mkdir_error mkdir_rc=0
    mkdir_error=$(mkdir -m 700 -- "$call_tmpdir" 2>&1) || mkdir_rc=$?
    if [[ $mkdir_rc -ne 0 ]]; then
        log "ERROR" "Tool $tool_name not run: cannot create MCP_CALL_TMPDIR ${call_tmpdir}: ${mkdir_error}"
        _mcp_remove_call_root "$call_root"
        _mcp_tool_text_response "$id" true "$setup_failure"
        return
    fi
    local pid
    local monitor_was_enabled=0
    if [[ -o monitor ]]; then
        monitor_was_enabled=1
    fi
    # The tool runs in the background under `set -m` so an in-flight call can be
    # cancelled by process group.
    set -m
    # A lifeline is identified by its directory and FIFO, never by
    # _MCP_LIFELINE_FD: process_request closed and cleared that descriptor on
    # the way in, so it is empty here on the one path that has a lifeline.
    if [[ -n "${_MCP_LIFELINE_DIR:-}" && -p "${_MCP_LIFELINE_DIR}/lifeline" ]]; then
        # The wrapper opens its own reader before it starts the tool, so a
        # server already gone leaves the wrapper blocked instead of starting an
        # orphaned tool.
        # The sentinel-pid record is best effort like the in-flight file. A
        # wrapper that cannot write it leaves the group's raw liveness as the
        # teardown's only measure, which is slower but not wrong.
        # docs/architecture.md §Tool containment.
        # shellcheck disable=SC2030 # MCP_CALL_TMPDIR is exported for this call's wrapper alone; the dispatch shell must not keep it.
        ( exec {lifeline_rd}<"${_MCP_LIFELINE_DIR}/lifeline"; _lifeline_sentinel "${lifeline_rd}" & sentinel_pid=$!; set +e; printf '%s\n' "$sentinel_pid" > "${sentinel_file}"; _reset_tool_dispatch_state; export MCP_CALL_TMPDIR="$call_tmpdir"; _mcp_run_tool "$func_name" "$tool_name" "$arguments" "$call_root" ) \
            >"$output_file" 2>&1 </dev/null &
    else
        # No lifeline: run_mcp_server never ran in this shell, so there is
        # nothing for a sentinel to watch. The wrapper keeps the shape of the
        # loop-driven path, so both give the tool the same process group.
        # shellcheck disable=SC2030,SC2031 # MCP_CALL_TMPDIR is exported for this call's wrapper alone; the dispatch shell must not keep it.
        ( set +e; _reset_tool_dispatch_state; export MCP_CALL_TMPDIR="$call_tmpdir"; _mcp_run_tool "$func_name" "$tool_name" "$arguments" "$call_root" ) >"$output_file" 2>&1 </dev/null &
    fi
    pid=$!
    if [[ "$monitor_was_enabled" == "1" ]]; then
        set -m
    else
        set +m
    fi

    # The tool's process group, its name and its output file are written where a
    # trap can read them back: the main shell cannot see inside the command
    # substitution this dispatches in, and the output file's path exists nowhere
    # else once this dispatch is gone. docs/architecture.md §The in-flight record.
    if [[ "${_MCP_IN_SERVER_LOOP:-0}" == "1" && -n "${_MCP_INFLIGHT_FILE:-}" ]]; then
        printf '%s %s %s\n' "$pid" "$tool_name" "$output_file" > "${_MCP_INFLIGHT_FILE}"
    fi

    # The poll below reads the client's stdin, and only run_mcp_server's read
    # loop owns that stream. A caller that invokes this function directly owns
    # its own stdin instead, so it gets the same background child in the same
    # process group but a plain blocking wait: reading there would consume
    # bytes the caller means to handle, and an EOF on that stream is the
    # caller's business rather than a cancellation.
    if [[ "${_MCP_IN_SERVER_LOOP:-0}" == "1" ]]; then
        _await_tool_call "$id" "$pid" "$tool_name" "$arguments" "$output_file"
    else
        _wait_tool_call "$pid" "$tool_name" "$output_file"
    fi

    local output=""
    local hook_text=""
    local hook_refused=0
    local exit_code="$_MCP_CHILD_STATUS"
    # A cancelled call was already answered by its teardown, which sends no
    # response for the id and has removed the call root.
    if [[ "$_MCP_CANCELLED" -eq 0 ]]; then
        output=$(<"$output_file")
        # _mcp_run_tool writes `hook-returned` as soon as the hook returns,
        # whatever its status, so a `hook-running` with no `hook-returned` means
        # the wrapper ended while the hook ran: the hook called `exit`, its own
        # errexit or nounset stopped it, or a signal killed the wrapper. In each
        # case the tool never ran. The capture is read only here, where nothing
        # removed it. A status above 128 names no single cause: `wait` reports
        # death by signal N and an exit with status 128+N alike, and a hook
        # that errexit stops at a command that failed with 141 exits with 141.
        # docs/architecture.md §Tool containment.
        if [[ -e "$call_root/hook-running" && ! -e "$call_root/hook-returned" ]]; then
            if [[ $exit_code -gt 128 ]]; then
                hook_text="mcp_before_tool_call ended with status $exit_code before returning (signal $((exit_code - 128)), or a command that failed with that status); tool $tool_name did not run."
                log "ERROR" "Before-tool hook mcp_before_tool_call for tool $tool_name ended with status $exit_code (signal $((exit_code - 128)), or a command that failed with that status)"
            else
                hook_text="mcp_before_tool_call ended the call instead of returning; tool $tool_name did not run."
                log "ERROR" "Before-tool hook mcp_before_tool_call for tool $tool_name ended the call (status $exit_code)"
            fi
            if [[ -s "$call_root/hook-output" ]]; then
                hook_text="${hook_text}"$'\n'"$(<"$call_root/hook-output")"
            fi
        elif [[ -e "$call_root/hook-refused" ]]; then
            hook_refused=1
        fi
        # The call root is removed here, once output and hook_text have been read
        # out of it; the in-flight record is truncated just below. Both happen
        # before the response is built or the deferred requests are replayed, so
        # neither can run ahead of the clear.
        # The call root goes first and the record second: the root exists
        # nowhere but this subshell and the record, so a teardown landing
        # between the steps reads a record naming a root this dispatch has
        # already released, and its removal is idempotent, so it loses nothing.
        # Every path that reaches here has already waited for the wrapper and
        # passed its group to _kill_tool_group, so no member of the call is left
        # to write into the root as it is removed.
        # docs/architecture.md §The in-flight record.
        _mcp_remove_call_root "$call_root"
    fi
    # Cleared once per dispatch, whichever way it ended — completed, cancelled,
    # or cleared by the teardown above. Clearing it is what keeps a shutdown from
    # signalling a process group that is already gone and whose id could by then
    # name something else.
    if [[ -n "${_MCP_INFLIGHT_FILE:-}" ]]; then
        : > "${_MCP_INFLIGHT_FILE}"
    fi

    if [[ "$_MCP_CANCELLED" -eq 0 ]]; then
        if [[ -n "$hook_text" ]]; then
            # The hook's exit status is discarded: the call is answered by the
            # reason the tool did not run, not by the status the hook chose.
            _mcp_tool_text_response "$id" true "$hook_text"
        elif [[ $exit_code -ne 0 ]]; then
            if [[ $hook_refused -eq 1 ]]; then
                log "ERROR" "before-tool hook refused tool $tool_name (status $exit_code)"
            else
                log "ERROR" "Tool $tool_name failed with exit code $exit_code"
            fi
            _mcp_tool_text_response "$id" true "Error executing $tool_name: $output"
        else
            _mcp_tool_text_response "$id" false "$output"
        fi
    fi

    # Requests that arrived while the tool ran are answered after the
    # in-flight response, in the order they were received.
    local deferred deferred_response
    # A replayed line that is itself a tools/call must not read stdin. This
    # subshell is still the one that owns the stream while the replays run,
    # so a nested poll would take the bytes of the fragment this dispatch has
    # already handed to the read loop — or of the next request — as its own
    # deferred line and consume them. With the flag cleared the replay takes
    # the no-read path, a plain blocking call, so a replayed call runs to
    # completion with no cancellation window: a cancellation naming it
    # arrives later in the stream and is dropped as matching nothing. Only
    # this subshell's copy is cleared, and it is put back before the
    # EOF-drain check below reads the state this dispatch actually ended in.
    local outer_in_server_loop
    outer_in_server_loop="${_MCP_IN_SERVER_LOOP:-0}"
    _MCP_IN_SERVER_LOOP=0
    for deferred in "${_MCP_DEFERRED_LINES[@]}"; do
        if [[ -z "$deferred" ]]; then
            continue
        fi
        deferred_response=$(process_request "$deferred")
        if [[ -n "$deferred_response" ]]; then
            printf '%s\n' "$deferred_response"
        fi
    done
    _MCP_IN_SERVER_LOOP="$outer_in_server_loop"

    # A line the client had left half-written when the tool ended has already
    # left this dispatch through the partial-line file, written by the poll loop
    # before it returned. The server's read loop completes it once this dispatch
    # has returned: completing it here would hold the response above back behind
    # a line the client might never finish.

    # Stdin reached EOF while the tool ran, so no further request can arrive.
    # This dispatch is fully answered by now, so the server stops after it. The
    # signal travels through a file rather than a variable because everything
    # above ran in the command substitution run_mcp_server dispatches in.
    if [[ "${_MCP_EOF_DRAIN:-0}" -eq 1 ]]; then
        if [[ -n "${_MCP_SHUTDOWN_FLAG_FILE:-}" ]]; then
            : >"$_MCP_SHUTDOWN_FLAG_FILE"
        else
            log "WARN" "No shutdown flag file set; the server loop cannot be signalled"
        fi
    fi
}

# Wait for a tool child when the call is not driven by the server's read loop.
# Nothing is read here, so there is no cancellation window: the dispatch is a
# plain blocking call, as it is for a consumer that invokes handle_tools_call
# or process_request itself. The child already leads its own process group, so
# the shape matches the in-loop one apart from the wait.
# Args: $1 = child pid, $2 = tool name, $3 = tool output file
# Sets: _MCP_CANCELLED, _MCP_CHILD_STATUS, _MCP_DEFERRED_LINES, _MCP_EOF_DRAIN
_wait_tool_call() {
    local pid="$1"
    local tool_name="$2"
    local output_file="$3"

    _MCP_CANCELLED=0
    _MCP_CHILD_STATUS=0
    _MCP_DEFERRED_LINES=()
    _MCP_EOF_DRAIN=0

    wait "$pid" || _MCP_CHILD_STATUS=$?
    _kill_tool_group "$pid" "$tool_name" "$output_file"
}

# Poll the client's stdin while a tool child runs, so an in-flight tools/call
# can be cancelled and so requests that arrive mid-call are answered in order
# once it finishes. Cancellation matching is docs/architecture.md §Cancellation;
# the EOF and fragment rules are docs/architecture.md §Partial-line handoff.
# Args: $1 = in-flight request id (JSON), $2 = child pid, $3 = tool name,
#       $4 = original arguments JSON, $5 = tool output file
# Sets: _MCP_CANCELLED (1 when the call was cancelled, else 0),
#       _MCP_CHILD_STATUS (the child's exit status), _MCP_DEFERRED_LINES, and
#       _MCP_EOF_DRAIN (1 when stdin reached EOF, so the server loop stops
#       after this dispatch)
# Writes: the fragment in hand when an uncancelled call ends to the file
#       _MCP_PARTIAL_FILE names; nothing when there is none
_await_tool_call() {
    local id="$1"
    local pid="$2"
    local tool_name="$3"
    local arguments="$4"
    local output_file="$5"

    _MCP_CANCELLED=0
    _MCP_CHILD_STATUS=0
    _MCP_DEFERRED_LINES=()
    _MCP_EOF_DRAIN=0

    local buffer=""
    local chunk=""
    local line=""
    local fragment=""
    local line_ready=0
    local is_cancel=0
    local rc=0
    local status=0

    while kill -0 "$pid" 2>/dev/null; do
        chunk=""
        rc=0
        line_ready=0
        # On a timeout, and on EOF reached after some bytes were read, bash
        # still stores what it managed to read into the variable, and those
        # bytes are gone from the pipe: they have to be kept and joined to the
        # rest of the line, or a line the client wrote in more than one piece
        # would lose its first fragment.
        # The window is short because it is the latency every completed
        # tools/call pays when the tool outruns it: the read is what the wait
        # blocks on after the tool is already gone.
        IFS= read -r -t 0.05 chunk || rc=$?
        if [[ $rc -eq 0 ]]; then
            line="${buffer}${chunk}"
            buffer=""
            line_ready=1
        elif [[ $rc -gt 128 ]]; then
            buffer="${buffer}${chunk}"
        else
            # EOF on stdin: the client is gone and nothing further can be
            # read, but the call was accepted and its response is still owed
            # to whoever reads the stream. Reading stops here and the normal
            # completion below answers it; the shutdown flag is set by
            # handle_tools_call once that response and the deferred lines are
            # written. The last read carries bytes even at EOF, so the
            # fragment is the joined buffer and whatever that read stored.
            # A fragment is only dropped when it is not JSON: one that already
            # parses is the client's last request, sent with no trailing
            # newline that can now ever arrive, and it is answerable. It goes
            # through the same handling as a terminated line below, and the
            # loop then stops.
            # A dropped fragment is unanswerable and its content is whatever
            # the client wrote, so only its length is recorded. The buffer is
            # cleared in both cases: the fragment has been accounted for, and
            # nothing below may treat it as still in hand.
            fragment="${buffer}${chunk}"
            buffer=""
            line=""
            if [[ -n "$fragment" ]]; then
                # The parse test is `jq empty`, which exits zero on any
                # parseable input: `jq -e '.'` takes its status from the
                # truthiness of the output, so it would drop a fragment of
                # `false` or `null`, both valid JSON. `jq empty` also exits
                # zero on input holding no documents, the empty string and
                # whitespace-only input alike, so the fragment
                # reaching this gate need not hold one: the `-n` guard above
                # excludes only the empty string, and a whitespace-only
                # fragment is handed on and answered -32700 — the same answer
                # the same bytes get when a newline follows them.
                if printf '%s\n' "$fragment" | jq empty >/dev/null 2>&1; then
                    line="$fragment"
                    line_ready=1
                else
                    log "WARN" "Discarding a partial line of ${#fragment} characters left by EOF during tools/call $id ($tool_name)"
                fi
            fi
            _MCP_EOF_DRAIN=1
            if [[ $line_ready -eq 0 ]]; then
                break
            fi
        fi

        if [[ $line_ready -eq 1 ]]; then
            is_cancel=0
            # The id is compared as a JSON value on both sides: `--argjson`
            # normalizes the in-flight id, jq compares it against the
            # requestId as parsed, so 1 does not match "1" and a malformed
            # line simply fails to parse and is queued instead of matching.
            # The requestId presence guard precedes the comparison: an absent
            # requestId reads as null, and a null in-flight id would then equal
            # it and cancel an unrelated call. Matched only when the key is
            # there, so the clause fails closed for an id no other message
            # reaches.
            if printf '%s\n' "$line" | jq -e --argjson id "$id" \
                '.jsonrpc == "2.0" and (has("id") | not) and .method == "notifications/cancelled" and (.params | has("requestId")) and .params.requestId == $id' \
                >/dev/null 2>&1; then
                is_cancel=1
            fi
            if [[ $is_cancel -eq 1 ]]; then
                log "INFO" "Cancelling in-flight tools/call $id ($tool_name)"
                _teardown_tool_call "$tool_name" "$pid" "$arguments" "$id" "$output_file"
                _MCP_CANCELLED=1
                return 0
            fi
            _MCP_DEFERRED_LINES+=("$line")
            # The line above was the last one this loop can read; a terminated
            # line leaves the drain flag clear and the loop continues.
            if [[ $_MCP_EOF_DRAIN -eq 1 ]]; then
                break
            fi
        fi
    done

    # A fragment still in hand when the loop ended — the child died before the
    # line it began was finished — is written out for run_mcp_server's read loop
    # to complete, no trailing newline, so the byte stream the client wrote is
    # the byte stream that is joined. Nothing is written for an empty fragment,
    # and the EOF above already accounts for the one it discarded. The handoff is
    # logged for the call it left, never for the fragment: the fragment's content
    # is the client's, so only its length is recorded.
    if [[ -n "$buffer" && -n "${_MCP_PARTIAL_FILE:-}" ]]; then
        printf '%s' "$buffer" > "${_MCP_PARTIAL_FILE}"
        log "INFO" "Handing a partial line of ${#buffer} characters out of tools/call $id ($tool_name) to the read loop"
    fi

    wait "$pid" || status=$?
    _MCP_CHILD_STATUS="$status"
    _kill_tool_group "$pid" "$tool_name" "$output_file"
}

# Run a tool's optional tool_<name>_cancel hook, bounded at
# _MCP_CANCEL_GRACE_SECONDS so a wedged hook cannot wedge its caller. The hook
# is consumer code: it gets the call's arguments as its one argument, and
# neither the client's stdin nor the protocol stream.
# The hook gets the call's MCP_CALL_TMPDIR, so it can read what the call
# recorded there; it runs before the call's group is signalled and before the
# call root is removed.
# Args: $1 = tool name, $2 = the call's arguments JSON. The teardown that runs
#       from a signal handler passes an empty string: it reads the tool's name
#       and process group out of the in-flight file, which records no
#       arguments. $3 = the call root, which the caller has already checked;
#       when it is empty, the hook runs with MCP_CALL_TMPDIR unset rather than
#       set to an empty path. $4 = the output path the caller derived that
#       root from: a non-empty path with an empty root is logged as refused,
#       here, because only this function knows whether a hook is defined.
_run_cancel_hook() {
    local tool_name="$1"
    local arguments="$2"
    local call_root="${3:-}"
    local output_file="${4:-}"

    # A function only, as in handle_tools_call: `type` would also run a
    # `tool_<name>_cancel` executable found on PATH.
    local hook="tool_${tool_name}_cancel"
    if ! declare -F "$hook" >/dev/null; then
        return 0
    fi

    local call_tmpdir=""
    if [[ -n "$call_root" ]]; then
        call_tmpdir="${call_root}/tmp"
    elif [[ -n "$output_file" ]]; then
        log "WARN" "refusing to derive a call root from ${output_file}: not a call root; cancel hook ${hook} runs with MCP_CALL_TMPDIR unset"
    fi

    local hook_pid
    local monitor_was_enabled=0
    if [[ -o monitor ]]; then
        monitor_was_enabled=1
    fi
    set -m
    # An empty MCP_CALL_TMPDIR would turn a hook's `rm -rf "$MCP_CALL_TMPDIR"/*`
    # into a removal under `/`, so with no directory to name it is unset, which
    # also drops a value inherited from the environment.
    # shellcheck disable=SC2031 # The hook's MCP_CALL_TMPDIR is set in this subshell alone, independent of any wrapper's.
    ( _mcp_close_protocol_fds; set +e; if [[ -n "$call_tmpdir" ]]; then export MCP_CALL_TMPDIR="$call_tmpdir"; else unset MCP_CALL_TMPDIR; fi; "$hook" "$arguments" ) >/dev/null 2>&1 </dev/null &
    hook_pid=$!
    if [[ "$monitor_was_enabled" == "1" ]]; then
        set -m
    else
        set +m
    fi
    _mcp_reap_with_grace "$hook_pid" "Cancel hook ${hook} for ${tool_name}" "exited"
    return 0
}

# Wait out a background job that leads a process group of its own, bounded at
# _MCP_CANCEL_GRACE_SECONDS: an overrun job's group is SIGKILLed, the job reaped
# and the overrun logged; a job that finished in time has a non-zero status
# logged and whatever it left in its group cleared. The status is always 0, so
# the job cannot change its caller's outcome.
# The caller spawns the job itself: a function wrapped around the job's body
# adds a frame, and with errtrace on the ERR trap fires once more at that frame
# (probed on bash 5.3).
# Args: $1 = the job's pid, which is the group id it leads,
#       $2 = what the WARN lines call the job, $3 = the verb its non-zero
#       status is logged with
_mcp_reap_with_grace() {
    local pid="$1"
    local label="$2"
    local status_verb="$3"
    local waited=0
    local status=0

    while kill -0 "$pid" 2>/dev/null \
        && [[ $waited -lt $((_MCP_CANCEL_GRACE_SECONDS * 10)) ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null || true
        wait "$pid" || true
        log "WARN" "${label} did not finish within ${_MCP_CANCEL_GRACE_SECONDS}s; killed"
    else
        wait "$pid" || status=$?
        if [[ $status -ne 0 ]]; then
            log "WARN" "${label} ${status_verb} with status ${status}"
        fi
        # The group is the job's own, not the call's group the in-flight record
        # names, so no tombstone is written for it: a call's group may still be
        # live here and the record has to keep naming it.
        _kill_tool_group "$pid" "" ""
    fi
    return 0
}

# Close the descriptors the server holds for its own use — the lifeline writer
# and the protocol stream — and clear the variables naming them, so a later
# close cannot hit a number the shell has since given to something else.
_mcp_close_protocol_fds() {
    if [[ -n "${_MCP_LIFELINE_FD:-}" ]]; then
        exec {_MCP_LIFELINE_FD}>&-
        _MCP_LIFELINE_FD=""
    fi
    if [[ -n "${_MCP_PROTOCOL_FD:-}" ]]; then
        exec {_MCP_PROTOCOL_FD}>&-
        _MCP_PROTOCOL_FD=""
    fi
}

# Clear what is left of a tool's process group after its wrapper has been
# reaped: the group is the tool's containment boundary, so nothing the tool
# started outlives the call. docs/architecture.md §Tool containment.
#
# The tombstone is written ahead of the check-and-kill, not after it, because
# this function is the one place the group is deliberately emptied: any other
# order leaves a window where the group is empty and the record still names its
# id. Accepted cost of that order — a teardown racing the same sliver removes
# the call's files without signalling, and the lifeline sentinel remains the
# containment backstop. docs/architecture.md §The in-flight record.
# Args: $1 = the wrapper's pid, which is the group id it leads,
#       $2 = the call's tool name, $3 = the call's output file path. The last
#       two are empty when the group is not the call's own — the cancel hook's
#       group is a group of its own, and the record names the call's — and a
#       tombstone is written only when both are non-empty, on the server loop
#       only, where a trap can read the record.
_kill_tool_group() {
    local pid="$1"
    local tool_name="$2"
    local output_file="$3"

    if [[ "${_MCP_IN_SERVER_LOOP:-0}" == "1" && -n "${_MCP_INFLIGHT_FILE:-}" \
        && -n "$tool_name" && -n "$output_file" ]]; then
        printf '%s %s %s\n' "-" "$tool_name" "$output_file" > "${_MCP_INFLIGHT_FILE}"
    fi

    if kill -0 -- "-${pid}" 2>/dev/null; then
        kill -KILL -- "-${pid}" 2>/dev/null || true
    fi
    return 0
}

# Derive the call root an output path names, once the path is checked. The
# variable named by the first argument is set to the root and the status is 0
# only when the path is absolute, its basename is the `output` name
# `handle_tools_call` mints, and its parent's basename is the `mcp-call.*` one
# `mktemp -d` mints. Anything else sets that variable to the empty string and
# returns 1, so a reader of a stale or corrupted in-flight record derives no
# root from it and reads no file through it.
# The root is named into a caller variable rather than printed, so no caller
# pays a subshell fork for the check.
# Args: $1 = the name of the variable to set, which the caller declares local,
#       $2 = the output path
# Returns: 0 when the path names a call root, else 1
_mcp_call_root_of() {
    local out_var="$1"
    local output_path="${2:-}"
    local root="${output_path%/*}"

    if [[ $output_path == /* && ${output_path##*/} == "output" && ${root##*/} == mcp-call.* ]]; then
        printf -v "$out_var" '%s' "$root"
        return 0
    fi
    printf -v "$out_var" '%s' ""
    return 1
}

# Remove a call root with its contents. A path that is not absolute, or whose
# basename is not the `mcp-call.*` one `mktemp -d` mints, is refused with a
# `WARN` and nothing is removed.
# `rm -rf` cannot empty a directory the tool left without read, write or search
# permission, so when the root survives the first pass those permissions are
# restored and the removal is retried.
# `-exec … \;` runs chmod on each directory as `find` reaches it, before `find`
# reads it, so a directory under one the tool locked is reached too. `find`
# does not follow symlinks unless told to and `-type d` does not match one, so
# the mode of whatever a symlink in the root points at is never changed. A
# failure is logged and never returned: it must not change the call's outcome
# (a response still goes out, a cancelled call still gets none), and under
# `set -o posix` a failing command in the dispatch would end the server instead.
# Args: $1 = the call root, an absolute path
# Returns: 0
_mcp_remove_call_root() {
    local root="$1"
    local rm_error chmod_error=""
    local rm_rc=0

    # Only a path this SDK minted is ever removed: `mktemp -d` builds the root
    # as an absolute `<TMPDIR>/mcp-call.*`. Anything else — a root a stale or
    # corrupted in-flight record named — is refused before `rm` or `find` runs,
    # so it cannot turn the removal loose on an arbitrary directory.
    if [[ $root != /* || ${root##*/} != mcp-call.* ]]; then
        log "WARN" "refusing to remove ${root}: not a call root"
        return 0
    fi

    # _teardown_tool_call may have removed it: an absent path is not a failure.
    [[ -e $root || -L $root ]] || return 0

    rm_error=$(rm -rf -- "$root" 2>&1) || rm_rc=$?
    if [[ -e $root || -L $root ]]; then
        # No `--` end-of-options marker: BusyBox `find` may read it as a path,
        # and every call site passes an absolute path, which cannot be an option.
        chmod_error=$(find "$root" -type d ! -perm -u+rwx -exec chmod u+rwx {} \; 2>&1) || true
        rm_rc=0
        rm_error=$(rm -rf -- "$root" 2>&1) || rm_rc=$?
    fi
    if [[ $rm_rc -ne 0 || -e $root || -L $root ]]; then
        log "WARN" "Cannot remove call directory ${root}: ${rm_error}${chmod_error:+ (restoring permissions: ${chmod_error})}"
    fi
    return 0
}

# Run a tool function behind the consumer's optional mcp_before_tool_call hook,
# inside the call's wrapper subshell. Neither the hook nor the tool is forked
# off: both run in the wrapper's shell, so a global variable the hook assigns,
# a directory it changes to, and an EXIT trap it installs reach the tool. The
# shell options are the exception: those the hook sets are put back before the
# tool runs. A function the hook defines reaches the tool but not the steps
# this function runs once the hook has returned. Bash scopes
# variables dynamically, so a hook assignment to a name it does not declare
# `local` writes to the nearest local of that name, in this function or a
# caller: every value read after the hook is therefore a positional parameter,
# which the hook cannot reach, or the hook's own status in `$?`, which is
# recorded as one at once.
# docs/server-contract.md §Running a step before every tool.
# Args: $1 = tool function name, $2 = tool name, $3 = the call's arguments JSON,
#       $4 = the call root, which holds the hook's capture file and markers
# Outputs: a failed hook's captured output on stdout, which the wrapper has
#          pointed at the call's output file; otherwise the tool's own output.
# Returns: the hook's status when it is non-zero, else the tool's status
_mcp_run_tool() {
    # `declare -F` matches a shell function only, as for the tool itself: an
    # executable or alias named mcp_before_tool_call never runs as the hook.
    if declare -F mcp_before_tool_call >/dev/null; then
        # $5 and $6 hold the shell option snapshots the restore below
        # re-executes, $7 the ERR trap in force before the hook (empty when
        # there is none), $8 the SDK's own ERR trap, $9 the hook's status and
        # $10 the `shopt` snapshot for the last restore pass. They are
        # positional so the hook cannot overwrite them.
        set -- "$1" "$2" "$3" "$4" "$(set +o)" "$(shopt -p)" "$(trap -p ERR)"
        # The marker outlives the wrapper only when the hook never returned —
        # it called `exit`, its errexit or nounset stopped it, or a signal killed
        # the wrapper — which is what handle_tools_call answers for once the
        # wrapper is reaped. A bare redirection, so no command name the hook
        # could shadow — `:` included — is reached and no PATH lookup happens.
        # shellcheck disable=SC2188 # a commandless redirection is the point: any command name here is one the hook may have shadowed or taken off PATH.
        >"$4/hook-running"
        # The hook is called as a plain statement, not an `if` condition: bash
        # ignores errexit in every function called from a condition, so an
        # errexit the hook turns on would not stop it at a failing command. A
        # hook it does stop ends the wrapper before `hook-returned` is written,
        # and is answered as one that called `exit`. A hook that returns
        # non-zero with errexit on would end the wrapper the same way at this
        # call, but the ERR trap below fires there first, in this function's
        # frame, and turns errexit off, so the status reaches the refusal
        # branch unless the hook replaced the trap with its own.
        # The FUNCNAME check keeps the trap from turning the hook's own errexit
        # off when errtrace carries it into the hook. It replaces the server's
        # ERR trap for the hook's duration, so the server's trap does not fire
        # for the hook's failures, and is swapped back after the restore below.
        builtin trap 'if [[ ${FUNCNAME[0]-} == _mcp_run_tool ]]; then builtin set +e; fi' ERR
        builtin set -- "$@" "$(builtin trap -p ERR)"
        # A brace group, not a subshell: its redirection applies without a fork,
        # so what the hook sets survives into the tool call below. The capture
        # keeps a successful hook's output out of the tool result. The hook's
        # status is appended as $9. `builtin` keeps a function the hook defined
        # named `set` from taking over the append.
        { mcp_before_tool_call "$2" "$3"; } >"$4/hook-output" 2>&1
        builtin set -- "$@" "$?"
        # The `shopt` snapshot with its extdebug line made a no-op: `builtin :`.
        builtin set -- "$@" "${6//shopt -? extdebug/:}"
        # Every step below runs after the hook returned, so each one bypasses
        # what the hook may have changed: a function it defined named `set`,
        # `shopt` or `printf` must not take over the SDK's own steps, and a PATH
        # it rewrote must not decide whether those steps can run. Nothing below
        # reaches for an external command — each file is written with a bare
        # redirection and every command run is a builtin — so a hook that sets
        # PATH=/nonexistent leaves no marker behind. The restore re-executes the
        # snapshot with every command prefixed `builtin` for the same reason,
        # since the snapshot's own `set` and `shopt` calls would otherwise
        # resolve to the hook's functions. The tool call at the end is
        # deliberately not bypassed: a function the hook defines reaches the
        # tool. docs/server-contract.md §Running a step before every tool.
        # Restored before any step below runs, so an errexit or nounset the hook
        # turned on governs neither those steps nor the tool. The three passes
        # exist because one replay rewrites options another set.
        # docs/architecture.md §Tool containment.
        builtin eval "builtin ${6//$'\n'/$'\n'builtin }"
        builtin eval "builtin ${5//$'\n'/$'\n'builtin }"
        builtin eval "builtin ${10//$'\n'/$'\n'builtin }"
        # An ERR trap the hook installed and still in force stays, and reaches
        # the tool when errtrace is on. When the trap in force is still the
        # SDK's own, because the hook left it in place, the trap in force before
        # the hook is put back.
        if [[ "$(builtin trap -p ERR)" == "$8" ]]; then
            if [[ -n $7 ]]; then
                builtin eval "builtin $7"
            else
                builtin trap - ERR
            fi
        fi
        # Written whatever the hook's status, and before the refusal branch: this
        # plus `hook-running` is what tells handle_tools_call the hook returned
        # rather than died. It is left in place with `hook-output`; the whole
        # root goes when the call does.
        # shellcheck disable=SC2188 # a commandless redirection is the point: any command name here is one the hook may have shadowed or taken off PATH.
        >"$4/hook-returned"
        if [[ $9 -ne 0 ]]; then
            # Tells handle_tools_call that the non-zero status is the hook's
            # refusal, not the tool's failure.
            # shellcheck disable=SC2188 # a commandless redirection is the point: any command name here is one the hook may have shadowed or taken off PATH.
            >"$4/hook-refused"
            builtin printf '%s' "$(<"$4/hook-output")"
            builtin return "$9"
        fi
    fi
    "$1" "$3"
}

# The pid recorded in a call's sentinel file. Empty when no record was written —
# no lifeline, or the wrapper had not reached it yet — which a grace poll reads
# as "unknown" and falls back to the group's raw liveness.
# Args: $1 = the sentinel pid file path
_sentinel_pid_for() {
    local sentinel_file="$1"
    local sentinel_pid=""

    if [[ -n "$sentinel_file" && -s "$sentinel_file" ]]; then
        IFS= read -r sentinel_pid < "$sentinel_file" || true
    fi
    printf '%s' "$sentinel_pid"
}

# Whether a tool's process group still holds a live member other than the
# lifeline sentinel. The sentinel waits on the server's lifeline rather than on
# the tool and ignores TERM, so it outlives a tool that dies on the first TERM;
# counting it would hold every cancellation open for the whole grace period.
# A group whose only live member is the sentinel therefore reads as dead, and
# the caller's grace loop ends. The sentinel is not forgotten: _kill_tool_group
# clears whatever is left of the group once the tool is reaped.
# A group the kernel has already released is dead here too — the scan matches
# nothing — but a caller that must not signal a recycled group id gates on
# `kill -0 -- "-<pgid>"` for that, not on this.
# The members come from a full `ps` listing filtered here rather than from a
# selecting call, which cannot tell an emptied group from a probe that never
# ran. A `ps` that fails at all is unknown liveness, never an empty group: read
# as empty it would end the caller's grace loop at once and skip the SIGKILL
# after it, leaving a tool that ignores TERM alive.
# docs/architecture.md §Cancellation.
# Args: $1 = group id, $2 = sentinel pid (empty when unknown)
_tool_group_has_live_member() {
    local pgid="$1"
    local sentinel_pid="$2"

    local listing=""
    local ps_rc=0
    # Guarded so a missing binary, which reaches a subshell as a 127 exit rather
    # than through errexit, cannot end the caller.
    listing="$(ps -A -o pgid=,pid= 2>/dev/null)" || ps_rc=$?
    if [[ ${ps_rc} -ne 0 ]]; then
        kill -0 -- "-${pgid}" 2>/dev/null
        return
    fi

    local entry_pgid member
    while read -r entry_pgid member _; do
        if [[ "${entry_pgid}" != "${pgid}" || -z "${member}" || "${member}" == "${sentinel_pid}" ]]; then
            continue
        fi
        return 0
    done <<< "${listing}"
    return 1
}

# TERM a tool's process group, give its live members other than the sentinel
# _MCP_CANCEL_GRACE_SECONDS to exit, and SIGKILL the group if one outlasts the
# grace. The caller checks the group is still there before calling, and reaps
# the leader itself where it is that caller's child.
# Args: $1 = group id, $2 = sentinel pid (empty when unknown), $3 = tool name
_mcp_term_group_with_grace() {
    local pgid="$1"
    local sentinel_pid="$2"
    local tool_name="$3"
    local waited=0

    # The wrapper leads its own process group, so the negative pid reaches the
    # tool and everything it spawned.
    kill -TERM -- "-$pgid" 2>/dev/null || true
    while _tool_group_has_live_member "$pgid" "$sentinel_pid" \
        && [[ $waited -lt $((_MCP_CANCEL_GRACE_SECONDS * 10)) ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if _tool_group_has_live_member "$pgid" "$sentinel_pid"; then
        kill -KILL -- "-$pgid" 2>/dev/null || true
        log "WARN" "Tool ${tool_name} ignored SIGTERM; process group killed"
    fi
    return 0
}

# Stop a cancelled tool call: run its optional cancel hook, terminate the
# child's process group, and reap it. A hook or a child that ignores SIGTERM
# gets _MCP_CANCEL_GRACE_SECONDS before being killed, so a wedged consumer tool
# cannot wedge the server; the grace is measured against the group's live
# members other than the sentinel, so a tool that dies on the first TERM is
# reaped at once rather than two seconds later.
# Args: $1 = tool name, $2 = child pid, $3 = original arguments JSON,
#       $4 = in-flight request id (JSON), $5 = tool output file
_teardown_tool_call() {
    local tool_name="$1"
    local pid="$2"
    local arguments="$3"
    local id="$4"
    local output_file="$5"

    local call_root=""
    _mcp_call_root_of call_root "$output_file" || true

    _run_cancel_hook "$tool_name" "$arguments" "$call_root" "$output_file"

    local sentinel_pid=""
    if [[ -n "$call_root" ]]; then
        sentinel_pid="$(_sentinel_pid_for "${call_root}/sentinel")"
    else
        log "WARN" "refusing to derive a call root from ${output_file}: not a call root"
    fi

    if kill -0 -- "-$pid" 2>/dev/null; then
        _mcp_term_group_with_grace "$pid" "$sentinel_pid" "$tool_name"
    fi
    # Reaped once, after the last signal: the status reflects the signal,
    # which is what a cancellation is expected to look like.
    wait "$pid" || true
    _kill_tool_group "$pid" "$tool_name" "$output_file"
    # A path that named no call root has no root to remove, and the check above
    # already logged the refusal.
    if [[ -n "$call_root" ]]; then
        _mcp_remove_call_root "$call_root"
    fi
    log "INFO" "Cancelled tools/call $id ($tool_name)"
}

process_request() {
    local request="$1"

    if [[ "${_MCP_IN_SERVER_LOOP:-0}" == "1" ]]; then
        _mcp_close_protocol_fds
    fi

    # Parse gate: exactly one JSON document, of any type. `jq -e '.'` would
    # accept a line holding two documents — it reports only its last output —
    # and the id filter below would then emit one line per document, whose
    # joined text `--argjson` rejects, ending the server. It also exits non-zero
    # on a whole document that is `null` or `false`, both of which are
    # parseable and belong in the -32600 arm below. The count is read the
    # way read_json_file reads a file's, with `jq -cs` and a length test; a line
    # jq cannot parse at all fails the substitution, and any other count is a
    # line that is not one document.
    local doc_count
    if ! doc_count=$(printf '%s\n' "$request" | jq -cs 'length' 2>/dev/null); then
        log "ERROR" "Invalid JSON received"
        create_error_response "null" -32700 "Parse error: Invalid JSON"
        return
    fi
    if [[ "$doc_count" != "1" ]]; then
        log "ERROR" "Received a line holding ${doc_count} JSON documents; expected exactly one"
        create_error_response "null" -32700 "Parse error: Expected exactly one JSON document per line"
        return
    fi

    # JSON-RPC 2.0 represents a call as a Request object, so a document of any
    # other type is an Invalid Request. This gate runs before `.jsonrpc`, `.id`,
    # `.method` and `.params` are read, so those extractions only ever see an
    # object and none of them can fail, so process_request does not depend on
    # its dispatch site clearing errexit inside the command substitution it
    # runs in. It also keeps a non-object line's `Cannot index ...` jq
    # diagnostics off the process's stderr, unrouted through `log`.
    if [[ "$(printf '%s\n' "$request" | jq -r 'type')" != "object" ]]; then
        log "ERROR" "JSON-RPC request is not a JSON object"
        create_error_response "null" -32600 "Invalid Request: expected a JSON object"
        return
    fi

    local jsonrpc id id_is_valid method method_is_string params
    # Read as JSON text and compared against `"2.0"` below: `jq -r` would print
    # the number 2.0 as `2.0`, and command substitution would strip a newline
    # from `"2.0\n"`, so either would pass a comparison against the bare string.
    jsonrpc=$(echo "$request" | jq -c '.jsonrpc')
    # The id is read by key presence, not with `//`: that operator maps an
    # absent key and a present null to the same output, so a request carrying
    # `"id": null` would be indistinguishable from a notification. `tojson`
    # keeps the JSON type of a present id, so 7 stays an integer and "7" a
    # string, and an absent key leaves the empty sentinel the notification gate
    # reads.
    id=$(echo "$request" | jq -r 'if has("id") then (.id | tojson) else "" end')
    # A method is read only when it is a string: `.method // ""` would fold a
    # present `null` or `false` into the empty name, and print a number or
    # `true` as a name. The verdict is kept apart from the name, because an
    # empty string is a string method that no handler answers.
    method_is_string=$(echo "$request" | jq -r '(.method | type) == "string"')
    # A method command substitution would alter is printed JSON-encoded, so it
    # matches no handler, as in handle_tools_call's name read.
    method=$(echo "$request" | jq -r 'if (.method | type) == "string" then (.method | if (explode | any(. == 0)) or endswith("\n") then tojson else . end) else "" end')
    # Only an absent params defaults to {}: `//` would substitute it for a
    # present `null` or `false`, and handle_tools_call's object gate would
    # then never see either.
    params=$(echo "$request" | jq -c 'if has("params") then .params else {} end')

    # Whether the id is of a type a response can echo back: a JSON string or
    # integer. JSON-RPC 2.0 §5 allows a response id to be a String, Number or
    # Null, so every other type — and the absent id, whose sentinel is the
    # empty string — must be answered with a null id rather than reflected.
    # Computed once here, because both the version arm below and the id-type
    # gate read this verdict; a second test would be the same question twice.
    #
    # The integer test is `_mcp_validate_against_schema`'s `type_ok` test for a
    # declared `integer`, restated for a whole document: `$id` is already the
    # id's `tojson` rendering, so the value under test is the document jq reads
    # rather than a sub-value. The duplication is deliberate — the validator's
    # copy sits inside a large jq program string, and factoring the two
    # together is a refactor with its own risk. The comment above that copy
    # explains why a bare `floor` comparison is not enough.
    id_is_valid=0
    if [[ -n "$id" ]] && printf '%s\n' "$id" | jq -e '
        (type == "string")
        or (
            (type == "number")
            and (. == (. | floor))
            and ((tojson) as $literal
                 | if ($literal | test("[eE]")) then true
                   else ($literal | test("\\.[0-9]*[1-9]") | not)
                   end)
        )' >/dev/null 2>&1; then
        id_is_valid=1
    fi

    if [[ "$jsonrpc" != '"2.0"' ]]; then
        log "ERROR" "Invalid JSON-RPC version: $jsonrpc"
        # This arm runs ahead of the id-type gate, so it settles the response
        # id itself: a string or integer is reflected, and the absent sentinel,
        # a null, a boolean, a fractional number, an object or an array all
        # answer null, which is the response id JSON-RPC reserves for an id
        # that could not be echoed.
        local response_id="null"
        if [[ "$id_is_valid" == "1" ]]; then
            response_id="$id"
        fi
        create_error_response "$response_id" -32600 "Invalid Request: jsonrpc must be 2.0"
        return
    fi

    # A message with no id key is a JSON-RPC notification and requires no
    # response, so none of the arms below can emit one. The id is empty exactly
    # when the key is absent. Between requests nothing is in flight: a
    # cancellation that arrives here matches no call and is dropped.
    if [[ -z "$id" ]]; then
        if [[ "$method_is_string" != "true" ]]; then
            log "ERROR" "Notification method is not a string; dropped"
            return
        fi
        case "$method" in
            "notifications/initialized")
                log "INFO" "Client initialized"
                ;;
            "notifications/cancelled")
                log "INFO" "Cancellation received with nothing in flight; dropped"
                ;;
            *)
                log "INFO" "Received notification: $method"
                ;;
        esac
        return
    fi

    # An id that is neither a string nor an integer is neither a request nor a
    # notification: MCP requires a request id to be a string or an integer and
    # forbids null, and a notification carries no id at all, so an id of any
    # other type — including a fractional number — is answered rather than
    # dispatched. The validity test above enforces that rule in full; its
    # verdict is read here rather than re-run.
    if [[ "$id_is_valid" != "1" ]]; then
        log "ERROR" "Request id must be a string or an integer"
        create_error_response "null" -32600 "Invalid Request: id must be a string or an integer"
        return
    fi

    # JSON-RPC 2.0 §4 makes `method` a String, so a request whose method is
    # anything else, or absent, is an Invalid Request rather than an unknown
    # method. It runs after the id gate, so the id it echoes is a valid one.
    if [[ "$method_is_string" != "true" ]]; then
        log "ERROR" "Request method is not a string"
        create_error_response "$id" -32600 "Invalid Request: method must be a string"
        return
    fi

    case "$method" in
        "initialize")
            handle_initialize "$id" "$params"
            ;;
        "tools/list")
            handle_tools_list "$id"
            ;;
        "tools/call")
            handle_tools_call "$id" "$params"
            ;;
        "ping")
            create_response "$id" '{}'
            ;;
        *)
            log "ERROR" "Unknown method: $method"
            create_error_response "$id" -32601 "Method not found: $method"
            ;;
    esac
}

# SIGKILL the tool's process group once the server is gone, however it went.
# This sentinel blocks on a read of the server's lifeline FIFO.
# docs/architecture.md §The lifeline.
# Nothing is ever expected to arrive on that read: a newline written to the
# FIFO would end the wait early and kill the group while the server is still
# alive, and the only writer in this design never writes, so the read ends
# only at EOF, once the last writer is gone.
_lifeline_sentinel() {
    local read_fd="$1"

    trap '' TERM INT HUP

    local pgid=""
    local entry_pid entry_pgid
    while read -r entry_pid entry_pgid _; do
        if [[ "${entry_pid}" == "${BASHPID}" ]]; then
            pgid="${entry_pgid}"
            break
        fi
    done < <(ps -A -o pid=,pgid= 2>/dev/null)

    local line=""
    IFS= read -r -u "${read_fd}" line || true

    kill -KILL -- "-${pgid}" 2>/dev/null || true
}

# Stop whatever the server still holds, however the server is going down.
# The in-flight group is not this shell's child — it was the dispatch
# subshell's, and that subshell is often already gone — so it is reaped by
# polling the group, never by `wait`. docs/architecture.md §Shutdown.
_server_teardown() {
    # A signal that arrives while this is already running would otherwise enter
    # it a second time and re-signal a group, and re-run a hook, that the first
    # pass has already dealt with. The flag is cleared on the way out rather
    # than left set, so a shell that runs a second server still tears that one
    # down.
    if [[ "${_MCP_TEARDOWN_RUNNING:-0}" == "1" ]]; then
        return 0
    fi
    _MCP_TEARDOWN_RUNNING=1

    local inflight_pid=""
    local inflight_tool=""
    local inflight_output=""
    local inflight_root=""
    local inflight_sentinel_file=""
    if [[ -n "${_MCP_INFLIGHT_FILE:-}" && -s "${_MCP_INFLIGHT_FILE}" ]]; then
        read -r inflight_pid inflight_tool inflight_output < "${_MCP_INFLIGHT_FILE}" || true
    fi
    # The record is not trusted to name a call: the root, and the sentinel path
    # beside it, are derived only from an output path this SDK minted. Every
    # read and every removal below is aimed through that one checked root.
    if _mcp_call_root_of inflight_root "${inflight_output}"; then
        inflight_sentinel_file="${inflight_root}/sentinel"
    fi

    # A pgid field of `-` is the tombstone: _kill_tool_group wrote it as it
    # emptied the group, so the id it once named is free to belong to some other
    # process group by now. Nothing is signalled for it, no cancel hook runs,
    # and no grace is polled — only the files the tombstone still names are
    # released below. A numeric pgid is a call still running, and its group is
    # stopped here if it still exists.
    if [[ -n "${inflight_pid}" && "${inflight_pid}" != "-" ]] \
        && kill -0 -- "-${inflight_pid}" 2>/dev/null; then
        # The cancel hook is handed the checked root, so a record naming a path
        # outside a call root runs it with MCP_CALL_TMPDIR unset.
        _run_cancel_hook "${inflight_tool}" "" "${inflight_root}" "${inflight_output}"
        # The sentinel this call's wrapper recorded in the call root is left
        # out of the group's liveness exactly as in _teardown_tool_call: it
        # ignores TERM and waits on the lifeline, so counting it would hold this
        # teardown for the whole grace on every shutdown.
        local inflight_sentinel
        inflight_sentinel="$(_sentinel_pid_for "${inflight_sentinel_file}")"
        _mcp_term_group_with_grace "${inflight_pid}" "${inflight_sentinel}" "${inflight_tool}"
        log "INFO" "Stopped in-flight tool ${inflight_tool} (group ${inflight_pid}) on shutdown"
    fi

    # The call root is named nowhere but the dispatch subshell that created it,
    # so a server going down on a signal has only the record to reach it: the
    # root is the directory of the output file the record names, and it is
    # removed with everything in it after the group above has been stopped.
    # This removal runs for a tombstone record too, which is the point of
    # keeping the path in it. A teardown that found no call to stop leaves
    # nothing to remove either way.
    # The root removed here is the one checked above, so a record naming a path
    # outside a call root leaves that path's parent alone.
    if [[ -n "${inflight_output}" ]]; then
        if [[ -n "${inflight_root}" ]]; then
            _mcp_remove_call_root "${inflight_root}"
        else
            log "WARN" "refusing to remove ${inflight_output%/*}: not a call root"
        fi
    fi

    # The variables are cleared with the files they name: a later step in this
    # shell cannot recreate a path the teardown has released, and a second pass
    # over a cleared name skips the removal instead of repeating it against a
    # path the shell may since have given to something else.
    if [[ -n "${_MCP_INFLIGHT_FILE:-}" ]]; then
        rm -f -- "${_MCP_INFLIGHT_FILE}"
        _MCP_INFLIGHT_FILE=""
    fi
    if [[ -n "${_MCP_SHUTDOWN_FLAG_FILE:-}" ]]; then
        rm -f -- "${_MCP_SHUTDOWN_FLAG_FILE}"
        _MCP_SHUTDOWN_FLAG_FILE=""
    fi
    # The partial-line handoff is the one of these the server holds for its own
    # use rather than a dispatch's, so a teardown that runs at the end of a
    # normal loop lifetime removes it here, exactly as the loop's own exit does.
    if [[ -n "${_MCP_PARTIAL_FILE:-}" ]]; then
        rm -f -- "${_MCP_PARTIAL_FILE}"
        _MCP_PARTIAL_FILE=""
    fi
    # Dropping the last writer is what releases a sentinel still waiting; the
    # group already killed above is the normal way out.
    _mcp_close_protocol_fds
    if [[ -n "${_MCP_LIFELINE_DIR:-}" ]]; then
        rm -rf -- "${_MCP_LIFELINE_DIR}"
        _MCP_LIFELINE_DIR=""
    fi

    # The caller's own EXIT handler runs here, after the SDK has released its
    # files: the one point both routes into this function reach with the cleanup
    # done and the shell still alive. It runs in its own background group under
    # the cancel-hook grace, because bash defers a trapped signal until a
    # foreground subshell finishes, so a handler that blocked would stall
    # shutdown — an overrun is killed and logged. `set +e` and a logged, not
    # returned, failure give it the no-errexit shape its contract states. Its
    # stdout goes to stderr, and its stdin is `/dev/null` rather than the
    # inherited client stream a handler could otherwise consume. The variable is
    # cleared after the one run, so no later pass over this function — the
    # loop's own teardown, then the EXIT trap — can run the handler a second
    # time. docs/architecture.md §Shutdown.
    if [[ -n "${_MCP_CHAINED_EXIT_TRAP:-}" ]]; then
        local chained_pid=""
        local chained_monitor_was_enabled=0
        if [[ -o monitor ]]; then
            chained_monitor_was_enabled=1
        fi
        set -m
        ( set +e; eval "${_MCP_CHAINED_EXIT_TRAP}" ) >&2 </dev/null &
        chained_pid=$!
        if [[ "$chained_monitor_was_enabled" == "1" ]]; then
            set -m
        else
            set +m
        fi
        _mcp_reap_with_grace "$chained_pid" "Chained caller EXIT trap" "failed"
        _MCP_CHAINED_EXIT_TRAP=""
    fi

    _MCP_TEARDOWN_RUNNING=0

    # A signal a trap recorded while this pass ran is what the shell now dies
    # by. The re-raise runs at the end of every pass, not only a trap-driven
    # one, so a signal recorded during a clean-exit teardown still ends the
    # shell by that signal. docs/architecture.md §Shutdown.
    if [[ -n "${_MCP_PENDING_SIGNAL:-}" ]]; then
        local pending_signal
        pending_signal="${_MCP_PENDING_SIGNAL}"
        _MCP_PENDING_SIGNAL=""
        trap - "$pending_signal"
        kill -s "$pending_signal" "$BASHPID"
    fi
    return 0
}

# What every signal trap runs: tear the server down, then die by the signal that
# was sent, with its default disposition restored, so the exit status reports
# death by signal rather than a plain zero.
# A signal that arrives while a teardown is already running cannot re-enter it.
# It is recorded instead, and the pass in progress re-raises it when it ends:
# the teardown finishes its cleanup, and the shell still dies by the signal.
# Re-raising from here instead would abort that pass part-way, skipping the
# SIGKILL to the tool group and the removal of the call's files.
# Args: $1 = the signal name, as the trap spells it
_mcp_teardown_on_signal() {
    local signal="$1"

    if [[ "${_MCP_TEARDOWN_RUNNING:-0}" == "1" ]]; then
        _MCP_PENDING_SIGNAL="$signal"
        return 0
    fi

    _server_teardown
    trap - "$signal"
    kill -s "$signal" "$BASHPID"
    # On Bash 5.1, when an EXIT trap was set before the signal trap, `trap -`
    # restores a handler bash installed rather than the default, so the
    # self-kill is only recorded. Without a command after it, bash blocks in
    # `read` again before acting on it (verified on 5.1.4, 5.1.8 and 5.1.16;
    # 5.2 and later act on it at once).
    :
}

run_mcp_server() {
    log "INFO" "MCP Server starting..."

    # A cancellation handler runs inside the command substitution below, so a
    # shell variable cannot carry its shutdown signal back out. The flag is a
    # file instead, created only when the client closes stdin mid-call.
    local shutdown_flag
    shutdown_flag=$(mktemp "${TMPDIR:-/tmp}/mcp-shutdown.XXXXXX")
    rm -f -- "$shutdown_flag"
    export _MCP_SHUTDOWN_FLAG_FILE="$shutdown_flag"

    # Where a dispatch records the tool group it started, the tool's name, and
    # the file its output is collected in, for the teardown below to find.
    # Created once and left in place: its content, not its existence, is the
    # signal, and every dispatch clears it on the way out.
    local inflight_file
    inflight_file=$(mktemp "${TMPDIR:-/tmp}/mcp-inflight.XXXXXX")
    export _MCP_INFLIGHT_FILE="$inflight_file"

    # Where a dispatch hands out a line the client had left half-written when
    # the call ended. A fragment cannot travel back out of the command
    # substitution above as anything but part of its stdout, and prepending it
    # there would mean the dispatch had to read the rest of the line first —
    # holding back the response the call already earned. The file is created
    # empty and never deleted while the server runs: the loop below empties it
    # after every read, so its content, not its existence, is the signal.
    local partial_file
    partial_file=$(mktemp "${TMPDIR:-/tmp}/mcp-partial.XXXXXX")
    export _MCP_PARTIAL_FILE="$partial_file"

    # The lifeline: a FIFO the server holds open read-write and never writes to,
    # which every tool wrapper's sentinel reads. A writer disappears exactly when
    # the last server process holding it dies, whatever killed it — SIGKILL
    # included, which no trap can observe. The read-write open never blocks, and
    # the descriptor is what makes the server a writer.
    local lifeline_dir
    lifeline_dir=$(mktemp -d "${TMPDIR:-/tmp}/mcp-lifeline.XXXXXX")
    mkfifo "${lifeline_dir}/lifeline"
    export _MCP_LIFELINE_DIR="$lifeline_dir"
    exec {_MCP_LIFELINE_FD}<>"${lifeline_dir}/lifeline"

    # Known and accepted limitation, at the point it bites: a signal to this
    # shell's pid alone while a dispatch runs takes effect only when that
    # dispatch returns, so the in-flight call finishes first and the teardown
    # then finds the tool already reaped. docs/server-contract.md §Cancelling
    # and shutting down.
    # The EXIT handler a caller installed before this call is kept rather than
    # dropped: the trap below replaces it, and the teardown runs it afterwards.
    # Captured only in the shell the caller's trap was installed in — a caller
    # that isolates this call in a subshell keeps its handler in the parent, and
    # chaining it from the subshell would run it in two shells. A plain variable
    # rather than a `local`, because the EXIT trap reads it after this function
    # has returned. docs/architecture.md §Shutdown.
    _MCP_CHAINED_EXIT_TRAP=""
    if [[ "${BASHPID}" == "$$" ]]; then
        # A bash subshell inherits its parent's trap table, and `trap -p` reports
        # the parent's handler until the subshell itself changes a trap — so
        # this substitution's subshell reports this shell's own handler, and the
        # handler does not run there. Should a future bash reset traps in a
        # subshell the way POSIX describes, this capture would come back empty
        # and a handler would be missed, never fired a second time.
        local incumbent_trap_text
        incumbent_trap_text=$(trap -p EXIT)
        # An empty capture is a shell with no EXIT handler; under `set -o posix`
        # an unset trap reports `trap -- - EXIT`, whose `-` is not a handler.
        # Both store nothing.
        if [[ -n "${incumbent_trap_text}" ]]; then
            # The re-input form is `trap -- '<handler>' EXIT`, so the handler is
            # the third word once that line is parsed as the shell would.
            eval "set -- ${incumbent_trap_text}"
            if [[ -n "${3-}" && "${3-}" != "-" ]]; then
                _MCP_CHAINED_EXIT_TRAP="${3-}"
            fi
        fi
    fi

    # The caller's handler on a signal is replaced here: it expects the shell to
    # keep running, and this shell has to die by the signal. The EXIT trap is
    # the SDK's own, and the caller's EXIT handler runs from the teardown
    # instead. docs/architecture.md §Shutdown.
    trap '_server_teardown' EXIT
    trap '_mcp_teardown_on_signal INT' INT
    trap '_mcp_teardown_on_signal TERM' TERM
    trap '_mcp_teardown_on_signal HUP' HUP
    trap '_mcp_teardown_on_signal PIPE' PIPE

    # This loop is what owns the client's stdin, so it is what licenses the
    # mid-call poll in _await_tool_call to read that stream. A plain variable,
    # not an export: the poll runs in the command substitution below, a
    # subshell of this shell, and no other process has any business reading
    # the client's side of the protocol.
    _MCP_IN_SERVER_LOOP=1

    # A fragment a dispatch could not finish is prepended to the next line this
    # loop reads, so the line is dispatched as the client wrote it. The variable
    # lives across iterations because the read that completes the line happens
    # after the dispatch that carried the fragment is already gone.
    # A fragment may only be joined to a line whose read succeeded: a read that
    # fails leaves whatever it stored unterminated, so joining there would form
    # a request the client never finished writing and answer a line it left
    # open. The one exception is a joined fragment that already parses as JSON
    # — a request the client did finish writing and never terminated — and the
    # EOF branch below tells that case from an unterminated line by parsing it.
    # A line a failed read stored with no fragment in hand is dispatched too, so
    # a client that sent its last request without a trailing newline is
    # answered rather than ignored.
    local partial=""
    local line
    local read_rc=0
    while true; do
        read_rc=0
        IFS= read -r line || read_rc=$?
        if [[ $read_rc -ne 0 && -n "$partial" ]]; then
            # Nothing further can arrive, so no later read can complete this
            # line, and the bytes this read stored are its tail. The joined
            # fragment is still a line when it parses as JSON: a client that
            # sent its last request with no trailing newline wrote exactly
            # that, and it is answerable. It falls through to the dispatch
            # below like any other line.
            # Otherwise both pieces are dropped together, with only their
            # length logged: the content is the client's.
            local eof_fragment
            eof_fragment="${partial}${line}"
            partial=""
            # `jq empty`, not `jq -e '.'`: `-e` takes its status from the
            # output's truthiness, so a fragment of `false` or `null` would
            # read as a parse failure. Full reason at the same test in
            # _await_tool_call.
            if ! printf '%s\n' "$eof_fragment" | jq empty >/dev/null 2>&1; then
                log "WARN" "Discarding a partial line of ${#eof_fragment} characters left by EOF"
                break
            fi
            line="$eof_fragment"
        fi
        if [[ $read_rc -ne 0 && -z "$line" ]]; then
            break
        fi

        if [[ -n "$partial" ]]; then
            line="${partial}${line}"
            partial=""
        fi
        [[ -z "$line" ]] && continue

        log "INFO" "Received: ${line:0:100}..."

        local response
        response=$(process_request "$line")

        if [[ -n "$response" ]]; then
            log "RESPONSE" "${response:0:100}..."
            echo "$response" >&"${_MCP_PROTOCOL_FD}"
        fi

        # Read after the response is out, so a dispatch's fragment never holds
        # back the response that dispatch owed. Emptying the file hands the next
        # fragment a clean slate, and the next dispatch writes one only if it
        # ends with a line still unfinished.
        if [[ -n "${_MCP_PARTIAL_FILE:-}" && -s "${_MCP_PARTIAL_FILE}" ]]; then
            partial="$(<"${_MCP_PARTIAL_FILE}")"
            : > "${_MCP_PARTIAL_FILE}"
        fi

        if [[ -e "$_MCP_SHUTDOWN_FLAG_FILE" ]]; then
            log "INFO" "Client closed stdin during an in-flight call; shutting down"
            break
        fi
    done

    _MCP_IN_SERVER_LOOP=0
    _server_teardown
    rm -f -- "$shutdown_flag"
    unset _MCP_SHUTDOWN_FLAG_FILE
    rm -f -- "$partial_file"
    unset _MCP_PARTIAL_FILE
    log "INFO" "MCP Server shutting down"
}
