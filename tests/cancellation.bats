#!/usr/bin/env bats
# bats file_tags=mcp-core,cancellation
# Tests notifications/cancelled against a real server over the FIFO harness:
# a cancellation that matches an in-flight tools/call stops the tool — and
# anything it spawned — without a response for that id, a cancellation that
# matches nothing is dropped, and every other line that arrives mid-call is
# answered in order once the call finishes.
# Also pins the two shapes the cancellation window must not reach: stdin EOF
# mid-call, which drains rather than cancels, and a direct call of
# handle_tools_call, which never reads the caller's stdin at all — the same
# reason a tools/call replayed after an in-flight call is answered without
# reading the stream either.
# What a message is, its id decides: an id-carrying message whose id is a string
# or an integer is a request, its id-less form is a notification, and a present
# id of any other type — null, a boolean, a fractional number, an object or an
# array — is neither, since MCP requires a request id to be a string or an
# integer and a notification carries no id, so it is answered -32600 rather than
# dropped. A
# notifications/cancelled that omits requestId must not match even when the
# in-flight id is null.
# What a line is decides too. A line must hold exactly one JSON document: one
# holding two answers -32700 rather than reaching the id handling, whose joined
# id used to end the server. A document of any type passes that gate, and one
# that is not a JSON object is answered -32600 before any field of it is read.
# The group's liveness check must never read a `ps` scan that could not answer
# as an empty group, which is what would drop the SIGKILL escalation.
# A line the client sent in pieces must not withhold the response of the call
# it arrived behind, whether the rest of it never arrives or the client closes
# stdin first, and a fragment may only be joined to a line whose read succeeded.
# A fragment that already parses as JSON is not a fragment at all: it is the
# client's last request, written without a trailing newline, and it is answered
# at the poll loop and at the read loop alike.
# A tool that dispatches a nested call of its own — handle_tools_call and
# process_request are public — must not inherit the outer dispatch's server-loop
# state, so that it neither reads the client's stream nor stops the server.
# The file itself must survive being sourced twice in one shell.
# The server is tests/fixtures/cancellation_server.sh; the client harness is
# tests/test_helper/mcp_client.bash (see its header for the exported paths and
# the fd that holds the server's stdin open).
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"

CANCELLATION_SERVER="${REPO_ROOT}/tests/fixtures/cancellation_server.sh"

