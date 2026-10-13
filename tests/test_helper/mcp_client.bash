#!/bin/bash
# Client harness for driving an MCP server over a FIFO, one JSON-RPC line at a
# time, so a test can write to the server while it is mid-call instead of
# feeding it a fixed stdin and waiting for exit.
#
# Source this file from a BATS suite; it defines no setup or teardown of its
# own. Every helper reports its own failures on stderr and returns non-zero, so
# a caller under `set -e` fails at the point of the problem rather than on a
# timeout later.
#
# Exports set by mcp_start_server:
#   MCP_SERVER_PID      pid of the server process
#   MCP_SERVER_OUT      file capturing the server's stdout (the JSON-RPC stream)
#                       from the first response after startup on:
#                       mcp_start_server sends one ping of its own (id
#                       "mcp-harness-ready"), checks that its response is the
#                       only thing on the stream, then empties the file. The
#                       ping still appears in the server's log and, with
#                       MCP_LOG_STDERR, in MCP_SERVER_ERR.
#   MCP_SERVER_ERR      file capturing the server's stderr
#   MCP_CLIENT_TMPDIR   directory holding the FIFO and both capture files
#   MCP_SERVER_INSTANCE marker unique to this start, carried in the server's
#                       argument vector and inherited by every process the
#                       server forks. A test that has to find the server's
#                       processes with `ps` filters on it, so a server started
#                       by another test — or by another run — is never counted.
#                       The server script receives it as an argument and is
#                       free to ignore it.
#
# mcp_start_server_isolated sets the same, plus MCP_SERVER_PGID, the process
# group id of the server it started.
#
# The write end of the server's stdin stays open in MCP_CLIENT_FD for the life
# of the test, so the server blocks on read instead of seeing EOF between
# messages.

# File descriptor holding the FIFO write end; 0 until mcp_start_server opens
# it. Allocated dynamically (>10) because bats itself holds fd 3, and bats'
# tracing holds fd 4.
MCP_CLIENT_FD=""
MCP_CLIENT_FD_OPEN=0

# Print the process state of <pid>, empty when it has no ps entry. Read from a
# full listing filtered here because BusyBox `ps` has no `-p` selection, and
# through the `stat` keyword, the one spelling procps, BSD and BusyBox share —
# `state` is procps and BSD only.
_mcp_proc_state() {
    local pid="$1"
    local entry_pid state
    while read -r entry_pid state _; do
        if [[ "${entry_pid}" == "${pid}" ]]; then
            printf '%s' "${state}"
            return 0
        fi
    done < <(ps -A -o pid=,stat= 2>/dev/null)
    return 0
}

# Wait until the server just started answers a ping, so its startup (temp files,
# trap installation) is complete before a test signals it or counts its
# processes. Fails loudly on a ping that cannot be written, a server that is
# gone, no answer in 10s, or anything on the protocol stream besides the ping's
# own response: a server that died at startup has not started, and driving its
# pipe would raise the failure somewhere else entirely. On success the capture
# file is emptied, so MCP_SERVER_OUT holds only what a test provokes itself.
_mcp_await_ready() {
    local ready_id="mcp-harness-ready"
    local expected='{"jsonrpc":"2.0","id":"mcp-harness-ready","result":{}}'
    local timeout=10
    local reason=""

    if ! mcp_send "{\"jsonrpc\":\"2.0\",\"id\":\"${ready_id}\",\"method\":\"ping\"}" 2>/dev/null; then
        reason="exited during startup (the ping could not be written)"
    else
        local deadline=$(( SECONDS + timeout ))
        local state
        reason="gave no ping answer within ${timeout}s"
        while (( SECONDS < deadline )); do
            # The id is on the stream and the last byte is a newline, so the
            # response is whole: the comparison never sees a half-written line.
            if grep -qF "\"id\":\"${ready_id}\"" "${MCP_SERVER_OUT}" \
                && [[ -z "$(tail -c 1 "${MCP_SERVER_OUT}")" ]]; then
                if cmp -s - "${MCP_SERVER_OUT}" <<< "${expected}"; then
                    : > "${MCP_SERVER_OUT}"
                    return 0
                fi
                reason="wrote to the protocol stream during startup"
                break
            fi
            # An empty state means the shell already reaped the child, and a
            # leading "Z" means it exited and is waiting to be reaped. `kill -0`
            # cannot stand in for this: it succeeds for a zombie.
            state="$(_mcp_proc_state "${MCP_SERVER_PID}")"
            if [[ -z "${state}" || "${state}" == Z* ]]; then
                reason="exited during startup"
                break
            fi
            sleep 0.1
        done
    fi

    printf 'mcp_start_server: server %s %s\n' "${MCP_SERVER_PID}" "${reason}" >&2
    if [[ -s "${MCP_SERVER_OUT}" ]]; then
        printf 'mcp_start_server: server stdout:\n%s\n' "$(< "${MCP_SERVER_OUT}")" >&2
    fi
    if [[ -s "${MCP_SERVER_ERR}" ]]; then
        printf 'mcp_start_server: server stderr:\n%s\n' "$(< "${MCP_SERVER_ERR}")" >&2
    fi
    mcp_stop_server
    return 1
}

