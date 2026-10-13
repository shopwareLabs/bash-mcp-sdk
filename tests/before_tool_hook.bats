#!/usr/bin/env bats
# bats file_tags=mcp-core,before-tool-hook
# Pins the optional mcp_before_tool_call hook a server may define. When it is a
# shell function, every dispatched tools/call runs it first, in the tool's own
# shell, with the tool name and the validated arguments JSON:
#   - it runs with errexit off and stdin at /dev/null, as the tool does;
#   - a hook that returns 0 has its output discarded, and what it sets — a
#     variable, the working directory, an EXIT trap — reaches the tool, while
#     a shell option it sets does not;
#   - a variable the hook assigns does not change which tool function runs,
#     the arguments it receives, or how the call is reported;
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
#   - a hook stopped by the nounset it turned on ends the call the same way,
#     and so does one stopped by the errexit it turned on, also with errtrace
#     on in the server script, while one that returns non-zero with errexit
#     on and no ERR trap of its own is answered as a refusal;
#   - the server's errtrace and ERR trap apply in the tool as without a hook,
#     and with errtrace on an ERR trap the hook installs reaches the tool;
#   - a hook that ends with a status above 128 — killed by a signal, or
#     stopped by errexit at a command that failed with such a status, where
#     bash 4.1 to 4.3 end the hook with status 1 instead — stops the call
#     with an isError result naming the status and the signal it may stand
#     for, followed by the hook's output, and a wrapper killed while no hook
#     is defined is answered as the tool's failure, never as the hook's;
#   - a call that is not dispatched — an undeclared tool, arguments that fail
#     validation — does not run the hook, and neither does an executable on
#     PATH of that name when no function is defined;
#   - a nested handle_tools_call inside a tool runs the hook again;
#   - a cancellation stops a hook that blocks;
#   - with a hook defined, a tool's background child stays in the call's
#     process group and is killed when the call ends.
# Each "did not run" claim is proved by the marker file the hook or the tool
# would have written. Requests are driven through process_request; the
# errexit and cancellation cases drive a throwaway server over the FIFO client
# harness.
# process_request runs under `run --separate-stderr`: bash can report a failed
# job-control setpgid for the wrapper on stderr, and that line is not part of
# the response the assertions parse.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

setup() {
    mcp_test_env "${BATS_TEST_TMPDIR}/config.json" "${BATS_TEST_TMPDIR}/tools.json"

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
    unset HOOK_SLEEP_PID_FILE TOOL_MARKER MCP_SERVER_INSTANCE
}

# --- no hook ---