# Wait up to <secs> (default 5) for <file> to hold something. The fixture tools
# publish their markers and pids from the server process, so a test waits for
# the evidence that the call is genuinely in flight before acting on it.
_mcp_wait_for_file() {
    local file="$1"
    local limit="${2:-5}"
    local deadline=$(( SECONDS + limit ))
    while (( SECONDS < deadline )); do
        if [[ -s "${file}" ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Wait up to <secs> (default 5) for process <pid> to be gone. A process this
# shell has already reaped has no ps entry; one that exited but has not been
# reaped yet shows state Z. Either way it is no longer running.
_mcp_wait_for_exit() {
    local pid="$1"
    local limit="${2:-5}"
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

# Wait up to <tries> polls of 0.05s for the server log to carry a line matching
# <pattern>. A teardown logs its outcome last, so the line's arrival is when the
# teardown finished — which is what a timing assertion about the grace period
# has to measure. The window is counted in polls rather than seconds because
# SECONDS has one-second granularity and the deadlines here sit well inside a
# single tick.
_mcp_wait_for_log_pattern() {
    local pattern="$1"
    local tries="${2:-20}"
    local i
    for (( i = 0; i < tries; i++ )); do
        if [[ -f "${MCP_LOG_FILE}" ]] && grep -q -- "${pattern}" "${MCP_LOG_FILE}"; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

setup() {
    # Keep the fixture's log inside the test's temp dir, and point the knobs the
    # fixture reads at fresh paths under it.
    export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    export SLOW_MARKER_FILE="${BATS_TEST_TMPDIR}/slow.marker"
    export CHILD_PID_FILE="${BATS_TEST_TMPDIR}/child.pid"
    export CANCEL_HOOK_FILE="${BATS_TEST_TMPDIR}/cancel-hook.json"
    export HOOK_CHILD_PID_FILE="${BATS_TEST_TMPDIR}/hook-child.pid"
    # The direct handle_tools_call tests source the core and call it for tools
    # that are not in any list. An unreadable list is a rejection now, so they
    # get a readable empty one: unlisted tools are not validated, which is the
    # path those tests exercised when no list was set at all. The fixture server
    # overrides this with its own list, so only the direct calls see it.
    export MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
    printf '{"tools": []}\n' > "${MCP_TOOLS_LIST_FILE}"
}

teardown() {
    mcp_stop_server
    unset MCP_LOG_FILE SLOW_MARKER_FILE CHILD_PID_FILE CANCEL_HOOK_FILE \
        HOOK_CHILD_PID_FILE MCP_TOOLS_LIST_FILE SLOW_SECS
}

@test "cancelling an in-flight call kills the tool and its child, and emits no response" {
    export SLOW_SECS=4
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"slow_with_child","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    local child_pid
    child_pid="$(<"${CHILD_PID_FILE}")"

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":101}}'

    # The child the tool spawned is dead within ~3s of the cancellation, so the
    # teardown reached the whole process group and not just the tool.
    local deadline=$(( SECONDS + 3 ))
    while (( SECONDS < deadline )) && kill -0 "${child_pid}" 2>/dev/null; do
        sleep 0.1
    done
    run kill -0 "${child_pid}"
    assert_failure

    run mcp_assert_no_response 101 1
    assert_success

    # The server survived the cancellation and still answers.
    mcp_send '{"jsonrpc":"2.0","id":102,"method":"tools/call","params":{"name":"fast","arguments":{}}}'
    run mcp_wait_for_response 102 5
    assert_success
    run jq -e '.result.isError == false' <<< "${output}"
    assert_success
}

@test "a cancellation naming an unknown id leaves the in-flight call to complete" {
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":201,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":999}}'

    run mcp_wait_for_response 201 6
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"
}

@test "a cancellation while nothing is in flight leaves the next request answerable" {
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":301}}'
    mcp_send '{"jsonrpc":"2.0","id":302,"method":"ping"}'

    run mcp_wait_for_response 302 5
    assert_success
    run jq -e '.id == 302 and has("result")' <<< "${output}"
    assert_success
}

@test "an id-carrying notifications/initialized is a request, and answers -32601" {
    # `notifications/initialized` is handled as a notification, which is what
    # its name and its id-less form say it is. A message carrying an id is a
    # request, so the id-bearing form falls to the unknown-method arm and is
    # answered -32601. 3.0.0 had the method in its dispatch table and emitted
    # nothing for either form, so this is a change in what reaches stdout.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"2.0","id":1301,"method":"notifications/initialized"}'
    run mcp_wait_for_response 1301 5
    assert_success
    run jq -e '.error.code == -32601' <<< "${output}"
    assert_success

    # The id-less form is still the notification it is: logged, never answered.
    mcp_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    mcp_send '{"jsonrpc":"2.0","id":1302,"method":"ping"}'
    run mcp_wait_for_response 1302 5
    assert_success
    run grep -c -- '"error"' "${MCP_SERVER_OUT}"
    assert_output "1"
}

@test "a request carrying a null id is answered -32600 rather than dropped" {
    # MCP requires a request id to be a string or an integer and forbids null,
    # and a notification carries no id at all, so a message with a present null
    # id is neither: it is answered as an invalid request instead of being
    # misread as a notification and dropped. jq's `//` conflated the two, so an
    # absent id and a null id both arrived as null and both fell to the
    # notification gate. 3.0.0 emitted nothing for this message, so this is a
    # change in what reaches stdout.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"2.0","id":null,"method":"ping"}'
    run mcp_wait_for_response null 5
    assert_success
    run jq -e '.error.code == -32600 and .id == null' <<< "${output}"
    assert_success
}

@test "a notification carrying no id is still never answered" {
    # The companion of the null-id case above: an absent id is what makes a
    # message a notification, so it is logged and never answered. Parsing the id
    # by key presence leaves this form with an empty id rather than a null one,
    # and the notification gate reads that empty sentinel. The ping is answered
    # only because it carries an id; the id-less ping ahead of it is not.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"2.0","method":"ping"}'
    mcp_send '{"jsonrpc":"2.0","id":1311,"method":"ping"}'
    run mcp_wait_for_response 1311 5
    assert_success
    run grep -c -- '"jsonrpc"' "${MCP_SERVER_OUT}"
    assert_output "1"
}

@test "a request carrying a boolean id is answered -32600 rather than dispatched" {
    # MCP requires a request id to be a string or an integer, and a notification
    # carries no id at all, so a boolean id is neither and is answered rather
    # than dispatched. `false` is the value jq's `//` dropped alongside the null
    # id, so this message was one of the two silent ones and is answered now;
    # `true` dispatched before and is answered now too. The answer carries a null
    # id, since no valid id can be echoed back.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"2.0","id":false,"method":"ping"}'
    # A sentinel with a known id, answered in order after the line above, so its
    # arrival is when the boolean-id line has already been answered.
    mcp_send '{"jsonrpc":"2.0","id":1400,"method":"ping"}'
    run mcp_wait_for_response 1400 5
    assert_success

    # The boolean id was answered, not dispatched: the one error line is its
    # answer, and the one result line is the sentinel's. A dispatched boolean id
    # would add a second result line for the one message.
    run grep -c -- '"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
    run grep -c -- '"result"' "${MCP_SERVER_OUT}"
    assert_output "1"
    # And the answer echoes no valid id: the -32600 line carries a null id,
    # where a regressed echo of the boolean would carry `false` instead.
    run grep -c -- '"id":null,"error":{"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
}

@test "a bad jsonrpc version with an invalid id answers a null id, not the invalid id" {
    # The version arm runs ahead of the id-type gate, so it has to settle the
    # response id on its own. JSON-RPC 2.0 §5 allows a response id to be a
    # String, Number or Null, so a boolean id is not echoed and the arm answers
    # with null. `false` is the value jq's `//` collapsed to null, which is why
    # the old tree answered null here and this branch regressed to echoing it.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"1.0","id":false,"method":"ping"}'
    # A sentinel with a known id, answered after the line above, so its arrival
    # is when the bad-version line has already been answered.
    mcp_send '{"jsonrpc":"2.0","id":1500,"method":"ping"}'
    run mcp_wait_for_response 1500 5
    assert_success

    # The one version-arm error line carries a null id; echoing the boolean
    # would carry `false` there instead.
    run grep -c -- '"id":null,"error":{"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
}

@test "a request carrying a string id round-trips as a string" {
    # The id is read by key presence and carried with `tojson`, so a string id
    # keeps its JSON type across the parse: "7" is answered as the string "7",
    # never the number 7. The pre-change `jq -c '.id // null'` rendered a
    # present string id as a JSON string too, and the `--argjson` round trip
    # preserved it, which is why this test passes on the pre-change tree; what
    # `//` failed to keep apart was an absent id, a `null` id and a `false` id,
    # all three of which it mapped to null. No other test in the suite sends a
    # string id, so this pins the round trip the parse change rests on.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"2.0","id":"7","method":"ping"}'
    run mcp_wait_for_response '"7"' 5
    assert_success
    run jq -e '.id == "7" and (.id | type) == "string"' <<< "${output}"
    assert_success
}

@test "a request carrying a fractional id is answered -32600 rather than dispatched" {
    # MCP requires a request id to be a string or an integer, so a fractional
    # id is neither a request nor a notification and is answered rather than
    # dispatched. The gate asked only for a JSON number before, so `1.5` was a
    # request that reached its method and was echoed back as a result. The
    # answer carries a null id, the id the server answers with when the request's
    # own id is not one it can echo.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"2.0","id":1.5,"method":"ping"}'
    # A sentinel with a known id, answered in order after the line above, so its
    # arrival is when the fractional-id line has already been answered.
    mcp_send '{"jsonrpc":"2.0","id":1700,"method":"ping"}'
    run mcp_wait_for_response 1700 5
    assert_success

    # The fractional id was answered, not dispatched: the one error line is its
    # answer, and the one result line is the sentinel's. A dispatched fractional
    # id would add a second result line for the one message.
    run grep -c -- '"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
    run grep -c -- '"result"' "${MCP_SERVER_OUT}"
    assert_output "1"
    # And the answer echoes no valid id: the -32600 line carries a null id,
    # where a regressed dispatch would carry the fraction in a result instead.
    run grep -c -- '"id":null,"error":{"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
}

@test "a request carrying a large integer id is dispatched and round-trips unchanged" {
    # The gate pairs a `floor` comparison with a test on the number as jq renders
    # it, so a whole-valued id keeps passing even where the double rounds it:
    # 9007199254740993 is 2^53 + 1, odd, and not representable as a double. The
    # literal test reads the rendering jq parsed rather than the rounded double,
    # so the narrowed gate does not reject a whole number the double cannot hold.
    # This passes before and after the change; it is not a fails-first test.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"2.0","id":9007199254740993,"method":"ping"}'
    run mcp_wait_for_response 9007199254740993 5
    assert_success
    run jq -e '.id == 9007199254740993 and (.id | type) == "number"' <<< "${output}"
    assert_success
    # The id round-trips as the literal the client sent, not as the double it
    # rounds to, which is what pins that the far value survives unchanged.
    run grep -c -- '"id":9007199254740993' "${MCP_SERVER_OUT}"
    assert_output "1"
}

@test "a line holding two JSON documents is answered -32700 and does not stop the server" {
    # A client that omits the trailing newline on one message before writing the
    # next produces one line holding two documents. `jq -e '.'` reported only
    # its last output and accepted it, so the id filter emitted one line per
    # document, the validity test read the joined two-line id as valid, and
    # `--argjson` then rejected it; the non-zero status propagated out of
    # process_request into run_mcp_server's plain `response=$(process_request
    # "$line")` assignment and ended the server. The line is answered -32700
    # instead, and the request behind it is still answered — which is what
    # proves the server survived.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '{"jsonrpc":"2.0","id":1601,"method":"ping"}{"jsonrpc":"2.0","id":1602,"method":"ping"}'
    mcp_send '{"jsonrpc":"2.0","id":1603,"method":"ping"}'

    run mcp_wait_for_response 1603 5
    assert_success
    run jq -e '.id == 1603 and has("result")' <<< "${output}"
    assert_success

    # The offending line is answered once, with a null id and -32700, and its
    # message names the one-document-per-line rule rather than only "Invalid
    # JSON". Neither of its two ids is answered: the line was rejected, not
    # dispatched.
    run grep -c -- '"code":-32700' "${MCP_SERVER_OUT}"
    assert_output "1"
    run grep -c -- 'Expected exactly one JSON document per line' "${MCP_SERVER_OUT}"
    assert_output "1"
    run grep -c -- '"id":1601' "${MCP_SERVER_OUT}"
    assert_output "0"
    run grep -c -- '"id":1602' "${MCP_SERVER_OUT}"
    assert_output "0"
}

@test "a line that is valid JSON but not an object is answered -32600 and does not stop the server" {
    # JSON-RPC 2.0 represents a call as a Request object, so a document of any
    # other type is an Invalid Request. Such a line rendered an empty id from
    # every field extraction, and create_error_response passed that empty string
    # to --argjson, whose rejection ended the server the same way the
    # two-document line did. It is answered -32600 with a null id instead, and
    # the request behind it is still answered.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send '[1,2]'
    mcp_send '{"jsonrpc":"2.0","id":1612,"method":"ping"}'

    run mcp_wait_for_response 1612 5
    assert_success
    run jq -e '.id == 1612 and has("result")' <<< "${output}"
    assert_success

    run grep -c -- '"id":null,"error":{"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
}

@test "a bare false document is answered -32600 rather than -32700" {
    # `false` is valid JSON, so a parse error is the wrong code for it. The
    # `jq -e '.'` parse gate exits non-zero on a whole document that is `null`
    # or `false`, which is why the pre-gate tree answered -32700 for both; the
    # gate now admits a single document of any type, and the object gate
    # answers this one -32600, as it does every other non-object document.
    mcp_start_server "${CANCELLATION_SERVER}"

    mcp_send 'false'
    mcp_send '{"jsonrpc":"2.0","id":1622,"method":"ping"}'

    run mcp_wait_for_response 1622 5
    assert_success
    run jq -e '.id == 1622 and has("result")' <<< "${output}"
    assert_success

    run grep -c -- '"id":null,"error":{"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
    run grep -c -- '"code":-32700' "${MCP_SERVER_OUT}"
    assert_output "0"
}

@test "a cancellation carrying no requestId does not cancel an in-flight call" {
    # handle_tools_call is public API, so a consumer can drive it directly, and
    # with the server-loop state in place it takes the same polling path a full
    # server would. The in-flight id is null — the one value an absent requestId
    # must not match, because jq reads the absent key as null and null == null
    # is true, so without a presence guard this notification stops an unrelated
    # call. Items 1-4 make a null id unreachable through process_request, so the
    # guard has to hold on its own.
    export SLOW_SECS=1
    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
    tool_null_id_call() {
        sleep "${SLOW_SECS}"
        printf 'slow done\n'
    }

    local cancel_file="${BATS_TEST_TMPDIR}/no-requestId.line"
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}' > "${cancel_file}"

    _MCP_IN_SERVER_LOOP=1
    local response
    response="$(handle_tools_call null '{"name":"null_id_call","arguments":{}}' < "${cancel_file}")"

    run jq -r '.result.content[0].text' <<< "${response}"
    assert_success
    assert_output "slow done"
}

@test "a request sent mid-call is answered after the in-flight response, in order" {
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":401,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","id":402,"method":"ping"}'

    run mcp_wait_for_response 401 6
    assert_success
    run mcp_wait_for_response 402 6
    assert_success

    # 401's response is written before 402's, so the mid-call request was held
    # rather than run ahead of the call it arrived behind.
    local stream
    stream="$(<"${MCP_SERVER_OUT}")"
    local before_401="${stream%%\"id\":401*}"
    local before_402="${stream%%\"id\":402*}"
    [[ ${#before_401} -lt ${#before_402} ]]
}

@test "a queued ping is answered when a later notification cancels the call" {
    export SLOW_SECS=5
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":451,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","id":452,"method":"ping"}'
    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":451}}'

    run mcp_assert_no_response 451 1
    assert_success
    run mcp_wait_for_response 452 5
    assert_success
    run jq -e '.id == 452 and has("result")' <<< "${output}"
    assert_success
}

@test "a replayed mid-call tools/call does not consume a pending fragment" {
    # A call that arrives mid-call is answered by replaying it through
    # process_request after the in-flight response. A replayed tools/call would
    # take the mid-call poll path with it — reading the client's stdin from
    # inside the dispatch that still owns the stream, and swallowing the bytes of
    # a fragment that dispatch has already handed to the read loop, or of the
    # next request. The replay therefore runs with the poll disabled: the
    # deferred call completes and answers, and the fragment is completed by the
    # read loop as the client wrote it.
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":1001,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # A second call arrives while the first runs, so the dispatch queues it.
    mcp_send '{"jsonrpc":"2.0","id":1002,"method":"tools/call","params":{"name":"slow_with_child","arguments":{}}}'
    # And a line the client leaves half-written: with the tool ending first, the
    # dispatch hands these bytes out through the partial-line file.
    printf '%s' '{"jsonrpc":"2.0","id":1003,"method":"pi' >&"${MCP_CLIENT_FD}"

    # The child the replayed call spawns is the evidence that the replay is in
    # flight; the first call is `slow` and spawns none. Everything a dispatch
    # writes is held until that dispatch returns, so the response for 1001 only
    # arrives once the replayed call is over — this wait is what puts the bytes
    # below inside it.
    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success

    # The bytes that complete the pending fragment arrive while the replayed call
    # runs. A replayed call polling stdin would take this line as its own and
    # consume it, and the fragment would then be joined to nothing.
    printf '%s\n' 'ng"}' >&"${MCP_CLIENT_FD}"

    run mcp_wait_for_response 1001 6
    assert_success
    run mcp_wait_for_response 1002 6
    assert_success
    run jq -e '.result.isError == false' <<< "${output}"
    assert_success

    # The prefix reached the handoff file, which is what leaves the read loop
    # holding it: _await_tool_call logs the handoff as it writes the bytes out,
    # naming the call it left behind. Asserted before the fragment's own request
    # is, because it is the evidence that the dispatch — not the replay — carried
    # those bytes out: a poll-enabled replay that took both pieces itself would
    # leave every assertion above satisfied without a handoff ever happening.
    run grep -c -- 'Handing a partial line of [0-9][0-9]* characters out of tools/call 1001 (slow) to the read loop' "${MCP_LOG_FILE}"
    assert_output "1"

    run mcp_wait_for_response 1003 6
    assert_success
    run jq -e '.id == 1003 and has("result")' <<< "${output}"
    assert_success

    # The fragment was completed into the one request the client wrote. A line
    # the replayed call had swallowed would come back here as a parse error.
    run grep -c -- '"error"' "${MCP_SERVER_OUT}"
    assert_output "0"
}

@test "a line completed after the tool exits is replayed intact" {
    export SLOW_SECS=1
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":461,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    printf '%s' '{"jsonrpc":"2.0","id":462,"method":"pi' >&"${MCP_CLIENT_FD}"
    sleep 2
    printf '%s\n' 'ng"}' >&"${MCP_CLIENT_FD}"

    run mcp_wait_for_response 461 5
    assert_success
    run mcp_wait_for_response 462 5
    assert_success
    run jq -e '.id == 462 and has("result")' <<< "${output}"
    assert_success
}

@test "malformed cancellation-shaped messages stay queued rather than cancelling" {
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":471,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","id":472,"method":"notifications/cancelled","params":{"requestId":471}}'

    run mcp_wait_for_response 471 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"
    run mcp_wait_for_response 472 5
    assert_success
    run jq -e '.error.code == -32601' <<< "${output}"
    assert_success

    export SLOW_SECS=2
    mcp_send '{"jsonrpc":"2.0","id":473,"method":"tools/call","params":{"name":"slow","arguments":{}}}'
    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success
    mcp_send '{"method":"notifications/cancelled","params":{"requestId":473}}'

    run mcp_wait_for_response 473 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"
    mcp_send '{"jsonrpc":"2.0","id":474,"method":"ping"}'
    run mcp_wait_for_response 474 5
    assert_success
}

@test "a cancellation id must match JSON type, and completed ids are ignored" {
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success
    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"7"}}'

    run mcp_wait_for_response 7 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}'
    mcp_send '{"jsonrpc":"2.0","id":475,"method":"ping"}'
    run mcp_wait_for_response 475 5
    assert_success
}

