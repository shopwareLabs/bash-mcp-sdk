#!/usr/bin/env bats
# bats file_tags=mcp-core,before-tool-hook
# Pins the optional mcp_before_tool_call hook a server may define. When it is a
# shell function, every dispatched tools/call runs it first, in the tool's own
# shell, with the tool name and the validated arguments JSON:
#   - it runs with errexit off and stdin at /dev/null, as the tool does;
#   - a hook that returns 0 has its output discarded, and what it sets — a
#     variable, the working directory, an EXIT trap — reaches the tool, while
#     a shell option it sets does not;
#   - a function the hook defines reaches the tool, but not the SDK's own steps
#     after the hook returns, and neither does a PATH the hook rewrites: those
#     steps reach no external command;
#   - a hook that returns non-zero stops the call with an isError result that
#     carries the hook's output, the tool does not run, and the log records a
#     refusal rather than a tool failure;
#   - a hook that ends the wrapper shell with `exit` instead of returning stops
#     the call the same way, whatever status it exits with: the tool does not
#     run, and the isError result carries the hook's captured output when it
#     printed any;
#   - a hook killed by a signal stops the call with an isError result naming
#     the signal, and a wrapper killed while no hook is defined is answered as
#     the tool's failure, never as the hook's;
#   - a call that is not dispatched — an undeclared tool, arguments that fail
#     validation — does not run the hook, and neither does an executable on
#     PATH of that name when no function is defined;
#   - a nested handle_tools_call inside a tool runs the hook again;
#   - a cancellation stops a hook that blocks.
# Each "did not run" claim is proved by the marker file the hook or the tool
# would have written. Requests are driven through process_request; the
# cancellation case drives a throwaway server over the FIFO client harness.
# process_request runs under `run --separate-stderr`: bash can report a failed
# job-control setpgid for the wrapper on stderr, and that line is not part of
# the response the assertions parse.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

setup() {
    MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    MCP_EXTRA_LOG_FILE=""
    MCP_CONFIG_FILE="${BATS_TEST_TMPDIR}/config.json"
    MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
    PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    export MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT

    printf '%s\n' '{}' > "${MCP_CONFIG_FILE}"
    printf '%s\n' '{
        "tools": [
            {"name": "x", "inputSchema": {"type": "object", "properties": {"n": {"type": "integer"}}, "additionalProperties": false}},
            {"name": "nested", "inputSchema": {"type": "object"}},
            {"name": "inner", "inputSchema": {"type": "object"}}
        ]
    }' > "${MCP_TOOLS_LIST_FILE}"

    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

teardown() {
    mcp_stop_server
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT \
        HOOK_SLEEP_PID_FILE TOOL_MARKER MCP_SERVER_INSTANCE
}

# A tools/call line for tool <name> with <arguments-json> and request id <id>,
# built with jq so the name and the arguments reach process_request as the JSON
# they name.
_call_request() {
    local name="$1"
    local arguments_json="$2"
    local id="${3:-1}"
    jq -nc --arg n "${name}" --argjson a "${arguments_json}" --argjson id "${id}" \
        '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: $n, arguments: $a}}'
}

# Assert <response> is a result for id 1 with isError <is-error> whose text is
# exactly <text>.
_assert_result_text() {
    local response="$1"
    local is_error="$2"
    local text="$3"
    run jq -e --argjson e "${is_error}" --arg t "${text}" \
        '.id == 1 and .result.isError == $e and .result.content[0].text == $t and (.error == null)' <<< "${response}"
    assert_success
}

# Count the running processes of the server this test started, the way
# tests/lifecycle.bats counts the fixture's: every subshell the SDK forks keeps
# the server's argv, so the script path and the per-start instance marker
# select them all and nothing else.
_server_procs() {
    local script="$1"
    local marker="--mcp-test-instance=${MCP_SERVER_INSTANCE:-}"
    local line
    local count=0
    while IFS= read -r line; do
        if [[ "${line}" == Z* ]]; then
            continue
        fi
        if [[ "${line}" == *"${script}"* && "${line}" == *"${marker}"* ]]; then
            count=$(( count + 1 ))
        fi
    done < <(ps -A -o stat=,args=)
    printf '%s' "${count}"
}