# Start <server-script-path> with a FIFO as its stdin and its stdout and stderr
# captured to files under a fresh temp dir. Returns once the server has answered
# a ping, so it is past startup; fails loudly if it never does.
mcp_start_server() {
    local server_script="${1:-}"
    if [[ -z "${server_script}" || ! -x "${server_script}" ]]; then
        printf 'mcp_start_server: not an executable server script: %s\n' "${server_script}" >&2
        return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/mcp-client.XXXXXX")"
    MCP_CLIENT_TMPDIR="${tmpdir}"
    MCP_SERVER_OUT="${tmpdir}/server.out"
    MCP_SERVER_ERR="${tmpdir}/server.err"
    MCP_SERVER_IN="${tmpdir}/server.in"
    export MCP_CLIENT_TMPDIR MCP_SERVER_OUT MCP_SERVER_ERR

    : > "${MCP_SERVER_OUT}"
    : > "${MCP_SERVER_ERR}"
    mkfifo "${MCP_SERVER_IN}"

    # A marker unique to this start, passed to the server as an argument so it
    # sits in the server's argv. A bash subshell keeps its parent's argv, so
    # every process the server forks carries it, and a process left over from
    # an earlier test or another run carries a different one. The fixture
    # scripts take no arguments and ignore it.
    MCP_SERVER_INSTANCE="mcp-test-$$-${RANDOM}${RANDOM}"
    export MCP_SERVER_INSTANCE

    # Opened for append: the harness empties this file while the server holds it,
    # and a plain write offset would leave NUL bytes before the next response.
    # The child blocks opening the FIFO for reading until the parent opens the
    # write end below; the two opens complete together.
    "${server_script}" "--mcp-test-instance=${MCP_SERVER_INSTANCE}" \
        < "${MCP_SERVER_IN}" >> "${MCP_SERVER_OUT}" 2> "${MCP_SERVER_ERR}" &
    MCP_SERVER_PID=$!
    export MCP_SERVER_PID

    exec {MCP_CLIENT_FD}> "${MCP_SERVER_IN}"
    MCP_CLIENT_FD_OPEN=1

    _mcp_await_ready
}

# Write one JSON-RPC line to the server's stdin. Fails rather than sending a
# blank line, which the server skips silently.
mcp_send() {
    local line="${1:-}"
    if [[ "${MCP_CLIENT_FD_OPEN}" != "1" ]]; then
        printf 'mcp_send: server stdin is not open\n' >&2
        return 1
    fi
    if [[ -z "${line}" ]]; then
        printf 'mcp_send: refusing to send an empty line\n' >&2
        return 1
    fi
    # In a subshell: to a dead reader the write raises SIGPIPE, which ends the
    # subshell instead of the test process.
    if ! ( printf '%s\n' "${line}" >&"${MCP_CLIENT_FD}" ) 2>/dev/null; then
        printf 'mcp_send: write failed; the server is not reading its stdin (pid %s)\n' \
            "${MCP_SERVER_PID}" >&2
        return 1
    fi
}