@test "a tool that ignores SIGTERM is killed and emits no response" {
    export SLOW_SECS=10
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":501,"method":"tools/call","params":{"name":"stubborn","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":501}}'

    # The tool outlives a plain TERM, so this only holds if the escalation to
    # SIGKILL ran: the server is answering again well before SLOW_SECS ends.
    run mcp_assert_no_response 501 3
    assert_success

    mcp_send '{"jsonrpc":"2.0","id":502,"method":"ping"}'
    run mcp_wait_for_response 502 5
    assert_success
}

@test "a ps scan that cannot answer still lets a TERM-ignoring tool be killed" {
    # Telling a live process group from an emptied one is the ps member scan's
    # job: members in the listing mean live, none mean emptied. A ps that fails
    # instead — here a binary reporting 127, the status a shell gives for one
    # that is not there — has not answered at all, and an unanswered liveness
    # must not read as an empty group: the grace loop would end at once, the
    # SIGKILL that follows it would be skipped, and a tool that ignores TERM
    # would outlive its own cancellation.
    # The stub fails only the liveness scan's column signature and hands every
    # other invocation to the real binary, so the harness's own ps reads and
    # the sentinel's group-id read stay answered.
    local real_ps
    real_ps="$(type -P ps)"
    local stub_dir="${BATS_TEST_TMPDIR}/stub-bin"
    mkdir -p "${stub_dir}"
    printf '#!/bin/sh\ncase "$*" in *"pgid=,pid="*) exit 127 ;; esac\nexec %s "$@"\n' \
        "${real_ps}" > "${stub_dir}/ps"
    chmod +x "${stub_dir}/ps"
    PATH="${stub_dir}:${PATH}"
    export PATH

    export SLOW_SECS=8
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":801,"method":"tools/call","params":{"name":"stubborn","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":801}}'

    # The fallback measures the group's raw liveness, so the sentinel holds the
    # grace open for its whole two seconds and the escalation is what ends the
    # tool — well before the eight seconds the tool would otherwise run.
    run _mcp_wait_for_log_pattern 'ignored SIGTERM; process group killed' 80
    assert_success
    run mcp_assert_no_response 801 1
    assert_success

    mcp_send '{"jsonrpc":"2.0","id":802,"method":"ping"}'
    run mcp_wait_for_response 802 5
    assert_success
}