# Wait up to <secs> for <file> to hold something.
_wait_for_file() {
    local file="$1"
    local limit="$2"
    local deadline=$(( SECONDS + limit ))
    while (( SECONDS < deadline )); do
        if [[ -s "${file}" ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Wait up to <secs> for process <pid> to be gone or a zombie.
_wait_for_exit() {
    local pid="$1"
    local limit="$2"
    local deadline=$(( SECONDS + limit ))
    local state=""
    while (( SECONDS < deadline )); do
        state="$(_mcp_proc_state "${pid}")"
        if [[ -z "${state}" || "${state}" == Z* ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Wait up to <secs> for exactly <want> processes of server <script>.
_wait_for_server_procs() {
    local script="$1"
    local want="$2"
    local limit="$3"
    local deadline=$(( SECONDS + limit ))
    local count=""
    while (( SECONDS < deadline )); do
        count="$(_server_procs "${script}")"
        if [[ "${count}" == "${want}" ]]; then
            return 0
        fi
        sleep 0.1
    done
    printf 'expected %s server process(es), saw %s\n' "${want}" "${count}" >&2
    return 1
}

# Count the call roots under <dir>, the way tests/lifecycle.bats counts them: a
# call root is a directory named `mcp-call.*`, and where a call's root is
# created is the only place a test can see whether it was removed.
_count_call_roots() {
    local dir="$1"
    local entry
    local count=0
    for entry in "${dir}"/*; do
        if [[ -e "${entry}" && "${entry}" == */mcp-call.* ]]; then
            count=$(( count + 1 ))
        fi
    done
    printf '%s' "${count}"
}

# --- no hook ---

@test "process_request: with no hook defined the tool result is the tool's output (guard: unchanged behavior)" {
    tool_x() { printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" false "tool output"
}

# --- a hook that succeeds ---

@test "process_request: a successful hook's stdout and stderr stay out of the tool result" {
    local hook_marker="${BATS_TEST_TMPDIR}/hook.ran"
    mcp_before_tool_call() {
        : > "${hook_marker}"
        printf 'AUDIT\n'
        printf 'AUDIT\n' >&2
        return 0
    }
    tool_x() { printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    assert [ -e "${hook_marker}" ]
    _assert_result_text "${output}" false "tool output"
}

@test "process_request: a variable the hook assigns and a directory it changes to reach the tool" {
    local hook_dir="${BATS_TEST_TMPDIR}/hook-dir"
    mkdir -p "${hook_dir}"
    mcp_before_tool_call() {
        HOOK_STATE="from-hook"
        cd "${hook_dir}" || return 1
    }
    tool_x() { printf '%s %s\n' "${HOOK_STATE:-unset}" "${PWD}"; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" false "from-hook ${hook_dir}"
}

@test "process_request: a function the hook defines still reaches the tool" {
    local hook_rm_file="${BATS_TEST_TMPDIR}/hook-rm.ran"
    mcp_before_tool_call() {
        rm() { printf 'hook rm\n' > "${hook_rm_file}"; }
        return 0
    }
    tool_x() { rm -f "${BATS_TEST_TMPDIR}/no-such-file"; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    # The tool called `rm` and the hook's function answered it instead of the
    # utility. The SDK's own steps bypass functions, so this is the one place
    # the hook's definitions still land.
    _assert_result_text "${output}" false ""
    assert_equal "$(<"${hook_rm_file}")" "hook rm"
}

@test "process_request: functions the hook defines do not divert the SDK's own steps" {
    # TMPDIR is the test's own so that the call's root is observable after the
    # call: it is the only evidence that the SDK, and not the hook's `rm`,
    # removed it.
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() {
        rm() { :; }
        shopt() { :; }
        printf() { :; }
        return 0
    }
    tool_x() { : > "${tool_marker}"; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    # The hook returned 0, so the tool ran and the call succeeded: a
    # `hook-running` marker the hook's `rm` kept from being removed would have
    # answered "ended the call" instead.
    _assert_result_text "${output}" false ""
    assert [ -e "${tool_marker}" ]
    run _count_call_roots "${TMPDIR}"
    assert_output "0"
}

@test "process_request: the hook receives the tool name and the arguments JSON the tool receives" {
    local hook_args_file="${BATS_TEST_TMPDIR}/hook-args"
    local tool_args_file="${BATS_TEST_TMPDIR}/tool-args"
    mcp_before_tool_call() { printf '%s\n%s\n' "$1" "$2" > "${hook_args_file}"; }
    tool_x() { printf '%s\n' "$1" > "${tool_args_file}"; }

    run --separate-stderr process_request "$(_call_request x '{"n": 7}')"

    assert_success
    run jq -e '.result.isError == false' <<< "${output}"
    assert_success
    assert_equal "$(<"${hook_args_file}")" "$(printf 'x\n%s' "$(<"${tool_args_file}")")"
    assert_equal "$(<"${tool_args_file}")" '{"n":7}'
}

@test "process_request: the hook runs with errexit off and stdin at /dev/null" {
    local hook_log="${BATS_TEST_TMPDIR}/hook.log"
    mcp_before_tool_call() {
        local read_status=0
        IFS= read -r -t 2 _ || read_status=$?
        false
        printf 'read status %s, ran past false\n' "${read_status}" > "${hook_log}"
    }
    tool_x() { printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')" < /dev/zero

    assert_success
    _assert_result_text "${output}" false "tool output"
    # Status 1 is EOF. A read from /dev/zero, the stdin this test hands
    # process_request, never sees a newline and times out above 128.
    assert_equal "$(<"${hook_log}")" "read status 1, ran past false"
}

@test "process_request: a nested dispatch inside a tool runs the hook for the inner call too" {
    local hook_log="${BATS_TEST_TMPDIR}/hook.log"
    mcp_before_tool_call() { printf '%s\n' "$1" >> "${hook_log}"; }
    tool_inner() { printf 'inner done\n'; }
    tool_nested() { handle_tools_call 9001 '{"name":"inner","arguments":{}}' 2>/dev/null; }

    run --separate-stderr process_request "$(_call_request nested '{}')"

    assert_success
    run jq -e '.result.isError == false' <<< "${output}"
    assert_success
    assert_equal "$(<"${hook_log}")" "$(printf 'nested\ninner')"
}

@test "process_request: the hook and the tool share one EXIT trap, so the tool's replaces the hook's" {
    local trap_log="${BATS_TEST_TMPDIR}/trap.log"
    local hook_marker="${BATS_TEST_TMPDIR}/hook.ran"
    mcp_before_tool_call() {
        : > "${hook_marker}"
        trap 'printf "hook trap\n" >> "${trap_log}"' EXIT
    }
    tool_x() {
        trap 'printf "tool trap\n" >> "${trap_log}"' EXIT
        printf 'tool output\n'
    }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" false "tool output"
    assert [ -e "${hook_marker}" ]
    assert_equal "$(<"${trap_log}")" "tool trap"
}

@test "process_request: an EXIT trap the hook installs runs once the tool has returned" {
    local trap_log="${BATS_TEST_TMPDIR}/trap.log"
    mcp_before_tool_call() { trap 'printf "hook trap\n" >> "${trap_log}"' EXIT; }
    tool_x() { printf 'tool ran\n' >> "${trap_log}"; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    assert_equal "$(<"${trap_log}")" "$(printf 'tool ran\nhook trap')"
}

@test "errexit, nounset and pipefail the hook turns on do not reach the tool" {
    # Driven over the server loop: under `run`, bats calls process_request where
    # errexit is ignored, and the wrapper inherits that, so a leaked errexit
    # would not end the tool there.
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
mcp_before_tool_call() {
    set -euo pipefail
    return 0
}
tool_x() {
    false
    printf 'done\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(_call_request x '{}' 1)"
    run mcp_wait_for_response 1 5

    assert_success
    _assert_result_text "${output}" false "done"
}

@test "process_request: a shopt option the hook sets does not reach the tool" {
    local missing_dir="${BATS_TEST_TMPDIR}/no-such-dir"
    mcp_before_tool_call() { shopt -s nullglob; }
    tool_x() {
        local matches=( "${missing_dir}"/* )
        printf '%s\n' "${#matches[@]}"
    }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    # Without nullglob an unmatched glob stays one literal word.
    _assert_result_text "${output}" false "1"
}

# --- a hook that rewrites PATH ---

@test "process_request: a hook that empties PATH does not stop the call or strand a marker" {
    mcp_before_tool_call() {
        # shellcheck disable=SC2123 # the hook rewrites PATH deliberately: the tool must run with a search path naming nothing.
        PATH=/nonexistent
        return 0
    }
    tool_x() { printf 'done\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    # Nothing the SDK runs after the hook returns may reach for an external
    # command: with a PATH naming nothing, an external step fails with 127, the
    # marker that records the hook's return is never written, and a hook that
    # returned is answered as one that ended the call. The tool reaches for
    # builtins only, so it runs whatever PATH holds.
    _assert_result_text "${output}" false "done"
}

@test "process_request: a hook that empties PATH and refuses is still answered as a refusal" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() {
        printf 'denied by policy\n'
        # shellcheck disable=SC2123 # the hook rewrites PATH deliberately: the refusal must survive a search path naming nothing.
        PATH=/nonexistent
        return 3
    }
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" true "Error executing x: denied by policy"
    assert [ ! -e "${tool_marker}" ]
    run grep -cF "before-tool hook refused tool x (status 3)" "${MCP_LOG_FILE}"
    assert_output "1"
}

# --- a hook that fails ---

@test "process_request: a hook that returns non-zero answers isError with its output and the tool does not run" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() {
        printf 'denied by policy\n'
        return 3
    }
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" true "Error executing x: denied by policy"
    assert [ ! -e "${tool_marker}" ]
}

@test "process_request: a hook that returns non-zero is logged as a refusal, not as a tool failure" {
    mcp_before_tool_call() { return 3; }
    tool_x() { printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    run grep -cF "before-tool hook refused tool x (status 3)" "${MCP_LOG_FILE}"
    assert_output "1"
    run grep -qF "Tool x failed" "${MCP_LOG_FILE}"
    assert_failure 1
}

# --- a hook that ends the wrapper shell instead of returning ---

@test "process_request: a hook that exits 0 answers isError and the tool does not run" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() { exit 0; }
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" true \
        "mcp_before_tool_call ended the call instead of returning; tool x did not run."
    assert [ ! -e "${tool_marker}" ]
}

@test "process_request: a hook that prints then exits non-zero answers isError with the message and its output" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() {
        printf 'X\n'
        exit 4
    }
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    # The captured output follows the message on its own line, with the trailing
    # newline the hook wrote stripped as a command substitution strips it.
    _assert_result_text "${output}" true \
        "$(printf 'mcp_before_tool_call ended the call instead of returning; tool x did not run.\nX')"
    assert [ ! -e "${tool_marker}" ]
}

@test "process_request: a hook that returns 0 still runs the tool (guard: unchanged behavior)" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() { printf 'checked\n'; return 0; }
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" false "tool output"
    assert [ -e "${tool_marker}" ]
}

@test "process_request: a hook killed by a signal answers isError naming the signal and the tool does not run" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() {
        printf 'about to be killed\n'
        kill -9 "${BASHPID}"
    }
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" true \
        "mcp_before_tool_call was killed by signal 9; tool x did not run."
    assert [ ! -e "${tool_marker}" ]
    run grep -qF "Before-tool hook mcp_before_tool_call for tool x was killed (status 137)" "${MCP_LOG_FILE}"
    assert_success
}

@test "process_request: with no hook defined, a tool that kills its own shell is answered as the tool's failure" {
    # The tool runs in the wrapper's shell, so killing BASHPID ends the wrapper
    # before anything is collected from it.
    tool_x() { kill -9 "${BASHPID}"; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" true "Error executing x: "
}

# --- calls the hook does not reach ---

@test "process_request: an undeclared tool answers -32601 without running the hook" {
    local hook_marker="${BATS_TEST_TMPDIR}/hook.ran"
    mcp_before_tool_call() { : > "${hook_marker}"; }
    tool_undeclared() { printf 'should not run\n'; }

    run --separate-stderr process_request "$(_call_request undeclared '{}')"

    assert_success
    run jq -e '.id == 1 and .error.code == -32601' <<< "${output}"
    assert_success
    assert [ ! -e "${hook_marker}" ]
}

@test "process_request: arguments that fail validation answer isError without running the hook" {
    local hook_marker="${BATS_TEST_TMPDIR}/hook.ran"
    mcp_before_tool_call() { : > "${hook_marker}"; }
    tool_x() { printf 'should not run\n'; }

    run --separate-stderr process_request "$(_call_request x '{"n": "seven"}')"

    assert_success
    _assert_result_text "${output}" true 'Invalid type(s): n expected integer, got string ("seven").'
    assert [ ! -e "${hook_marker}" ]
}

@test "process_request: an mcp_before_tool_call executable on PATH is not run as the hook" {
    local path_marker="${BATS_TEST_TMPDIR}/path-hook.ran"
    local bin_dir="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin_dir}"
    printf '#!/usr/bin/env bash\n: > %q\nexit 1\n' "${path_marker}" > "${bin_dir}/mcp_before_tool_call"
    chmod +x "${bin_dir}/mcp_before_tool_call"
    PATH="${bin_dir}:${PATH}"
    tool_x() { printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x '{}')"

    assert_success
    _assert_result_text "${output}" false "tool output"
    assert [ ! -e "${path_marker}" ]
}

# --- cancellation ---

@test "a cancellation stops a hook blocked in sleep, and the tool never runs" {
    export HOOK_SLEEP_PID_FILE="${BATS_TEST_TMPDIR}/hook-sleep.pid"
    export TOOL_MARKER="${BATS_TEST_TMPDIR}/tool.ran"
    printf '%s\n' '{"tools": [{"name": "blocked", "inputSchema": {"type": "object"}}]}' > "${MCP_TOOLS_LIST_FILE}"
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
mcp_before_tool_call() {
    sleep 30 &
    printf '%s\n' "$!" > "${HOOK_SLEEP_PID_FILE}"
    wait "$!"
}
tool_blocked() {
    : > "${TOOL_MARKER}"
    printf 'tool ran\n'
}
BODY
    mcp_start_server "${server}"
    mcp_send "$(_call_request blocked '{}' 41)"
    run _wait_for_file "${HOOK_SLEEP_PID_FILE}" 5
    assert_success
    local sleep_pid
    sleep_pid="$(<"${HOOK_SLEEP_PID_FILE}")"

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":41}}'

    run _wait_for_exit "${sleep_pid}" 5
    assert_success
    run mcp_assert_no_response 41 1
    assert_success
    assert [ ! -e "${TOOL_MARKER}" ]
    # Only the server process is left: the wrapper the hook ran in and the
    # sentinel beside it are gone with the call's group.
    run _wait_for_server_procs "${server}" 1 5
    assert_success
}
