#!/usr/bin/env bats
# bats file_tags=mcp-core,call-tmpdir
# Pins the per-call directory every dispatched tool gets as MCP_CALL_TMPDIR, and
# the EXIT-trap contract a tool can write its own cleanup against:
#   - the directory exists empty, is private to the call, and is distinct per
#     call; the before-tool hook and the tool's child processes see the same
#     one as the tool, and a nested dispatch gets its own;
#   - it sits in a call root that is private to the call, mode 700, alongside
#     the call's other files;
#   - the SDK removes the call root with its contents however the call ends: a
#     normal return, a non-zero exit, a cancellation that has to SIGKILL the
#     group, and a server shutdown with the call in flight — including a
#     subdirectory the tool left read-only or with no permissions at all,
#     without following a symlink in it, and under `set -o posix` without
#     ending the server;
#   - a relative TMPDIR still gives the call absolute paths, so a hook that
#     changes directory does not lose the tool's result;
#   - the cancel hook gets the same MCP_CALL_TMPDIR, on a cancellation and on a
#     shutdown, and can read what the call recorded there;
#   - a call whose call root or MCP_CALL_TMPDIR cannot be created answers
#     isError, never runs, and leaves no file behind;
#   - a tool's own `trap … EXIT` runs when the tool returns and on the SIGTERM
#     step of a cancellation or shutdown, and does not run after a SIGKILL.
# In-process cases go through process_request. Cancellation and shutdown cases
# drive the throwaway server setup() writes over the FIFO client harness. TMPDIR
# points at a directory of the test's own, so what the SDK leaves there is
# observable. process_request runs under `run --separate-stderr`: bash can
# report a failed job-control setpgid for the wrapper on stderr, and that line
# is not part of the response the assertions parse.
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
    TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    export MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT TMPDIR
    mkdir -p "${TMPDIR}"

    # The files the harness server's tools and hooks write their evidence to.
    export DIR_FILE="${BATS_TEST_TMPDIR}/call-dir"
    export EXIT_MARKER="${BATS_TEST_TMPDIR}/exit-trap.ran"
    export CANCEL_HOOK_FILE="${BATS_TEST_TMPDIR}/cancel-hook"

    printf '%s\n' '{}' > "${MCP_CONFIG_FILE}"
    printf '%s\n' '{
        "tools": [
            {"name": "x", "inputSchema": {"type": "object"}},
            {"name": "nested", "inputSchema": {"type": "object"}},
            {"name": "inner", "inputSchema": {"type": "object"}},
            {"name": "recorder", "inputSchema": {"type": "object"}},
            {"name": "stubborn_recorder", "inputSchema": {"type": "object"}}
        ]
    }' > "${MCP_TOOLS_LIST_FILE}"

    # The harness server. Both tools record a state file in their call
    # directory, install an EXIT trap, publish the directory's path last — so a
    # test that sees the path knows the rest is in place — and then block.
    # stubborn_recorder ignores TERM, so only the SIGKILL stops it.
    SERVER="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${SERVER}" <<'BODY'
tool_recorder() {
    printf 'recorded by the call\n' > "${MCP_CALL_TMPDIR}/state"
    trap ': > "${EXIT_MARKER}"' EXIT
    printf '%s\n' "${MCP_CALL_TMPDIR}" > "${DIR_FILE}"
    sleep 30
}
tool_recorder_cancel() {
    printf '%s|%s\n' "${MCP_CALL_TMPDIR}" "$(<"${MCP_CALL_TMPDIR}/state")" > "${CANCEL_HOOK_FILE}"
}
tool_stubborn_recorder() {
    trap '' TERM
    printf 'recorded by the call\n' > "${MCP_CALL_TMPDIR}/state"
    trap ': > "${EXIT_MARKER}"' EXIT
    printf '%s\n' "${MCP_CALL_TMPDIR}" > "${DIR_FILE}"
    local remaining=12
    while (( remaining > 0 )); do
        sleep 1
        remaining=$(( remaining - 1 ))
    done
}
BODY

    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