@test "the cancel hook receives the original arguments JSON" {
    export SLOW_SECS=5
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":601,"method":"tools/call","params":{"name":"hooked","arguments":{"alpha":1,"beta":"two"}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":601}}'

    run _mcp_wait_for_file "${CANCEL_HOOK_FILE}" 5
    assert_success
    run jq -e '.alpha == 1 and .beta == "two"' "${CANCEL_HOOK_FILE}"
    assert_success
}

@test "a wedged cancel hook does not leave its TERM-ignoring child behind" {
    export SLOW_SECS=10
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":611,"method":"tools/call","params":{"name":"hooked_child","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success
    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":611}}'

    run _mcp_wait_for_file "${HOOK_CHILD_PID_FILE}" 5
    assert_success
    local hook_child_pid
    hook_child_pid="$(<"${HOOK_CHILD_PID_FILE}")"
    run _mcp_wait_for_exit "${hook_child_pid}" 5
    assert_success
    run mcp_assert_no_response 611 1
    assert_success
}

@test "the cancellation grace waits for a TERM-ignoring group member" {
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":621,"method":"tools/call","params":{"name":"term_wrapper_stubborn_child","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    local child_pid
    child_pid="$(<"${CHILD_PID_FILE}")"

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":621}}'
    sleep 1
    run kill -0 "${child_pid}"
    assert_success
    run _mcp_wait_for_exit "${child_pid}" 3
    assert_success
    run mcp_assert_no_response 621 1
    assert_success
}