# Close the held write end, so the server reads EOF. Safe on an already-closed
# stream.
mcp_close_stdin() {
    if [[ "${MCP_CLIENT_FD_OPEN}" == "1" ]]; then
        exec {MCP_CLIENT_FD}>&-
        MCP_CLIENT_FD_OPEN=0
    fi
    return 0
}

# Print the first captured line whose .id equals <id>. Polls until the line
# arrives or <timeout-secs> (default 10) elapse, then returns non-zero with a
# diagnostic on stderr.
mcp_wait_for_response() {
    local id="${1:-}"
    local timeout="${2:-10}"
    if [[ -z "${id}" ]]; then
        printf 'mcp_wait_for_response: missing response id\n' >&2
        return 1
    fi

    local deadline=$(( SECONDS + timeout ))
    local line
    while (( SECONDS < deadline )); do
        while IFS= read -r line; do
            if [[ -z "${line}" ]]; then
                continue
            fi
            if printf '%s' "${line}" | jq -e --argjson id "${id}" '.id == $id' >/dev/null 2>&1; then
                printf '%s\n' "${line}"
                return 0
            fi
        done < "${MCP_SERVER_OUT}"
        sleep 0.1
    done

    printf 'mcp_wait_for_response: no response for id %s within %ss\n' "${id}" "${timeout}" >&2
    return 1
}

# Wait <window-secs>, then fail if any captured line carries <id>. Returns
# non-zero on an unexpected response, so a bare call fails the enclosing test.
mcp_assert_no_response() {
    local id="${1:-}"
    local window="${2:-}"
    if [[ -z "${id}" || -z "${window}" ]]; then
        printf 'mcp_assert_no_response: usage: mcp_assert_no_response <id> <window-secs>\n' >&2
        return 1
    fi

    sleep "${window}"
    local line
    while IFS= read -r line; do
        if [[ -z "${line}" ]]; then
            continue
        fi
        if printf '%s' "${line}" | jq -e --argjson id "${id}" '.id == $id' >/dev/null 2>&1; then
            printf 'mcp_assert_no_response: unexpected response for id %s: %s\n' "${id}" "${line}" >&2
            return 1
        fi
    done < "${MCP_SERVER_OUT}"
    return 0
}

# Close stdin, TERM the server if it is still alive, reap it, and remove the
# temp dir. Safe to call twice, and safe after a failed mcp_start_server. The
# pid and capture paths are left in place so a caller can still assert on them.
mcp_stop_server() {
    mcp_close_stdin

    if [[ -n "${MCP_SERVER_PID:-}" ]] && kill -0 "${MCP_SERVER_PID}" 2>/dev/null; then
        kill -TERM "${MCP_SERVER_PID}" 2>/dev/null || true
        wait "${MCP_SERVER_PID}" 2>/dev/null || true
    fi

    if [[ -n "${MCP_CLIENT_TMPDIR:-}" && -d "${MCP_CLIENT_TMPDIR}" ]]; then
        rm -rf -- "${MCP_CLIENT_TMPDIR}"
    fi
    return 0
}

# Start a server exactly as mcp_start_server does, but in a process group of its
# own, so a test can signal the whole group (the shape a supervisor uses) as
# well as the leader pid alone. Monitor mode is what puts the background job in
# a new group, and the job's pid is that group's id. Everything else — the FIFO,
# the capture files, the exported variables — is mcp_start_server's contract,
# which this does not change.
# Exports on success, in addition to mcp_start_server's: MCP_SERVER_PGID.
mcp_start_server_isolated() {
    local rc=0
    set -m
    mcp_start_server "$@"
    rc=$?
    set +m
    if [[ "${rc}" -ne 0 ]]; then
        return "${rc}"
    fi
    MCP_SERVER_PGID="${MCP_SERVER_PID}"
    export MCP_SERVER_PGID
    return 0
}