teardown() {
    mcp_stop_server
    # A locked directory a test left behind would make removing the test's own
    # temp directory fail. A regular file a test put in TMPDIR's place is
    # untouched by this.
    chmod -R u+rwx "${BATS_TEST_TMPDIR}" 2>/dev/null || true
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT \
        TMPDIR DIR_FILE EXIT_MARKER CANCEL_HOOK_FILE MCP_SERVER_INSTANCE MCP_SERVER_PGID
}

# A tools/call line for tool <name> with empty arguments and request id <id>.
_call_request() {
    local name="$1"
    local id="$2"
    jq -nc --arg n "${name}" --argjson id "${id}" \
        '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: $n, arguments: {}}}'
}

# Print the names of the call roots the SDK left under TMPDIR, one per line.
# Every per-call file lives in one.
_call_files_left() {
    local entry
    for entry in "${TMPDIR}"/mcp-call.*; do
        [[ -e "${entry}" ]] || continue
        printf '%s\n' "${entry##*/}"
    done
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

# Wait up to <secs> for the server log to carry a line containing <text>.
_wait_for_log() {
    local text="$1"
    local limit="$2"
    local deadline=$(( SECONDS + limit ))
    while (( SECONDS < deadline )); do
        if [[ -f "${MCP_LOG_FILE}" ]] && grep -qF -- "${text}" "${MCP_LOG_FILE}"; then
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

# --- the directory a tool sees ---

@test "process_request: each call gets its own empty, writable, owner-only MCP_CALL_TMPDIR" {
    local dir_log="${BATS_TEST_TMPDIR}/dirs"
    tool_x() {
        printf '%s\n' "${MCP_CALL_TMPDIR}" >> "${dir_log}"
        [[ -z "$(ls -A "${MCP_CALL_TMPDIR}")" ]] || return 1
        : > "${MCP_CALL_TMPDIR}/probe" || return 1
        local listing
        listing="$(ls -ld "${MCP_CALL_TMPDIR}")"
        printf '%s\n' "${listing:0:10}"
    }

    run --separate-stderr process_request "$(_call_request x 1)"
    assert_success
    run jq -e '.result.isError == false and .result.content[0].text == "drwx------"' <<< "${output}"
    assert_success
    run --separate-stderr process_request "$(_call_request x 2)"
    assert_success
    run jq -e '.result.isError == false and .result.content[0].text == "drwx------"' <<< "${output}"
    assert_success

    local first second
    { IFS= read -r first; IFS= read -r second; } < "${dir_log}"
    assert [ -n "${first}" ]
    assert [ "${first}" != "${second}" ]
    assert_equal "${first%/mcp-call.*/tmp}" "${TMPDIR}"
}

@test "process_request: the before-tool hook, the tool and a process it starts see the same MCP_CALL_TMPDIR" {
    local hook_dir_file="${BATS_TEST_TMPDIR}/hook-dir"
    mcp_before_tool_call() { printf '%s\n' "${MCP_CALL_TMPDIR}" > "${hook_dir_file}"; }
    # The child reads the variable from its environment, which only an export
    # puts there.
    tool_x() { sh -c 'printf "%s\n" "${MCP_CALL_TMPDIR}"'; }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    local tool_dir
    tool_dir="$(jq -r '.result.content[0].text' <<< "${output}")"
    assert [ -n "${tool_dir}" ]
    assert_equal "$(<"${hook_dir_file}")" "${tool_dir}"
}

@test "process_request: a nested dispatch gets its own MCP_CALL_TMPDIR, which shadows the outer one only inside the inner call" {
    local dir_log="${BATS_TEST_TMPDIR}/dirs"
    tool_inner() { printf 'inner %s\n' "${MCP_CALL_TMPDIR}" >> "${dir_log}"; }
    tool_nested() {
        printf 'outer-before %s\n' "${MCP_CALL_TMPDIR}" >> "${dir_log}"
        handle_tools_call 9001 '{"name":"inner","arguments":{}}' >/dev/null 2>&1
        printf 'outer-after %s\n' "${MCP_CALL_TMPDIR}" >> "${dir_log}"
    }

    run --separate-stderr process_request "$(_call_request nested 1)"

    assert_success
    run jq -e '.result.isError == false' <<< "${output}"
    assert_success
    local label before inner after
    { read -r label before; read -r label inner; read -r label after; } < "${dir_log}"
    assert_equal "${before%/mcp-call.*/tmp}" "${TMPDIR}"
    assert_equal "${inner%/mcp-call.*/tmp}" "${TMPDIR}"
    assert [ "${inner}" != "${before}" ]
    assert_equal "${after}" "${before}"
}

# --- removal ---

@test "process_request: a call that returns normally leaves its directory and contents removed" {
    tool_x() {
        mkdir -p "${MCP_CALL_TMPDIR}/nested"
        printf 'scratch\n' > "${MCP_CALL_TMPDIR}/nested/file"
        printf '%s\n' "${MCP_CALL_TMPDIR}"
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    local call_dir
    call_dir="$(jq -r '.result.content[0].text' <<< "${output}")"
    assert_equal "${call_dir%/mcp-call.*/tmp}" "${TMPDIR}"
    assert [ ! -e "${call_dir}" ]
    run _call_files_left
    assert_output ""
}

@test "process_request: a call that exits non-zero leaves its directory removed" {
    tool_x() {
        printf 'scratch\n' > "${MCP_CALL_TMPDIR}/file"
        printf '%s\n' "${MCP_CALL_TMPDIR}"
        return 4
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    local response="${output}"
    run jq -e '.result.isError == true' <<< "${response}"
    assert_success
    local call_dir
    call_dir="$(jq -r '.result.content[0].text | sub("^Error executing x: "; "")' <<< "${response}")"
    assert_equal "${call_dir%/mcp-call.*/tmp}" "${TMPDIR}"
    assert [ ! -e "${call_dir}" ]
    run _call_files_left
    assert_output ""
}

@test "process_request: a call that leaves a read-only subdirectory with a file in it has its directory removed and is answered" {
    tool_x() {
        mkdir "${MCP_CALL_TMPDIR}/ro"
        printf 'scratch\n' > "${MCP_CALL_TMPDIR}/ro/file"
        chmod 555 "${MCP_CALL_TMPDIR}/ro"
        printf '%s\n' "${MCP_CALL_TMPDIR}"
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    local response="${output}"
    run jq -e '.id == 1 and .result.isError == false' <<< "${response}"
    assert_success
    local call_dir
    call_dir="$(jq -r '.result.content[0].text' <<< "${response}")"
    assert_equal "${call_dir%/mcp-call.*/tmp}" "${TMPDIR}"
    assert [ ! -e "${call_dir}" ]
    run _call_files_left
    assert_output ""
    run grep -qF "WARN" "${MCP_LOG_FILE}"
    assert_failure 1
}

@test "under set -o posix a call that leaves a read-only subdirectory is answered and the server answers the next request" {
    local posix_server="${BATS_TEST_TMPDIR}/posix-server.sh"
    write_server "${posix_server}" <<'BODY'
set -o posix
tool_x() {
    mkdir "${MCP_CALL_TMPDIR}/ro"
    printf 'scratch\n' > "${MCP_CALL_TMPDIR}/ro/file"
    chmod 555 "${MCP_CALL_TMPDIR}/ro"
    printf '%s\n' "${MCP_CALL_TMPDIR}"
}
BODY
    mcp_start_server "${posix_server}"

    mcp_send "$(_call_request x 51)"
    run mcp_wait_for_response 51 5
    assert_success
    local response="${output}"
    run jq -e '.result.isError == false' <<< "${response}"
    assert_success
    local call_dir
    call_dir="$(jq -r '.result.content[0].text' <<< "${response}")"
    assert [ ! -e "${call_dir}" ]

    mcp_send '{"jsonrpc":"2.0","id":52,"method":"ping"}'
    run mcp_wait_for_response 52 5
    assert_success
}

@test "process_request: removing a call's directory does not follow a symlink the tool left in it" {
    local outside="${BATS_TEST_TMPDIR}/outside"
    mkdir "${outside}"
    chmod 555 "${outside}"
    tool_x() {
        ln -s "${outside}" "${MCP_CALL_TMPDIR}/link"
        mkdir "${MCP_CALL_TMPDIR}/ro"
        chmod 555 "${MCP_CALL_TMPDIR}/ro"
        printf '%s\n' "${MCP_CALL_TMPDIR}"
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    local call_dir
    call_dir="$(jq -r '.result.content[0].text' <<< "${output}")"
    assert [ ! -e "${call_dir}" ]
    local listing
    listing="$(ls -ld "${outside}")"
    assert_equal "${listing:0:10}" "dr-xr-xr-x"
}

@test "process_request: a call that leaves a nested directory with no permissions has its call root removed without a WARN" {
    tool_x() {
        mkdir -p "${MCP_CALL_TMPDIR}/locked/inner"
        printf 'scratch\n' > "${MCP_CALL_TMPDIR}/locked/inner/file"
        chmod 000 "${MCP_CALL_TMPDIR}/locked/inner"
        chmod 000 "${MCP_CALL_TMPDIR}/locked"
        printf 'tool output\n'
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    run jq -e '.id == 1 and .result.isError == false and .result.content[0].text == "tool output"' <<< "${output}"
    assert_success
    run _call_files_left
    assert_output ""
    run grep -qF "WARN" "${MCP_LOG_FILE}"
    assert_failure 1
}

@test "process_request: a call that removes every permission from MCP_CALL_TMPDIR itself has its call root removed without a WARN" {
    tool_x() {
        printf 'scratch\n' > "${MCP_CALL_TMPDIR}/file"
        chmod 000 "${MCP_CALL_TMPDIR}"
        printf 'tool output\n'
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    run jq -e '.id == 1 and .result.isError == false and .result.content[0].text == "tool output"' <<< "${output}"
    assert_success
    run _call_files_left
    assert_output ""
    run grep -qF "WARN" "${MCP_LOG_FILE}"
    assert_failure 1
}

# --- the call root ---

@test "a call's sentinel and hook output files sit in a call root only the server's user can enter" {
    export ROOT_PROBE="${BATS_TEST_TMPDIR}/root-probe"
    local layout_server="${BATS_TEST_TMPDIR}/layout-server.sh"
    # The hook and the tool look at the root while the call runs: the hook's
    # capture file exists only while the hook runs, the sentinel pid file only
    # on the server loop.
    write_server "${layout_server}" <<'BODY'
mcp_before_tool_call() {
    if [[ -f "${MCP_CALL_TMPDIR%/*}/hook-output" ]]; then
        printf 'hook output inside\n' >> "${ROOT_PROBE}"
    fi
}
tool_x() {
    local root="${MCP_CALL_TMPDIR%/*}"
    local listing
    listing="$(ls -ld "${root}")"
    printf 'root mode %s\n' "${listing:0:10}" >> "${ROOT_PROBE}"
    if [[ -s "${root}/sentinel" ]]; then
        printf 'sentinel inside\n' >> "${ROOT_PROBE}"
    fi
}
BODY
    mcp_start_server "${layout_server}"

    mcp_send "$(_call_request x 56)"
    run mcp_wait_for_response 56 5

    assert_success
    run jq -e '.result.isError == false' <<< "${output}"
    assert_success
    assert_equal "$(<"${ROOT_PROBE}")" "$(printf 'hook output inside\nroot mode drwx------\nsentinel inside')"
}

# --- a relative TMPDIR ---

@test "process_request: with a relative TMPDIR and a hook that changes directory the tool runs and sees an absolute MCP_CALL_TMPDIR" {
    cd "${BATS_TEST_TMPDIR}"
    TMPDIR="tmp"
    mcp_before_tool_call() { cd /; }
    tool_x() {
        if [[ "${MCP_CALL_TMPDIR}" == /* && -d "${MCP_CALL_TMPDIR}" ]]; then
            printf 'absolute and present\n'
        else
            printf 'not usable: %s\n' "${MCP_CALL_TMPDIR}"
        fi
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    run jq -e '.result.isError == false and .result.content[0].text == "absolute and present"' <<< "${output}"
    assert_success
    run _call_files_left
    assert_output ""
}

@test "process_request: with a relative TMPDIR and no hook the tool runs (guard: unchanged behavior)" {
    cd "${BATS_TEST_TMPDIR}"
    TMPDIR="tmp"
    tool_x() { printf 'tool output\n'; }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    run jq -e '.result.isError == false and .result.content[0].text == "tool output"' <<< "${output}"
    assert_success
    run _call_files_left
    assert_output ""
}

# --- the call's files ---

@test "a call on the server loop leaves no call files behind (guard: unchanged behavior)" {
    local plain_server="${BATS_TEST_TMPDIR}/plain-server.sh"
    write_server "${plain_server}" <<'BODY'
tool_x() { printf 'tool output\n'; }
BODY
    mcp_start_server "${plain_server}"

    mcp_send "$(_call_request x 54)"
    run mcp_wait_for_response 54 5

    assert_success
    run jq -e '.result.isError == false and .result.content[0].text == "tool output"' <<< "${output}"
    assert_success
    run _call_files_left
    assert_output ""
}

@test "a cancellation that has to SIGKILL the group removes the call's directory" {
    mcp_start_server "${SERVER}"
    mcp_send "$(_call_request stubborn_recorder 44)"
    run _wait_for_file "${DIR_FILE}" 5
    assert_success
    local call_dir
    call_dir="$(<"${DIR_FILE}")"
    assert [ -f "${call_dir}/state" ]

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":44}}'

    # The second line is logged after the call's files are removed.
    run _wait_for_log "Tool stubborn_recorder ignored SIGTERM; process group killed" 6
    assert_success
    run _wait_for_log "Cancelled tools/call 44 (stubborn_recorder)" 3
    assert_success
    assert [ ! -e "${call_dir}" ]
    run _call_files_left
    assert_output ""
}

@test "a cancellation whose directory the teardown already removed logs no WARN about the call directory" {
    mcp_start_server "${SERVER}"
    mcp_send "$(_call_request recorder 55)"
    run _wait_for_file "${DIR_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":55}}'

    run _wait_for_log "Cancelled tools/call 55 (recorder)" 6
    assert_success
    # The dispatch's own removal runs after that line. A second `find` against
    # the path the teardown just removed is what logs the spurious WARN.
    run _wait_for_log "call directory" 2
    assert_failure
}

@test "a server shutdown with a call in flight removes the call's directory" {
    mcp_start_server_isolated "${SERVER}"
    mcp_send "$(_call_request recorder 45)"
    run _wait_for_file "${DIR_FILE}" 5
    assert_success
    local call_dir
    call_dir="$(<"${DIR_FILE}")"
    assert [ -f "${call_dir}/state" ]

    kill -TERM -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    run _wait_for_exit "${MCP_SERVER_PID}" 6
    assert_success
    assert [ ! -e "${call_dir}" ]
    run _call_files_left
    assert_output ""
}

# --- the cancel hook ---

@test "a cancellation's cancel hook reads what the call recorded in MCP_CALL_TMPDIR" {
    mcp_start_server "${SERVER}"
    mcp_send "$(_call_request recorder 46)"
    run _wait_for_file "${DIR_FILE}" 5
    assert_success
    local call_dir
    call_dir="$(<"${DIR_FILE}")"

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":46}}'

    run _wait_for_file "${CANCEL_HOOK_FILE}" 5
    assert_success
    assert_equal "$(<"${CANCEL_HOOK_FILE}")" "${call_dir}|recorded by the call"
}

@test "a shutdown's cancel hook reads what the call recorded in MCP_CALL_TMPDIR" {
    mcp_start_server_isolated "${SERVER}"
    mcp_send "$(_call_request recorder 47)"
    run _wait_for_file "${DIR_FILE}" 5
    assert_success
    local call_dir
    call_dir="$(<"${DIR_FILE}")"

    kill -TERM -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    run _wait_for_exit "${MCP_SERVER_PID}" 6
    assert_success
    assert [ -e "${CANCEL_HOOK_FILE}" ]
    assert_equal "$(<"${CANCEL_HOOK_FILE}")" "${call_dir}|recorded by the call"
}

# --- a tool's EXIT trap ---

@test "process_request: a tool's EXIT trap runs when the tool returns, and its output joins the result (guard: unchanged behavior)" {
    local trap_marker="${BATS_TEST_TMPDIR}/trap.ran"
    tool_x() {
        trap 'printf "trap output\n"; : > "${trap_marker}"' EXIT
        printf 'body output\n'
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    assert [ -e "${trap_marker}" ]
    run jq -e '.result.isError == false and .result.content[0].text == "body output\ntrap output"' <<< "${output}"
    assert_success
}

@test "a tool's EXIT trap runs on the SIGTERM step of a cancellation" {
    mcp_start_server "${SERVER}"
    mcp_send "$(_call_request recorder 48)"
    run _wait_for_file "${DIR_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":48}}'

    run _wait_for_log "Cancelled tools/call 48 (recorder)" 6
    assert_success
    assert [ -e "${EXIT_MARKER}" ]
    # The tool died on the TERM: no SIGKILL was needed to end it.
    run grep -qF "ignored SIGTERM" "${MCP_LOG_FILE}"
    assert_failure 1
}

@test "a tool's EXIT trap runs on the SIGTERM step of a server shutdown" {
    mcp_start_server_isolated "${SERVER}"
    mcp_send "$(_call_request recorder 49)"
    run _wait_for_file "${DIR_FILE}" 5
    assert_success

    kill -TERM -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    run _wait_for_exit "${MCP_SERVER_PID}" 6
    assert_success
    assert [ -e "${EXIT_MARKER}" ]
}

@test "a tool's EXIT trap does not run when a cancellation has to SIGKILL the group" {
    mcp_start_server "${SERVER}"
    mcp_send "$(_call_request stubborn_recorder 50)"
    run _wait_for_file "${DIR_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":50}}'

    run _wait_for_log "Tool stubborn_recorder ignored SIGTERM; process group killed" 6
    assert_success
    run _wait_for_log "Cancelled tools/call 50 (stubborn_recorder)" 3
    assert_success
    assert [ ! -e "${EXIT_MARKER}" ]
}

# --- a directory that cannot be created ---

@test "under set -o posix a call whose call root cannot be created answers isError, leaves no file in the server's directory, and the server answers the next request" {
    local server_tmp="${BATS_TEST_TMPDIR}/server-tmp"
    local server_cwd="${BATS_TEST_TMPDIR}/server-cwd"
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mkdir "${server_tmp}" "${server_cwd}"
    local posix_server="${BATS_TEST_TMPDIR}/posix-server.sh"
    # The server keeps a TMPDIR of its own, so the harness's capture files stay
    # where the test can read them once the server's TMPDIR is taken away.
    write_server "${posix_server}" <<BODY
set -o posix
export TMPDIR="${server_tmp}"
cd "${server_cwd}"
tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }
BODY
    mcp_start_server "${posix_server}"
    # A regular file where the server's TMPDIR was: no directory can be created
    # in it, whoever the server runs as.
    mv "${server_tmp}" "${server_tmp}.moved"
    : > "${server_tmp}"

    mcp_send "$(_call_request x 57)"
    run mcp_wait_for_response 57 5

    assert_success
    run jq -e '.result.isError == true and .result.content[0].text == "Cannot run x: its call directory could not be created."' <<< "${output}"
    assert_success
    assert [ ! -e "${tool_marker}" ]
    run ls -A "${server_cwd}"
    assert_output ""
    run grep -qF "Tool x not run: cannot create its call directory in ${server_tmp}: " "${MCP_LOG_FILE}"
    assert_success

    mcp_send '{"jsonrpc":"2.0","id":58,"method":"ping"}'
    run mcp_wait_for_response 58 5
    assert_success
}

@test "process_request: a call whose directory cannot be created answers isError and the tool does not run" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }
    # A function named mkdir shadows the binary for this shell only, so the call
    # root's `mktemp -d` still succeeds and the MCP_CALL_TMPDIR creation alone
    # fails.
    mkdir() {
        printf 'mkdir: simulated failure\n' >&2
        return 1
    }

    run --separate-stderr process_request "$(_call_request x 1)"

    assert_success
    run jq -e '.id == 1 and .result.isError == true and .result.content[0].text == "Cannot run x: its call directory could not be created."' <<< "${output}"
    assert_success
    assert [ ! -e "${tool_marker}" ]
    run _call_files_left
    assert_output ""
    run grep -qF "mkdir: simulated failure" "${MCP_LOG_FILE}"
    assert_success
}