@test "cancelling a TERM-compliant tool does not wait out the grace" {
    # The sentinel in the tool's group outlives the tool by design and ignores
    # TERM, so a grace period measured against the group's raw liveness would
    # hold every cancellation for its full two seconds. The teardown is pinned
    # to the tool's own death instead: the cancellation line — the last thing a
    # teardown writes — has to land well inside the grace, not at its end.
    # The tool sleeps far longer than the poll window below, so a teardown that
    # waited on the sentinel could not produce the line in time.
    export SLOW_SECS=30
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":641,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":641}}'

    run _mcp_wait_for_log_pattern 'Cancelled tools/call 641' 20
    assert_success

    run mcp_assert_no_response 641 1
    assert_success
}

@test "a tool's stdin is /dev/null, so its read returns EOF" {
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":701,"method":"tools/call","params":{"name":"reads_stdin","arguments":{}}}'

    run mcp_wait_for_response 701 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success

    # The fixture reports what its read saw. stdin is /dev/null, so the tool
    # must have read EOF — never a line off the client's protocol stream. The
    # check accepts the fixture's plain form and its diagnostic form (read
    # status 1 is EOF; an open-but-idle stream would time out instead).
    local text="${output}"
    if [[ "${text}" == *"jsonrpc"* ]]; then
        fail "the tool consumed a protocol line: ${text}"
    fi
    if [[ "${text}" != *"EOF"* && "${text}" != *"rc:1 "* ]]; then
        fail "the tool's read did not report EOF: ${text}"
    fi
}

@test "a message sent while a stdin-reading tool runs is answered by the server" {
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":711,"method":"tools/call","params":{"name":"reads_stdin","arguments":{}}}'
    mcp_send '{"jsonrpc":"2.0","id":712,"method":"ping"}'

    # A tool that inherited the protocol stream would have consumed the ping's
    # line and the server would never answer 712.
    run mcp_wait_for_response 711 5
    assert_success
    run mcp_wait_for_response 712 5
    assert_success
}

@test "a tool that dispatches a nested call does not read the stream or stop the server" {
    # A consumer tool may call the public entry points itself, which makes the
    # nested call a second dispatch inside the tool's own subshell. It must not
    # inherit the outer dispatch's server-loop state: with `_MCP_IN_SERVER_LOOP`
    # at 1 and the exported file handles in place it polls the tool's /dev/null
    # stdin, reads the instant EOF as a client closing the stream, and touches
    # the shutdown flag — which stops the server the moment the outer call
    # returns — and it overwrites the outer call's in-flight record on the way.
    export SLOW_SECS=3
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":1101,"method":"tools/call","params":{"name":"nested_dispatch","arguments":{}}}'

    run mcp_wait_for_response 1101 5
    assert_success
    local response="${output}"
    run jq -e '.result.isError == false' <<< "${response}"
    assert_success
    # The nested dispatch really ran and answered: the outer tool printed its
    # response, so the nested result is the text of the outer call's result.
    run jq -e '.result.content[0].text | fromjson | .result.content[0].text == "fast done"' <<< "${response}"
    assert_success

    # The EOF the nested dispatch read was its own stdin, never the client's,
    # so the server is still here and still answering requests. Its liveness is
    # asserted before the write below: a server that has already stopped leaves
    # the write below to die on a broken pipe instead of failing here.
    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 1
    assert_failure
    mcp_send '{"jsonrpc":"2.0","id":1102,"method":"ping"}'
    run mcp_wait_for_response 1102 5
    assert_success

    # And a later call is still cancellable: the outer call left the in-flight
    # machinery able to name and stop a tool group.
    mcp_send '{"jsonrpc":"2.0","id":1103,"method":"tools/call","params":{"name":"slow","arguments":{}}}'
    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success
    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1103}}'
    run _mcp_wait_for_log_pattern 'Cancelled tools/call 1103' 20
    assert_success
    run mcp_assert_no_response 1103 1
    assert_success
}