@test "process_request: with no hook defined the tool result is the tool's output (guard: unchanged behavior)" {
    tool_x() { printf 'tool output\n'; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 false "tool output"
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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    assert [ -e "${hook_marker}" ]
    mcp_assert_tool_result "${output}" 1 false "tool output"
}

@test "process_request: a variable the hook assigns and a directory it changes to reach the tool" {
    local hook_dir="${BATS_TEST_TMPDIR}/hook-dir"
    mkdir -p "${hook_dir}"
    mcp_before_tool_call() {
        HOOK_STATE="from-hook"
        cd "${hook_dir}" || return 1
    }
    tool_x() { printf '%s %s\n' "${HOOK_STATE:-unset}" "${PWD}"; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 false "from-hook ${hook_dir}"
}

@test "process_request: a function the hook defines still reaches the tool" {
    local hook_rm_file="${BATS_TEST_TMPDIR}/hook-rm.ran"
    mcp_before_tool_call() {
        rm() { printf 'hook rm\n' > "${hook_rm_file}"; }
        return 0
    }
    tool_x() { rm -f "${BATS_TEST_TMPDIR}/no-such-file"; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    # The tool called `rm` and the hook's function answered it instead of the
    # utility. The SDK's own steps bypass functions, so this is the one place
    # the hook's definitions still land.
    mcp_assert_tool_result "${output}" 1 false ""
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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    # The hook returned 0, so the tool ran and the call succeeded: a
    # `hook-running` marker the hook's `rm` kept from being removed would have
    # answered "ended the call" instead.
    mcp_assert_tool_result "${output}" 1 false ""
    assert [ -e "${tool_marker}" ]
    run mcp_count_call_roots "${TMPDIR}"
    assert_output "0"
}

@test "process_request: the hook receives the tool name and the arguments JSON the tool receives" {
    local hook_args_file="${BATS_TEST_TMPDIR}/hook-args"
    local tool_args_file="${BATS_TEST_TMPDIR}/tool-args"
    mcp_before_tool_call() { printf '%s\n%s\n' "$1" "$2" > "${hook_args_file}"; }
    tool_x() { printf '%s\n' "$1" > "${tool_args_file}"; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{"n": 7}')"

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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')" < /dev/zero

    assert_success
    mcp_assert_tool_result "${output}" 1 false "tool output"
    # Status 1 is EOF. A read from /dev/zero, the stdin this test hands
    # process_request, never sees a newline and times out above 128.
    assert_equal "$(<"${hook_log}")" "read status 1, ran past false"
}

@test "process_request: a nested dispatch inside a tool runs the hook for the inner call too" {
    local hook_log="${BATS_TEST_TMPDIR}/hook.log"
    mcp_before_tool_call() { printf '%s\n' "$1" >> "${hook_log}"; }
    tool_inner() { printf 'inner done\n'; }
    tool_nested() { handle_tools_call 9001 '{"name":"inner","arguments":{}}' 2>/dev/null; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 nested '{}')"

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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 false "tool output"
    assert [ -e "${hook_marker}" ]
    assert_equal "$(<"${trap_log}")" "tool trap"
}

@test "process_request: an EXIT trap the hook installs runs once the tool has returned" {
    local trap_log="${BATS_TEST_TMPDIR}/trap.log"
    mcp_before_tool_call() { trap 'printf "hook trap\n" >> "${trap_log}"' EXIT; }
    tool_x() { printf 'tool ran\n' >> "${trap_log}"; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

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

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 false "done"
}

@test "a hook stopped by the errexit it turned on ends the call, and the tool does not run" {
    # Driven over the server loop for the reason the test above gives: a direct
    # process_request under `run` ignores the hook's errexit too.
    export TOOL_MARKER="${BATS_TEST_TMPDIR}/tool.ran"
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
mcp_before_tool_call() {
    set -e
    false
    printf 'continued\n'
    return 0
}
tool_x() {
    : > "${TOOL_MARKER}"
    printf 'tool ran\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    # The exact text proves the hook stopped at `false`: had it gone on, its
    # `continued` line would follow the message.
    mcp_assert_tool_result "${output}" 1 true \
        "mcp_before_tool_call ended the call instead of returning; tool x did not run."
    assert [ ! -e "${TOOL_MARKER}" ]
}

@test "a hook with errexit on that returns non-zero is answered as a refusal" {
    export TOOL_MARKER="${BATS_TEST_TMPDIR}/tool.ran"
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
mcp_before_tool_call() {
    set -euo pipefail
    printf 'denied\n'
    return 1
}
tool_x() {
    : > "${TOOL_MARKER}"
    printf 'tool ran\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 true "Error executing x: denied"
    assert [ ! -e "${TOOL_MARKER}" ]
}

@test "with errtrace on in the server script, a hook stopped by its errexit still ends the call" {
    # errtrace makes an ERR trap set in the dispatch reach the hook's body.
    export TOOL_MARKER="${BATS_TEST_TMPDIR}/tool.ran"
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
set -E
mcp_before_tool_call() {
    set -e
    false
    printf 'continued\n'
    return 0
}
tool_x() {
    : > "${TOOL_MARKER}"
    printf 'tool ran\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 true \
        "mcp_before_tool_call ended the call instead of returning; tool x did not run."
    assert [ ! -e "${TOOL_MARKER}" ]
}

@test "a hook stopped by its errexit answers with what it printed before the failing command" {
    export TOOL_MARKER="${BATS_TEST_TMPDIR}/tool.ran"
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
mcp_before_tool_call() {
    set -e
    printf 'before\n'
    false
    printf 'after\n'
    return 0
}
tool_x() {
    : > "${TOOL_MARKER}"
    printf 'tool ran\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 true \
        "$(printf 'mcp_before_tool_call ended the call instead of returning; tool x did not run.\nbefore')"
    assert [ ! -e "${TOOL_MARKER}" ]
}

@test "a hook stopped by its nounset ends the call, and the tool does not run" {
    export TOOL_MARKER="${BATS_TEST_TMPDIR}/tool.ran"
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
mcp_before_tool_call() {
    set -u
    printf '%s\n' "$undefined_variable"
    return 0
}
tool_x() {
    : > "${TOOL_MARKER}"
    printf 'tool ran\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 true \
        "mcp_before_tool_call ended the call instead of returning; tool x did not run." prefix
    assert [ ! -e "${TOOL_MARKER}" ]
}

@test "a hook whose errexit stops it with a status above 128 is not reported as killed by a signal alone" {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        skip "bash ${BASH_VERSION} ends a shell errexit stops with status 1, not the failed command's status"
    fi
    # The hook ends with the status a SIGPIPE death would give.
    export TOOL_MARKER="${BATS_TEST_TMPDIR}/tool.ran"
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
mcp_before_tool_call() {
    set -e
    (exit 141)
    return 0
}
tool_x() {
    : > "${TOOL_MARKER}"
    printf 'tool ran\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 true \
        "mcp_before_tool_call ended with status 141 before returning (signal 13, or a command that failed with that status); tool x did not run."
    assert [ ! -e "${TOOL_MARKER}" ]
}

@test "with a hook defined, the server's errtrace and ERR trap still apply in the tool" {
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
set -E
trap 'printf "server-err\n"' ERR
mcp_before_tool_call() {
    return 0
}
tool_x() {
    false
    printf 'done\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 false "$(printf 'server-err\ndone')"
}

@test "with a hook defined, the tool runs with the errtrace the server script turned on" {
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
set -E
mcp_before_tool_call() {
    return 0
}
tool_x() {
    if [[ $- == *E* ]]; then
        printf 'errtrace on\n'
    else
        printf 'errtrace off\n'
    fi
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 false "errtrace on"
}

@test "an ERR trap the hook installs reaches the tool" {
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
set -E
mcp_before_tool_call() {
    trap 'printf "hook-err\n"' ERR
    return 0
}
tool_x() {
    false
    printf 'done\n'
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    mcp_assert_tool_result "${output}" 1 false "$(printf 'hook-err\ndone')"
}

@test "process_request: a shopt option the hook sets does not reach the tool" {
    local missing_dir="${BATS_TEST_TMPDIR}/no-such-dir"
    mcp_before_tool_call() { shopt -s nullglob; }
    tool_x() {
        local matches=( "${missing_dir}"/* )
        printf '%s\n' "${#matches[@]}"
    }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    # Without nullglob an unmatched glob stays one literal word.
    mcp_assert_tool_result "${output}" 1 false "1"
}

@test "a hook that runs set -o posix leaves expand_aliases, errtrace and posix as the tool had them" {
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
set -E
shopt -s expand_aliases
mcp_before_tool_call() {
    set -o posix
    return 0
}
tool_x() {
    local aliases=off errtrace=off posix=off
    shopt -q expand_aliases && aliases=on
    [[ $- == *E* ]] && errtrace=on
    [[ :${SHELLOPTS}: == *:posix:* ]] && posix=on
    printf 'expand_aliases=%s errtrace=%s posix=%s\n' "${aliases}" "${errtrace}" "${posix}"
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    # The snapshot has expand_aliases on and posix off. Replaying the set
    # snapshot's `set +o posix` turns expand_aliases off, so the tool sees it
    # on only when the shopt values are replayed after that line, and
    # errtrace on only when that replay leaves extdebug out.
    mcp_assert_tool_result "${output}" 1 false "expand_aliases=on errtrace=on posix=off"
}

@test "a hook that runs set +o posix leaves inherit_errexit off and posix on as the tool had them" {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        skip "bash ${BASH_VERSION} has no inherit_errexit option"
    fi
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
set -o posix
shopt -u inherit_errexit
mcp_before_tool_call() {
    set +o posix
    return 0
}
tool_x() {
    local inherit=off posix=off
    shopt -q inherit_errexit && inherit=on
    [[ :${SHELLOPTS}: == *:posix:* ]] && posix=on
    printf 'inherit_errexit=%s posix=%s\n' "${inherit}" "${posix}"
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    # set -o posix turns inherit_errexit on, so the snapshot taken with it
    # off only survives a restore that replays the shopt values after the
    # posix line.
    mcp_assert_tool_result "${output}" 1 false "inherit_errexit=off posix=on"
}

@test "a hook that runs set -o posix leaves errtrace and functrace off when extdebug is on" {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        skip "bash ${BASH_VERSION}: extdebug does not change errtrace or functrace before 4.4"
    fi
    local server="${BATS_TEST_TMPDIR}/server.sh"
    write_server "${server}" <<'BODY'
shopt -s extdebug
set +E +T
mcp_before_tool_call() {
    set -o posix
    return 0
}
tool_x() {
    local extdebug=off errtrace=off functrace=off posix=off
    shopt -q extdebug && extdebug=on
    [[ $- == *E* ]] && errtrace=on
    [[ $- == *T* ]] && functrace=on
    [[ :${SHELLOPTS}: == *:posix:* ]] && posix=on
    printf 'extdebug=%s errtrace=%s functrace=%s posix=%s\n' "${extdebug}" "${errtrace}" "${functrace}" "${posix}"
}
BODY
    mcp_start_server "${server}"

    mcp_send "$(mcp_tools_call_request 1 x '{}')"
    run mcp_wait_for_response 1 5

    assert_success
    # The last restore pass replays the shopt snapshot, and replaying its
    # `shopt -s extdebug` line would turn errtrace and functrace back on.
    mcp_assert_tool_result "${output}" 1 false "extdebug=on errtrace=off functrace=off posix=off"
}

@test "process_request: variables the hook assigns do not change which tool runs, its arguments, or how the call is reported" {
    local inner_marker="${BATS_TEST_TMPDIR}/inner.ran"
    # Each assignment is non-local, so it lands in whatever variable of that
    # name the hook's callers hold. Every value would change the outcome if
    # the SDK read it after the hook: another declared tool, other arguments,
    # a call root that does not exist, a refusal status, and option snapshots
    # that print a marker when they are re-executed.
    mcp_before_tool_call() {
        func_name=tool_inner
        arguments='{"n":99}'
        call_root=/nonexistent
        readonly hook_status=1
        saved_set='printf INJECTED-SET'
        saved_shopt='printf INJECTED-SHOPT'
        set -f
        return 0
    }
    tool_inner() { : > "${inner_marker}"; printf 'inner ran\n'; }
    tool_x() {
        local noglob=off
        if [[ $- == *f* ]]; then
            noglob=on
        fi
        printf '%s noglob=%s\n' "$1" "${noglob}"
    }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{"n": 7}')"

    assert_success
    # The exact text proves the requested tool ran with the validated
    # arguments, that no snapshot string was executed, and that the call was
    # not answered as a refusal or as a hook that ended it; noglob=off proves
    # the restore ran from the SDK's own snapshot.
    mcp_assert_tool_result "${output}" 1 false '{"n":7} noglob=off'
    assert [ ! -e "${inner_marker}" ]
}

# --- a hook that rewrites PATH ---

@test "process_request: a hook that empties PATH does not stop the call or strand a marker" {
    mcp_before_tool_call() {
        # shellcheck disable=SC2123 # the hook rewrites PATH deliberately: the tool must run with a search path naming nothing.
        PATH=/nonexistent
        return 0
    }
    tool_x() { printf 'done\n'; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    # Nothing the SDK runs after the hook returns may reach for an external
    # command: with a PATH naming nothing, an external step fails with 127, the
    # marker that records the hook's return is never written, and a hook that
    # returned is answered as one that ended the call. The tool reaches for
    # builtins only, so it runs whatever PATH holds.
    mcp_assert_tool_result "${output}" 1 false "done"
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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 true "Error executing x: denied by policy"
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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 true "Error executing x: denied by policy"
    assert [ ! -e "${tool_marker}" ]
}

@test "process_request: a hook that returns non-zero is logged as a refusal, not as a tool failure" {
    mcp_before_tool_call() { return 3; }
    tool_x() { printf 'tool output\n'; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 true \
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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    # The captured output follows the message on its own line, with the trailing
    # newline the hook wrote stripped as a command substitution strips it.
    mcp_assert_tool_result "${output}" 1 true \
        "$(printf 'mcp_before_tool_call ended the call instead of returning; tool x did not run.\nX')"
    assert [ ! -e "${tool_marker}" ]
}

@test "process_request: a hook that returns 0 still runs the tool (guard: unchanged behavior)" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() { printf 'checked\n'; return 0; }
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 false "tool output"
    assert [ -e "${tool_marker}" ]
}

@test "process_request: with a hook defined, a tool's background child stays in the call's process group and is killed when the call ends" {
    local long_pid_file="${BATS_TEST_TMPDIR}/long.pid"
    mcp_before_tool_call() { return 0; }
    tool_x() {
        sleep 30 &
        printf '%s' "$!" > "${long_pid_file}"
        sleep 0.2 &
        wait "$!"
        printf 'long=%s\n' "$(<"${long_pid_file}")"
    }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    local text
    text="$(jq -r '.result.content[0].text' <<< "${output}")"
    local long_pid
    long_pid="$(<"${long_pid_file}")"
    run mcp_wait_for_exit "${long_pid}" 3
    kill "${long_pid}" 2>/dev/null || true
    assert_success
    assert_equal "${text}" "long=${long_pid}"
}

@test "process_request: a hook killed by a signal answers isError naming its status, the signal and its output, and the tool does not run" {
    local tool_marker="${BATS_TEST_TMPDIR}/tool.ran"
    mcp_before_tool_call() {
        printf 'about to be killed\n'
        kill -9 "${BASHPID}"
    }
    tool_x() { : > "${tool_marker}"; printf 'tool output\n'; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 true \
        "$(printf '%s\n%s' "mcp_before_tool_call ended with status 137 before returning (signal 9, or a command that failed with that status); tool x did not run." "about to be killed")"
    assert [ ! -e "${tool_marker}" ]
    run grep -qF "Before-tool hook mcp_before_tool_call for tool x ended with status 137 (signal 9, or a command that failed with that status)" "${MCP_LOG_FILE}"
    assert_success
}

@test "process_request: with no hook defined, a tool that kills its own shell is answered as the tool's failure" {
    # The tool runs in the wrapper's shell, so killing BASHPID ends the wrapper
    # before anything is collected from it.
    tool_x() { kill -9 "${BASHPID}"; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 true "Error executing x: "
}

# --- calls the hook does not reach ---

@test "process_request: an undeclared tool answers -32601 without running the hook" {
    local hook_marker="${BATS_TEST_TMPDIR}/hook.ran"
    mcp_before_tool_call() { : > "${hook_marker}"; }
    tool_undeclared() { printf 'should not run\n'; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 undeclared '{}')"

    assert_success
    run jq -e '.id == 1 and .error.code == -32601' <<< "${output}"
    assert_success
    assert [ ! -e "${hook_marker}" ]
}

@test "process_request: arguments that fail validation answer isError without running the hook" {
    local hook_marker="${BATS_TEST_TMPDIR}/hook.ran"
    mcp_before_tool_call() { : > "${hook_marker}"; }
    tool_x() { printf 'should not run\n'; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{"n": "seven"}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 true 'Invalid type(s): n expected integer, got string ("seven").'
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

    run --separate-stderr process_request "$(mcp_tools_call_request 1 x '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 false "tool output"
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
    mcp_send "$(mcp_tools_call_request 41 blocked '{}')"
    run mcp_wait_for_file "${HOOK_SLEEP_PID_FILE}" 5
    assert_success
    local sleep_pid
    sleep_pid="$(<"${HOOK_SLEEP_PID_FILE}")"

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":41}}'

    run mcp_wait_for_exit "${sleep_pid}" 5
    assert_success
    run mcp_assert_no_response 41 1
    assert_success
    assert [ ! -e "${TOOL_MARKER}" ]
    # Only the server process is left: the wrapper the hook ran in and the
    # sentinel beside it are gone with the call's group.
    run mcp_wait_for_server_procs "${server}" exact 1 5
    assert_success
}