@test "a request line split across two writes is answered intact after the in-flight call" {
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":801,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # A read that times out on a partial line consumes those bytes from the
    # pipe, so the server has to carry the fragment into the rest of the line.
    # The first fragment must therefore reach a read of its own, rather than
    # arrive in the same read as the rest of the line, and the poll loop's read
    # window (0.05s in _await_tool_call) is what this wait has to outlast. No
    # log line marks a read that timed out, so the wait is the whole of the
    # synchronization; what it buys is checked below, by the requests that
    # would come back as a parse error were the bytes dropped or joined wrong.
    printf '%s' '{"jsonrpc":"2.0","id":802,"method":"pi' >&"${MCP_CLIENT_FD}"
    sleep 0.5
    printf '%s\n' 'ng"}' >&"${MCP_CLIENT_FD}"

    run mcp_wait_for_response 801 6
    assert_success
    run mcp_wait_for_response 802 6
    assert_success
    run jq -e '.id == 802 and has("result")' <<< "${output}"
    assert_success

    # The line the client split is answered as the one request it was written
    # as: a lost fragment would leave the tail to be parsed on its own, and a
    # fragment dropped by the EOF path would never be answered at all.
    run grep -c -- '"error"' "${MCP_SERVER_OUT}"
    assert_output "0"
}

@test "EOF during an in-flight call lets it finish and answer, then the server exits" {
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":901,"method":"tools/call","params":{"name":"slow","arguments":{}}}'
    mcp_close_stdin

    # A closed stdin means no further request can arrive — it is not a
    # cancellation. The call was accepted, so its response is still owed, and
    # it carries the tool's completed output rather than a truncated one.
    run mcp_wait_for_response 901 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    # Nothing more can be answered, so the server stops by itself.
    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a complete line queued before EOF is answered, and a trailing fragment is discarded" {
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":911,"method":"tools/call","params":{"name":"slow","arguments":{}}}'
    mcp_send '{"jsonrpc":"2.0","id":912,"method":"ping"}'
    # A half-written message can never be completed once the client is gone.
    printf '%s' '{"jsonrpc":"2.0","id":913,"method":"pi' >&"${MCP_CLIENT_FD}"
    mcp_close_stdin

    # The line that arrived whole is still answered, after the in-flight call.
    run mcp_wait_for_response 911 5
    assert_success
    run mcp_wait_for_response 912 5
    assert_success

    # The fragment is neither answered nor quoted into the log — only its
    # length is recorded, so no client payload reaches the log file.
    run mcp_assert_no_response 913 0
    assert_success
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "1"
    run grep -c '913' "${MCP_LOG_FILE}"
    assert_output "0"

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a complete request sent without a trailing newline is answered when stdin closes mid-call" {
    # 3.0.0 read with `read || [[ -n "$line" ]]`, so it answered a client's last
    # request whether or not it ended in a newline. The call's own poll loop
    # reads the same stream, so a request it is holding when the client closes
    # stdin is answerable too when the joined bytes already parse as JSON. Only
    # a fragment that is not JSON is dropped, because no byte can complete it.
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":1201,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # No trailing newline, and the stream closes behind it, so nothing can ever
    # terminate the line. The wait puts these bytes in the poll loop's buffer
    # rather than in the read that the EOF ends.
    printf '%s' '{"jsonrpc":"2.0","id":1202,"method":"ping"}' >&"${MCP_CLIENT_FD}"
    sleep 0.5
    mcp_close_stdin

    run mcp_wait_for_response 1201 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    # The call was accepted, so its response is owed; the request behind it was
    # finished, so it is answerable too and goes out behind that response.
    run mcp_wait_for_response 1202 5
    assert_success
    run jq -e '.id == 1202 and has("result")' <<< "${output}"
    assert_success
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "0"

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a complete request handed to the read loop and left unterminated is answered at EOF" {
    # The same shape one level up: the dispatch hands its fragment to the read
    # loop, and the client closes stdin before any byte can complete the line.
    # A fragment the loop holds that already parses as JSON is the client's last
    # request, and dropping it would lose a request 3.0.0 answered.
    export SLOW_SECS=1
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":1211,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # The wait outlasts SLOW_SECS, so the tool ends with these bytes still in
    # the poll loop's buffer and the dispatch hands them to the read loop.
    printf '%s' '{"jsonrpc":"2.0","id":1212,"method":"ping"}' >&"${MCP_CLIENT_FD}"
    sleep 2
    run grep -c -- 'Handing a partial line of [0-9][0-9]* characters out of tools/call 1211 (slow) to the read loop' "${MCP_LOG_FILE}"
    assert_output "1"

    mcp_close_stdin

    run mcp_wait_for_response 1211 5
    assert_success
    run mcp_wait_for_response 1212 5
    assert_success
    run jq -e '.id == 1212 and has("result")' <<< "${output}"
    assert_success
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "0"

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a fragment buffered before EOF does not withhold the in-flight response" {
    # The shape that wedged the dispatch: the fragment is taken by a read that
    # then times out — so it sits in the poll loop's buffer rather than being
    # carried by the EOF read — and the client closes stdin while the tool is
    # still running. Nothing else can complete that line, so the loop has to
    # end with the fragment in hand, and the response has to go out anyway.
    export SLOW_SECS=3
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":921,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # The wait outlasts the poll loop's read window (0.05s in _await_tool_call),
    # so the read that takes these bytes has returned into the buffer before
    # the EOF below is read. A read that timed out logs nothing, so the wait is
    # the whole of the synchronization: were the fragment instead carried by
    # the EOF read, the discard below would still be logged and this test would
    # pass without covering the buffer path it exists for.
    printf '%s' '{"jsonrpc":"2.0","id":922,"method":"pi' >&"${MCP_CLIENT_FD}"
    sleep 0.5
    mcp_close_stdin

    # A closed stdin is not a cancellation: the call was accepted, so it still
    # gets the response the tool produced.
    run mcp_wait_for_response 921 6
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    # The fragment is neither answered nor quoted into the log, and it is
    # discarded exactly once — not once by the poll loop and again by whatever
    # code completes the response.
    run mcp_assert_no_response 922 0
    assert_success
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "1"
    run grep -c '922' "${MCP_LOG_FILE}"
    assert_output "0"

    # The response was owed to a client that is gone, so the dispatch is
    # finished: the server stops rather than waiting for a line that can never
    # arrive.
    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a fragment held incomplete does not withhold the in-flight response" {
    # The fragment leaves the dispatch through a file rather than keeping it
    # inside a read that completes it: run_mcp_server collects a dispatch's
    # stdout in a command substitution, so a dispatch that blocked on the line
    # would withhold the response the call had already earned. The response is
    # therefore out while the line is still unterminated, and the fragment's own
    # request is answered once its remaining bytes arrive — which means a client
    # that never finishes the line stalls only the next request, exactly as it
    # would between requests.
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":931,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # Written while the poll loop is running and followed by a wait longer than
    # its 0.05s read window, so the loop holds the bytes when the tool ends.
    printf '%s' '{"jsonrpc":"2.0","id":932,"method":"pi' >&"${MCP_CLIENT_FD}"
    sleep 0.5

    # The tool is done and the fragment is still incomplete, yet the call's
    # response is out: nothing in the dispatch is waiting on that line.
    run mcp_wait_for_response 931 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    # That the handoff is what carried the fragment is checked rather than
    # assumed: the log line is written when the dispatch puts the bytes in the
    # partial-line file, which is before this dispatch returns, so it is there
    # by the time the response above is. A dispatch that had not taken those
    # bytes would have left them in the pipe for the read loop to join itself,
    # and no handoff would have happened.
    run grep -c 'Handing a partial line of' "${MCP_LOG_FILE}"
    assert_output "1"

    # Completing the line is what forms and answers the request it carries,
    # behind the response already sent.
    printf '%s\n' 'ng"}' >&"${MCP_CLIENT_FD}"
    run mcp_wait_for_response 932 5
    assert_success
    run jq -e '.id == 932 and has("result")' <<< "${output}"
    assert_success

    local stream
    stream="$(<"${MCP_SERVER_OUT}")"
    local before_931="${stream%%\"id\":931*}"
    local before_932="${stream%%\"id\":932*}"
    [[ ${#before_931} -lt ${#before_932} ]]
}

@test "a handoff fragment left open when the client closes stdin is discarded" {
    # The fragment reaches the read loop before the EOF does, so the EOF lands
    # on the loop's own read rather than on the dispatch's poll. Nothing can
    # complete the line then, and the response the call owed is already out:
    # the fragment is dropped with only its length logged, and the server stops.
    export SLOW_SECS=1
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":941,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # The wait outlasts SLOW_SECS, so the tool ends with the fragment still
    # unterminated and the dispatch hands it out through the partial-line file
    # before the EOF below arrives.
    printf '%s' '{"jsonrpc":"2.0","id":942,"method":"pi' >&"${MCP_CLIENT_FD}"
    sleep 2
    mcp_close_stdin

    run mcp_wait_for_response 941 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    run _mcp_wait_for_log_pattern 'Discarding a partial line' 20
    assert_success

    run mcp_assert_no_response 942 0
    assert_success
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "1"
    # The read loop's message names no call; only a discard inside a dispatch
    # does, so this pins where the fragment was dropped.
    run grep -c 'during tools/call' "${MCP_LOG_FILE}"
    assert_output "0"
    run grep -c '942' "${MCP_LOG_FILE}"
    assert_output "0"

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a fragment joined to an unterminated EOF suffix is discarded, not dispatched" {
    # The fragment the dispatch handed out is joined to the bytes the failing
    # read stored, because the two are the halves of one line the client wrote
    # in more than one piece. That joined line is only a request when it parses
    # as JSON; here the suffix stops short of completing it, so the client never
    # finished writing a request and the whole line is dropped. Only its length
    # reaches the log, and nothing is answered.
    export SLOW_SECS=1
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":951,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # The tool ends with the fragment still unterminated, so the dispatch hands
    # it to the read loop rather than finishing it inside the call.
    printf '%s' '{"jsonrpc":"2.0","id":952,"method":"pi' >&"${MCP_CLIENT_FD}"
    sleep 2

    # The rest of the line follows, but never a newline, and then the client is
    # gone: the read that takes these bytes is the one that reports the EOF.
    # What arrives stops short of closing the request, so the joined line is not
    # JSON and cannot be answered.
    printf '%s' 'ng' >&"${MCP_CLIENT_FD}"
    sleep 0.5
    mcp_close_stdin

    run mcp_wait_for_response 951 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    # The tool ended before the suffix arrived, so the fragment was still in the
    # dispatch's hand and left the dispatch through the partial-line file — the
    # handoff log line is written as those bytes are put there. That the read
    # loop's own branch ran is asserted before the discard below: the branch joins
    # the fragment this line accounts for to the unterminated suffix, so without
    # it the discard and the absent response would be accounted for by a fragment
    # that never reached the loop at all.
    run grep -c -- 'Handing a partial line of [0-9][0-9]* characters out of tools/call 951 (slow) to the read loop' "${MCP_LOG_FILE}"
    assert_output "1"

    run mcp_assert_no_response 952 1
    assert_success
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "1"
    # The fragment was neither dispatched nor parsed apart from its prefix.
    run grep -c -- '"error"' "${MCP_SERVER_OUT}"
    assert_output "0"

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a fragment joined to an EOF suffix that completes the request is answered" {
    # The same join as the test above, with the bytes that do finish the line:
    # the client wrote a whole request across two writes and never terminated
    # it. The line parses, so it is the client's request and it is answered, and
    # the fragment is not discarded just because no newline ever followed it.
    export SLOW_SECS=1
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":961,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    printf '%s' '{"jsonrpc":"2.0","id":962,"method":"pi' >&"${MCP_CLIENT_FD}"
    sleep 2
    printf '%s' 'ng"}' >&"${MCP_CLIENT_FD}"
    sleep 0.5
    mcp_close_stdin

    run mcp_wait_for_response 961 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    # The handoff is what carried the first half out of the dispatch, so the
    # read loop is where the join happened; asserting it first keeps the answer
    # below from being credited to a fragment that never reached the loop.
    run grep -c -- 'Handing a partial line of [0-9][0-9]* characters out of tools/call 961 (slow) to the read loop' "${MCP_LOG_FILE}"
    assert_output "1"

    run mcp_wait_for_response 962 5
    assert_success
    run jq -e '.id == 962 and has("result")' <<< "${output}"
    assert_success
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "0"
    run grep -c -- '"error"' "${MCP_SERVER_OUT}"
    assert_output "0"

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a bare false fragment handed to the read loop is answered, not discarded" {
    # The handoff of the test above, with a document `jq -e '.'` reads as
    # falsy: `false` is valid JSON, so a fragment carrying it is the client's
    # last request and is answerable. The read loop hands the parsed line to
    # process_request, which decides what it deserves: a non-object document is
    # answered -32600 with a null id, the same answer the bytes get when a
    # newline follows them.
    export SLOW_SECS=1
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":1221,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # The wait outlasts SLOW_SECS, so the tool ends with these bytes still in
    # the poll loop's buffer and the dispatch hands them to the read loop.
    printf '%s' 'false' >&"${MCP_CLIENT_FD}"
    sleep 2
    run grep -c -- 'Handing a partial line of [0-9][0-9]* characters out of tools/call 1221 (slow) to the read loop' "${MCP_LOG_FILE}"
    assert_output "1"

    mcp_close_stdin

    # The fragment is the read loop's last line: it dispatches it, then stops.
    # The exit is what orders that answer ahead of the assertions below, since
    # its id is null and there is no response to poll for.
    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success

    # The fragment parsed, so it was dispatched rather than dropped, and its
    # -32600 answer carries a null id.
    run grep -c -- '"id":null,"error":{"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "0"
}

@test "a bare false sent without a trailing newline is answered when stdin closes mid-call" {
    # The poll loop's own EOF branch, the shape that answers a client's last
    # request written with no trailing newline: `false` is valid JSON, so it is
    # that request rather than a fragment to drop, and it is answered behind
    # the call's own response.
    export SLOW_SECS=2
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":1231,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # No trailing newline, and the stream closes behind it while the tool still
    # runs, so the poll loop holds these bytes when the EOF ends its read.
    printf '%s' 'false' >&"${MCP_CLIENT_FD}"
    sleep 0.5
    mcp_close_stdin

    run mcp_wait_for_response 1231 5
    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    assert_output "slow done"

    # The fragment parsed, so it went behind the call's response as a replay
    # rather than being logged as discarded, and its answer is -32600.
    run grep -c -- '"id":null,"error":{"code":-32600' "${MCP_SERVER_OUT}"
    assert_output "1"
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "0"

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
}

@test "a whitespace-only fragment handed to the read loop is answered, not discarded" {
    # The handoff of the tests above, with a fragment that holds no document at
    # all: `jq -e '.'` exits non-zero on input holding nothing to parse, so
    # whitespace read as a parse failure and was dropped. `jq empty` exits zero
    # on it, so the fragment is handed on to process_request, which answers a
    # line holding no document -32700 — the same answer the bytes get when a
    # newline follows them.
    export SLOW_SECS=1
    mcp_start_server "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":1241,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # The wait outlasts SLOW_SECS, so the tool ends with these bytes still in
    # the poll loop's buffer and the dispatch hands them to the read loop.
    printf '%s' '   ' >&"${MCP_CLIENT_FD}"
    sleep 2
    run grep -c -- 'Handing a partial line of [0-9][0-9]* characters out of tools/call 1241 (slow) to the read loop' "${MCP_LOG_FILE}"
    assert_output "1"

    mcp_close_stdin

    # The fragment is the read loop's last line: it dispatches it, then stops.
    # The exit is what orders that answer ahead of the assertions below, since
    # its id is null and there is no response to poll for.
    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success

    # The fragment was handed on rather than dropped, and its -32700 answer
    # carries a null id.
    run grep -c -- '"id":null,"error":{"code":-32700' "${MCP_SERVER_OUT}"
    assert_output "1"
    run grep -c 'Discarding a partial line' "${MCP_LOG_FILE}"
    assert_output "0"
}

@test "the file can be sourced twice in one shell" {
    # A consumer that sources the file from two places in one shell, or reloads
    # it after an upgrade, must not lose that shell: a second `readonly` on a
    # name the first source marked is a fatal error under `set -e`.
    run bash -c '
        set -e
        source "$1"
        source "$1"
        printf "sourced twice\n"
    ' bash "${REPO_ROOT}/lib/mcpserver_core.sh"

    assert_success
    assert_output "sourced twice"
}

@test "handle_tools_call called directly with stdin at EOF still prints the tool response" {
    # The documented no-read-loop shape: a consumer that drives one request at
    # a time through process_request or handle_tools_call owns its own stdin,
    # so the dispatcher must not read it — an EOF there is the caller's
    # business, not a cancellation.
    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
    tool_trivial() {
        printf 'trivial done\n'
    }

    run handle_tools_call 1 '{"name":"trivial","arguments":{}}' </dev/null

    assert_success
    assert_output '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"trivial done"}],"isError":false}}'
}

@test "a direct call after run_mcp_server returns leaves the caller's stdin alone" {
    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
    # run_mcp_server installs its own EXIT trap, which in this test shell would
    # replace the one bats uses to report the test; the subshell keeps the trap
    # bound to a shell that dies with the call.
    ( run_mcp_server </dev/null )
    tool_after_server_loop() {
        sleep 1
        printf 'after loop done\n'
    }

    exec {input_fd}< <(printf '%s\n' '{"jsonrpc":"2.0","id":992,"method":"ping"}')
    local response
    response="$(handle_tools_call 991 '{"name":"after_server_loop","arguments":{}}' <&"${input_fd}")"
    local remaining
    IFS= read -r remaining <&"${input_fd}"
    exec {input_fd}<&-

    assert_equal "${remaining}" '{"jsonrpc":"2.0","id":992,"method":"ping"}'
    run jq -e '.id == 991 and .result.isError == false' <<< "${response}"
    assert_success
}

@test "a direct handle_tools_call preserves an enabled monitor mode" {
    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
    tool_monitor_state() {
        printf 'monitor state done\n'
    }

    set -m
    handle_tools_call 993 '{"name":"monitor_state","arguments":{}}' >/dev/null
    if ! [[ -o monitor ]]; then
        set +m
        fail "handle_tools_call disabled monitor mode"
    fi
    set +m
}

@test "a direct set -e dispatch keeps running after a tool's failed step" {
    run bash -c '
        set -e
        source "$1"
        tool_fail_then_continue() {
            false
            printf "after failing step\\n"
            return 7
        }
        handle_tools_call 994 "{\"name\":\"fail_then_continue\",\"arguments\":{}}"
    ' bash "${REPO_ROOT}/lib/mcpserver_core.sh"

    assert_success
    run jq -r '.result.content[0].text' <<< "${output}"
    assert_success
    [[ "${output}" == *"after failing step"* ]]
}
