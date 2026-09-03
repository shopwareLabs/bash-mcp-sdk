#!/usr/bin/env bats
# bats file_tags=mcp-core,argument-validation
# Tests for the shared mcpserver_core argument validator:
#   validate_tool_arguments() and its wiring into handle_tools_call().
# Enforces `required` always, `additionalProperties: false` when declared,
# a declared `type` — one name or a list of alternatives — a declared
# `pattern` (string values), `minimum`/`maximum`/`exclusiveMinimum`/
# `exclusiveMaximum` (number values), a declared array `items.type`/
# `items.enum` (each element), and `enum` on any property present in the
# call's arguments. Diagnostic precedence is
# missing > unknown > type > pattern > range > items > enum.
# Sources lib/mcpserver_core.sh directly. Consumers vendor that file verbatim, so
# this suite covers the validator wherever it is vendored.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

setup() {
    MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    MCP_EXTRA_LOG_FILE=""
    MCP_CONFIG_FILE="/dev/null"
    MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
    PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    export MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT

    # Fixture tool list:
    #   strict — required:[number], additionalProperties:false, repo/mode carry enums
    #   loose  — no required, additionalProperties unset (defaults to allowed)
    #   typed  — type/pattern/items coverage: name (string+pattern), count
    #            (integer), active (boolean), tags (array of string, each
    #            enum-constrained)
    #   union  — list-form `type` coverage: count (integer or string), choice
    #            (single-member list plus an enum, for precedence), values
    #            (array whose items.type is a list)
    #   malformed — `type` lists that declare nothing enforceable: empty, and
    #            one carrying a non-string member
    #   ranged — range-keyword coverage: limit (integer, minimum+maximum),
    #            score (number, minimum), above (exclusiveMinimum), below
    #            (exclusiveMaximum), untyped (minimum, no declared type),
    #            plus name/tags/mode to pin range against pattern, items and
    #            enum precedence
    #   badrange — bounds that declare nothing enforceable: a non-number
    #            bound, and the draft-04 boolean `exclusiveMinimum` modifier
    cat > "${MCP_TOOLS_LIST_FILE}" <<'JSON'
{
  "tools": [
    {
      "name": "strict",
      "inputSchema": {
        "type": "object",
        "required": ["number"],
        "properties": {
          "number": {"type": "string"},
          "repo": {"type": "string", "enum": ["a/b", "c/d"]},
          "mode": {"type": "string", "enum": ["development", "production"]}
        },
        "additionalProperties": false
      }
    },
    {
      "name": "loose",
      "inputSchema": {
        "type": "object",
        "properties": { "a": {"type": "string"} }
      }
    },
    {
      "name": "typed",
      "inputSchema": {
        "type": "object",
        "required": ["name"],
        "properties": {
          "name": {"type": "string", "pattern": "^[a-z]+$"},
          "count": {"type": "integer"},
          "active": {"type": "boolean"},
          "tags": {"type": "array", "items": {"type": "string", "enum": ["a", "b", "c"]}}
        }
      }
    },
    {
      "name": "union",
      "inputSchema": {
        "type": "object",
        "properties": {
          "count": {"type": ["integer", "string"]},
          "choice": {"type": ["string"], "enum": ["a", "b"]},
          "values": {"type": "array", "items": {"type": ["integer", "string"]}}
        }
      }
    },
    {
      "name": "malformed",
      "inputSchema": {
        "type": "object",
        "properties": {
          "empty": {"type": []},
          "mixed": {"type": ["string", 7]},
          "emptyitems": {"type": "array", "items": {"type": []}},
          "mixeditems": {"type": "array", "items": {"type": ["string", 7]}}
        }
      }
    },
    {
      "name": "ranged",
      "inputSchema": {
        "type": "object",
        "properties": {
          "limit": {"type": "integer", "minimum": 1, "maximum": 50},
          "score": {"type": "number", "minimum": 1},
          "above": {"type": "number", "exclusiveMinimum": 0},
          "below": {"type": "number", "exclusiveMaximum": 100},
          "untyped": {"minimum": 3},
          "name": {"type": "string", "pattern": "^[a-z]+$"},
          "tags": {"type": "array", "items": {"type": "string"}},
          "mode": {"enum": ["a", "b"]}
        }
      }
    },
    {
      "name": "badrange",
      "inputSchema": {
        "type": "object",
        "properties": {
          "stringbound": {"minimum": "3"},
          "draft04": {"minimum": 0, "exclusiveMinimum": true}
        }
      }
    }
  ]
}
JSON

    source "${REPO_ROOT}/lib/mcpserver_core.sh"

    # Dispatchable stubs that echo a marker so dispatch can be observed.
    tool_strict() { printf 'DISPATCHED:%s\n' "$1"; }
    tool_loose() { printf 'DISPATCHED:%s\n' "$1"; }
    tool_typed() { printf 'DISPATCHED:%s\n' "$1"; }
    tool_ranged() { printf 'DISPATCHED:%s\n' "$1"; }
}

teardown() {
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT
}

# --- validate_tool_arguments: direct unit behavior ---

@test "validate_tool_arguments: missing required field fails with its name" {
    run validate_tool_arguments "strict" '{"repo": "a/b"}'
    assert_failure
    assert_output --partial "Missing required parameter(s): number"
}

@test "validate_tool_arguments: unknown field fails and lists allowed parameters" {
    run validate_tool_arguments "strict" '{"number": "5", "pr": 339}'
    assert_failure
    assert_output --partial "Unknown parameter(s): pr"
    assert_output --partial "Allowed parameters: mode, number, repo"
}

@test "validate_tool_arguments: valid arguments pass with no output" {
    run validate_tool_arguments "strict" '{"number": "5", "repo": "a/b"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: unknown field allowed when additionalProperties is unset" {
    run validate_tool_arguments "loose" '{"a": "x", "anything": "y"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: tool absent from the schema list is not validated" {
    run validate_tool_arguments "nonexistent" '{"whatever": 1}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: value outside the declared enum fails naming property, value, and allowed values" {
    run validate_tool_arguments "strict" '{"number": "5", "repo": "x/y"}'
    assert_failure
    assert_output --partial 'Invalid value(s):'
    assert_output --partial 'repo="x/y"'
    assert_output --partial '(allowed: a/b, c/d)'
}

@test "validate_tool_arguments: two invalid enum values in one call are both named in one message" {
    run validate_tool_arguments "strict" '{"number": "5", "repo": "x/y", "mode": "staging"}'
    assert_failure
    assert_output --partial 'repo="x/y"'
    assert_output --partial '(allowed: a/b, c/d)'
    assert_output --partial 'mode="staging"'
    assert_output --partial '(allowed: development, production)'
}

@test "validate_tool_arguments: a non-string value against a string enum fails on type, not enum" {
    # `mode` declares both type:string and an enum. Type checking now runs
    # before enum checking, so a non-string value is reported as a type
    # mismatch (the more fundamental defect) rather than an enum mismatch —
    # and does so without a jq error.
    run validate_tool_arguments "strict" '{"number": "5", "mode": 5}'
    assert_failure
    assert_output --partial 'Invalid type(s):'
    assert_output --partial 'mode expected string, got number (5)'
    refute_output --partial 'Invalid value(s)'
}

@test "validate_tool_arguments: a property with an enum absent from the arguments passes" {
    run validate_tool_arguments "strict" '{"number": "5"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a property with no enum is unaffected by any value" {
    run validate_tool_arguments "loose" '{"a": "anything-at-all"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: missing required takes precedence over an invalid enum" {
    run validate_tool_arguments "strict" '{"repo": "x/y"}'
    assert_failure
    assert_output --partial "Missing required parameter(s): number"
    refute_output --partial "Invalid value(s)"
}

# --- validate_tool_arguments: type, pattern, and array items ---
# These constraints did not exist before this suite: a wrong-type, wrong-
# pattern, or wrong-item-type/enum value in a schema-typed field was
# previously accepted outright (the schema-driven validator only checked
# required/additionalProperties/enum). Each test below fails against the
# pre-fix validator and passes against the current one.

@test "validate_tool_arguments: valid typed arguments pass with no output" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 5, "active": true, "tags": ["a", "b"]}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a string where an integer is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": "5"}'
    assert_failure
    assert_output --partial "Invalid type(s):"
    assert_output --partial 'count expected integer, got string ("5")'
}

@test "validate_tool_arguments: a non-integer number where an integer is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 5.5}'
    assert_failure
    assert_output --partial "count expected integer, got number (non-integer) (5.5)"
}

@test "validate_tool_arguments: a whole-valued number satisfies a declared integer type" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 5}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a string where a boolean is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "active": "true"}'
    assert_failure
    assert_output --partial 'active expected boolean, got string ("true")'
}

@test "validate_tool_arguments: a value violating pattern is rejected and names the pattern" {
    run validate_tool_arguments "typed" '{"name": "ABC"}'
    assert_failure
    assert_output --partial 'Invalid value(s):'
    assert_output --partial 'name="ABC" does not match pattern ^[a-z]+$'
}

@test "validate_tool_arguments: a value matching pattern passes" {
    run validate_tool_arguments "typed" '{"name": "abc"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an array item of the wrong type is rejected and names the index" {
    run validate_tool_arguments "typed" '{"name": "abc", "tags": ["a", 5]}'
    assert_failure
    assert_output --partial "Invalid array item(s):"
    assert_output --partial 'tags[1] expected string, got number (5)'
}

@test "validate_tool_arguments: an array item outside the declared item enum is rejected and names the index" {
    run validate_tool_arguments "typed" '{"name": "abc", "tags": ["a", "z"]}'
    assert_failure
    assert_output --partial "Invalid array item(s):"
    assert_output --partial 'tags[1]="z" (allowed: a, b, c)'
}

@test "validate_tool_arguments: every array item matching type and enum passes" {
    run validate_tool_arguments "typed" '{"name": "abc", "tags": ["a", "b", "c"]}'
    assert_success
    assert_output ""
}

# Regression: `items` declaring only `type` (no `enum`), or only `enum` (no
# `type`), independently. A prior revision bound both via `// empty`, and
# `X as $v | BODY` runs BODY zero times when X produces zero outputs — so
# whichever of the two keys was absent silently discarded every element,
# including violations of the key that *was* declared. These two schemas
# each declare exactly one of the pair, so each pins its own key.
@test "validate_tool_arguments: an items schema declaring only type (no enum) still catches a type violation" {
    cat > "${MCP_TOOLS_LIST_FILE}" <<'JSON'
{
  "tools": [
    {
      "name": "counts",
      "inputSchema": {
        "type": "object",
        "properties": {
          "values": {"type": "array", "items": {"type": "integer"}}
        }
      }
    }
  ]
}
JSON
    run validate_tool_arguments "counts" '{"values": [1, "not-a-number"]}'
    assert_failure
    assert_output --partial "Invalid array item(s):"
    assert_output --partial 'values[1] expected integer, got string ("not-a-number")'
}

@test "validate_tool_arguments: an items schema declaring only enum (no type) still catches an enum violation" {
    cat > "${MCP_TOOLS_LIST_FILE}" <<'JSON'
{
  "tools": [
    {
      "name": "colors",
      "inputSchema": {
        "type": "object",
        "properties": {
          "values": {"type": "array", "items": {"enum": ["red", "green", "blue"]}}
        }
      }
    }
  ]
}
JSON
    run validate_tool_arguments "colors" '{"values": ["red", "purple"]}'
    assert_failure
    assert_output --partial "Invalid array item(s):"
    assert_output --partial 'values[1]="purple" (allowed: red, green, blue)'
}

@test "validate_tool_arguments: type precedence — a type violation is reported before an unrelated pattern violation" {
    # count is wrong-typed; name's pattern also fails. Type is reported first.
    run validate_tool_arguments "typed" '{"name": "ABC", "count": "5"}'
    assert_failure
    assert_output --partial "Invalid type(s):"
    refute_output --partial "does not match pattern"
}

@test "validate_tool_arguments: type precedence — required is still reported ahead of a type violation" {
    run validate_tool_arguments "typed" '{"count": "5"}'
    assert_failure
    assert_output --partial "Missing required parameter(s): name"
    refute_output --partial "Invalid type(s)"
}

@test "validate_tool_arguments: a reproduction of the reported defect — a number where a string field is declared is now rejected" {
    # The originally reported defect: a tool schema declares a field as
    # type:string (e.g. get_rules' "ids"), and a caller passes a JSON number
    # instead. Previously accepted outright because the validator never read
    # `.type`. "name" here plays that role: type:string, given a number.
    run validate_tool_arguments "typed" '{"name": 12345}'
    assert_failure
    assert_output --partial "Invalid type(s):"
    assert_output --partial "name expected string, got number (12345)"
}

@test "validate_tool_arguments: required, additionalProperties, and enum are unaffected on an untyped tool" {
    # Regression: the pre-existing constraints on the "strict" and "loose"
    # fixtures (no type/pattern/items declared on their properties beyond
    # what earlier tests already cover) still behave exactly as before.
    run validate_tool_arguments "strict" '{"number": "5", "repo": "a/b", "mode": "production"}'
    assert_success
    assert_output ""
}

# --- validate_tool_arguments: a `type` declared as a list of alternatives ---

# JSON Schema allows `"type": ["integer", "string"]` to mean "either". The
# validator once read the list form as "no type constraint" — the guard that
# selected a property for type checking required `type` to be a string, so an
# array-valued `type` dropped the property before any comparison ran, and
# every value passed. `items.type` carried the identical guard.

@test "validate_tool_arguments: a union type accepts a value matching its integer member" {
    run validate_tool_arguments "union" '{"count": 5}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a union type accepts a value matching its string member" {
    run validate_tool_arguments "union" '{"count": "5"}'
    assert_success
    assert_output ""
}

_assert_union_rejects() {
    local arguments="$1" expected_actual="$2"
    run validate_tool_arguments "union" "${arguments}"
    assert_failure
    assert_output --partial "Invalid type(s):"
    assert_output --partial "count expected integer or string, got ${expected_actual}"
}

@test "validate_tool_arguments: an object outside a union type is rejected naming both alternatives" {
    _assert_union_rejects '{"count": {"a": 1}}' 'object ({"a":1})'
}

@test "validate_tool_arguments: an array outside a union type is rejected naming both alternatives" {
    _assert_union_rejects '{"count": [1, 2, 3]}' 'array ([1,2,3])'
}

@test "validate_tool_arguments: a null outside a union type is rejected naming both alternatives" {
    _assert_union_rejects '{"count": null}' 'null (null)'
}

@test "validate_tool_arguments: a boolean outside a union type is rejected naming both alternatives" {
    _assert_union_rejects '{"count": true}' 'boolean (true)'
}

@test "validate_tool_arguments: a non-integer number against a union offering integer but not number reports number (non-integer)" {
    _assert_union_rejects '{"count": 5.5}' 'number (non-integer) (5.5)'
}

@test "validate_tool_arguments: a value outside a single-member union type fails on type, not enum" {
    # The scalar-form counterpart above pins the same precedence. Under a list
    # form the type check once never ran at all, so the value was reported as
    # an enum violation instead.
    run validate_tool_arguments "union" '{"choice": 7}'
    assert_failure
    assert_output --partial "Invalid type(s):"
    assert_output --partial 'choice expected string, got number (7)'
    refute_output --partial 'Invalid value(s)'
}

@test "validate_tool_arguments: array items declaring a union type accept every declared member" {
    run validate_tool_arguments "union" '{"values": [1, "x"]}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an array item outside a union items type is rejected and names the index" {
    run validate_tool_arguments "union" '{"values": [1, true]}'
    assert_failure
    assert_output --partial "Invalid array item(s):"
    assert_output --partial 'values[1] expected integer or string, got boolean (true)'
}

@test "validate_tool_arguments: an empty type list is malformed and left unenforced" {
    run validate_tool_arguments "malformed" '{"empty": true}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a type list carrying a non-string member is malformed and left unenforced" {
    run validate_tool_arguments "malformed" '{"mixed": true}'
    assert_success
    assert_output ""
}

# `items.type` carries the same malformed-list guard as a property `type`, and
# it is a separate expression in the jq program. Without these two, a
# regression that made a malformed `items.type` reject every element would
# leave the whole suite passing.
@test "validate_tool_arguments: an empty items type list is malformed and leaves every element unenforced" {
    run validate_tool_arguments "malformed" '{"emptyitems": [true, {"a": 1}]}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an items type list carrying a non-string member is malformed and leaves every element unenforced" {
    run validate_tool_arguments "malformed" '{"mixeditems": [true, {"a": 1}]}'
    assert_success
    assert_output ""
}

# --- validate_tool_arguments: numeric range keywords ---

# The validator read no range keyword at all: `minimum`, `maximum`,
# `exclusiveMinimum` and `exclusiveMaximum` were declared by consumer schemas
# and never enforced, so `{"limit": -1}` against `minimum: 1` was accepted and
# failed downstream instead. No input below produced a range diagnostic
# pre-change: an out-of-range value was accepted outright unless the call
# violated one of the constraints that were enforced.

@test "validate_tool_arguments: a value equal to minimum is accepted" {
    run validate_tool_arguments "ranged" '{"limit": 1}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a value equal to maximum is accepted" {
    run validate_tool_arguments "ranged" '{"limit": 50}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a value below minimum is rejected naming property, value, and bound" {
    run validate_tool_arguments "ranged" '{"limit": 0}'
    assert_failure
    assert_output "Out-of-range value(s): limit=0 below minimum 1."
}

@test "validate_tool_arguments: a value above maximum is rejected naming property, value, and bound" {
    run validate_tool_arguments "ranged" '{"limit": 999}'
    assert_failure
    assert_output "Out-of-range value(s): limit=999 above maximum 50."
}

@test "validate_tool_arguments: exclusiveMinimum rejects a value equal to the bound" {
    run validate_tool_arguments "ranged" '{"above": 0}'
    assert_failure
    assert_output "Out-of-range value(s): above=0 not above exclusiveMinimum 0."
}

@test "validate_tool_arguments: exclusiveMinimum accepts a value above the bound" {
    run validate_tool_arguments "ranged" '{"above": 0.5}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: exclusiveMaximum rejects a value equal to the bound" {
    run validate_tool_arguments "ranged" '{"below": 100}'
    assert_failure
    assert_output "Out-of-range value(s): below=100 not below exclusiveMaximum 100."
}

@test "validate_tool_arguments: exclusiveMaximum accepts a value below the bound" {
    run validate_tool_arguments "ranged" '{"below": 99}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a non-integer number is checked against the bound like any other number" {
    run validate_tool_arguments "ranged" '{"score": 0.5}'
    assert_failure
    assert_output --partial "score=0.5 below minimum 1"
}

@test "validate_tool_arguments: a reproduction of the reported defect — a negative value against minimum 1 is now rejected" {
    # The originally reported defect: a consumer schema declares `minimum: 1`
    # on a pagination or truncation limit and a caller passes -1. Previously
    # accepted outright, then applied downstream as `per_page=-1`.
    run validate_tool_arguments "ranged" '{"limit": -1}'
    assert_failure
    assert_output --partial "limit=-1 below minimum 1"
}

@test "validate_tool_arguments: a string value with minimum declared is left unenforced" {
    # A range keyword must not start rejecting strings where no type is
    # declared; where one is, the type check has already reported the defect.
    run validate_tool_arguments "ranged" '{"untyped": "ab"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a boolean value with minimum declared is left unenforced" {
    # jq types `true` as "boolean", so the number gate skips it and no
    # coercion to 1 or 0 happens.
    run validate_tool_arguments "ranged" '{"untyped": true}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a number value with minimum declared and no type is still enforced" {
    # The counterpart to the two cases above: the number gate skips other
    # types, it does not disable the bound on the property.
    run validate_tool_arguments "ranged" '{"untyped": 2}'
    assert_failure
    assert_output --partial "untyped=2 below minimum 3"
}

@test "validate_tool_arguments: a non-number bound is malformed and left unenforced" {
    run validate_tool_arguments "badrange" '{"stringbound": 1}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: the draft-04 boolean form of exclusiveMinimum is left unenforced" {
    # draft-04 spelled the exclusive bound as a modifier on `minimum`, so
    # `{"minimum": 0, "exclusiveMinimum": true}` rejects 0 there. This
    # validator implements only the numeric form, so 0 is accepted.
    run validate_tool_arguments "badrange" '{"draft04": 0}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: two out-of-range properties in one call are both named in one message" {
    run validate_tool_arguments "ranged" '{"above": 0, "limit": 999}'
    assert_failure
    assert_output "Out-of-range value(s): above=0 not above exclusiveMinimum 0; limit=999 above maximum 50."
}

@test "validate_tool_arguments: range precedence — a type violation is reported before a range violation on the same value" {
    # 0.5 fails both: `limit` declares integer, and 0.5 is below minimum 1.
    run validate_tool_arguments "ranged" '{"limit": 0.5}'
    assert_failure
    assert_output --partial "limit expected integer, got number (non-integer) (0.5)"
    refute_output --partial "Out-of-range"
}

@test "validate_tool_arguments: range precedence — a pattern violation is reported before an unrelated range violation" {
    run validate_tool_arguments "ranged" '{"name": "ABC", "limit": 0}'
    assert_failure
    assert_output --partial "does not match pattern"
    refute_output --partial "Out-of-range"
}

@test "validate_tool_arguments: range precedence — a range violation is reported before an unrelated items violation" {
    run validate_tool_arguments "ranged" '{"limit": 0, "tags": [7]}'
    assert_failure
    assert_output --partial "limit=0 below minimum 1"
    refute_output --partial "Invalid array item(s)"
}

@test "validate_tool_arguments: range precedence — a range violation is reported before an unrelated enum violation" {
    run validate_tool_arguments "ranged" '{"limit": 0, "mode": "z"}'
    assert_failure
    assert_output --partial "limit=0 below minimum 1"
    refute_output --partial "mode="
}

@test "validate_tool_arguments: a property carrying a bound and absent from the arguments is not reported" {
    run validate_tool_arguments "ranged" '{"name": "abc"}'
    assert_success
    assert_output ""
}

# --- validate_tool_arguments: a declared integer against a large literal ---

# The whole-value check ran `val == (val | floor)`, and `floor` converts its
# input to an IEEE-754 double. At or above 2^52 = 4503599627370496 the double
# spacing reaches 1, so `4503599627370496.5` was already whole before the
# comparison ran and the fractional value was accepted outright — then passed
# to the tool function with its fraction intact. The check now also reads the
# number as jq renders it, which still carries the fraction. Each rejection
# case at or above the threshold was accepted outright pre-change; the
# precedence case was rejected pre-change as an out-of-range value, so only its
# diagnostic category changes; the two small-fraction cases were rejected
# pre-change and pin that the added conjunct did not displace the value test.
# Every acceptance case was accepted pre-change too and pins that the added
# conjunct rejects nothing that is an integer under JSON Schema.

@test "validate_tool_arguments: a fractional literal at 2^52 where an integer is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 4503599627370496.5}'
    assert_failure
    assert_output --partial "Invalid type(s):"
    assert_output --partial "count expected integer, got number (non-integer) (4503599627370496.5)"
}

@test "validate_tool_arguments: a negative fractional literal at 2^52 where an integer is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": -4503599627370496.5}'
    assert_failure
    assert_output --partial "count expected integer, got number (non-integer) (-4503599627370496.5)"
}

@test "validate_tool_arguments: the whole value at 2^52 satisfies a declared integer type" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 4503599627370496}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an odd whole value above 2^53 satisfies a declared integer type" {
    # 9007199254740993 has no exact double, so a check deciding from the
    # rounded value alone would have to guess. Reading the literal keeps it
    # accepted.
    run validate_tool_arguments "typed" '{"name": "abc", "count": 9007199254740993}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a small non-integer where an integer is declared is rejected unchanged" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 1.5}'
    assert_failure
    assert_output --partial "count expected integer, got number (non-integer) (1.5)"
}

@test "validate_tool_arguments: an exponent-rendered fraction where an integer is declared is rejected by the value test" {
    # jq renders 1.5e-7 as "1.5E-7", which takes the exponent fallback and so
    # reaches only the `floor` comparison. This is the case that pins that
    # conjunct: drop it and this value is accepted.
    run validate_tool_arguments "typed" '{"name": "abc", "count": 1.5e-7}'
    assert_failure
    assert_output --partial "count expected integer, got number (non-integer) (1.5E-7)"
}

@test "validate_tool_arguments: a literal written with a zero fraction satisfies a declared integer type" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 1.0}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an exponent literal with no fraction satisfies a declared integer type" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 1e2}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an exponent literal whose value is whole satisfies a declared integer type" {
    # 1.5e3 is 1500 — an integer under JSON Schema even though its literal
    # carries a fraction. jq renders it as "1.5E+3", so a rejection driven by
    # the rendered text alone would wrongly refuse it.
    run validate_tool_arguments "typed" '{"name": "abc", "count": 1.5e3}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a fractional literal at 2^52 against a union offering integer is rejected naming both alternatives" {
    run validate_tool_arguments "union" '{"count": 4503599627370496.5}'
    assert_failure
    assert_output --partial "Invalid type(s):"
    assert_output --partial "count expected integer or string, got number (non-integer) (4503599627370496.5)"
}

@test "validate_tool_arguments: a fractional array element at 2^52 against an integer items type is rejected and names the index" {
    cat > "${MCP_TOOLS_LIST_FILE}" <<'JSON'
{
  "tools": [
    {
      "name": "counts",
      "inputSchema": {
        "type": "object",
        "properties": {
          "values": {"type": "array", "items": {"type": "integer"}}
        }
      }
    }
  ]
}
JSON
    run validate_tool_arguments "counts" '{"values": [1, 4503599627370496.5]}'
    assert_failure
    assert_output --partial "Invalid array item(s):"
    assert_output --partial "values[1] expected integer, got number (non-integer) (4503599627370496.5)"
}

@test "validate_tool_arguments: a fractional array element at 2^52 against a union items type is rejected naming both alternatives" {
    # The scalar `items.type` case above and the property-level union case each
    # reach type_ok down a different route. This one crosses them, so a
    # regression confined to a union-typed `items` cannot hide behind either.
    run validate_tool_arguments "union" '{"values": [1, 4503599627370496.5]}'
    assert_failure
    assert_output --partial "Invalid array item(s):"
    assert_output --partial "values[1] expected integer or string, got number (non-integer) (4503599627370496.5)"
}

@test "validate_tool_arguments: precedence — a fractional literal at 2^52 is reported as a type defect, not a range defect" {
    # `limit` declares integer plus minimum 1 and maximum 50, and the value
    # violates both. Pre-change the type check could not see the fraction, so
    # the call was reported as out of range instead.
    run validate_tool_arguments "ranged" '{"limit": 4503599627370496.5}'
    assert_failure
    assert_output --partial "limit expected integer, got number (non-integer) (4503599627370496.5)"
    refute_output --partial "Out-of-range"
}

@test "validate_tool_arguments: exponent notation does not by itself escape the fractional-literal check" {
    # jq renders 4503599627370496.5e0 back as "4503599627370496.5" — it keeps
    # an exponent only for a value that is an exact multiple of ten or whose
    # magnitude is below about 1e-6 — so writing the fraction with a trailing
    # `e0` does not reach the exponent fallback.
    run validate_tool_arguments "typed" '{"name": "abc", "count": 4503599627370496.5e0}'
    assert_failure
    assert_output --partial "count expected integer, got number (non-integer) (4503599627370496.5)"
}

@test "validate_tool_arguments: KNOWN GAP — a fractional value below the smallest subnormal double is accepted as an integer" {
    # Not desired behavior. A rendering that keeps an exponent falls back to
    # the double-based verdict, and 1.5e-400 underflows to 0, which is whole.
    # Closing this needs decimal arithmetic in jq to expand the exponent
    # exactly. Whoever closes it inverts this test.
    run validate_tool_arguments "typed" '{"name": "abc", "count": 1.5e-400}'
    assert_success
    assert_output ""
}

# --- validate_tool_arguments: arguments that are not a JSON object ---

# Every schema constraint reads `$args | keys`, which errors on a non-object.
# Each of these once passed validation, taking `required`,
# `additionalProperties` and `enum` down with it.
_assert_rejects_non_object() {
    local arguments="$1" expected_type="$2"
    run validate_tool_arguments "strict" "${arguments}"
    assert_failure
    assert_output --partial "Invalid arguments: expected a JSON object, got ${expected_type}."
}

@test "validate_tool_arguments: a string in place of an arguments object is rejected" {
    _assert_rejects_non_object '"oops"' "string"
}

@test "validate_tool_arguments: an array in place of an arguments object is rejected" {
    _assert_rejects_non_object '[1,2]' "array"
}

@test "validate_tool_arguments: a null in place of an arguments object is rejected" {
    _assert_rejects_non_object 'null' "null"
}

@test "validate_tool_arguments: an empty object is still checked against required parameters" {
    run validate_tool_arguments "strict" '{}'
    assert_failure
    assert_output --partial "Missing required parameter(s): number"
}

# --- validate_tool_arguments: a jq failure is a rejection, not a skip ---

@test "validate_tool_arguments: arguments that are not JSON at all are rejected" {
    run validate_tool_arguments "strict" '{not valid json'
    assert_failure
    assert_output --partial "Cannot validate arguments for strict"
    assert_output --partial "could not be evaluated against its schema"
}

@test "validate_tool_arguments: an unparseable tool list is rejected rather than skipping validation" {
    printf '%s' '{"tools": [ broken' > "${MCP_TOOLS_LIST_FILE}"
    run validate_tool_arguments "strict" '{"number": "5"}'
    assert_failure
    assert_output --partial "is not parseable JSON"
}

# --- handle_tools_call: wiring (validation runs before dispatch) ---

@test "handle_tools_call: invalid arguments return an isError result, not a dispatch" {
    local params
    params=$(jq -n -c '{name: "strict", arguments: {repo: "a/b"}}')
    run handle_tools_call 1 "$params"
    assert_success
    assert_output --partial '"isError":true'
    assert_output --partial "Missing required parameter(s): number"
    refute_output --partial "DISPATCHED"
}

@test "handle_tools_call: invalid enum returns an isError result, not a dispatch" {
    local params
    params=$(jq -n -c '{name: "strict", arguments: {number: "5", repo: "x/y"}}')
    run handle_tools_call 1 "$params"
    assert_success
    assert_output --partial '"isError":true'
    assert_output --partial 'Invalid value(s):'
    refute_output --partial "DISPATCHED"
}

@test "handle_tools_call: an out-of-range argument returns an isError result, not a dispatch" {
    local params
    params=$(jq -n -c '{name: "ranged", arguments: {limit: 999}}')
    run handle_tools_call 1 "$params"
    assert_success
    assert_output --partial '"isError":true'
    assert_output --partial "limit=999 above maximum 50"
    refute_output --partial "DISPATCHED"
}

@test "handle_tools_call: valid arguments are dispatched to the tool" {
    local params
    params=$(jq -n -c '{name: "strict", arguments: {number: "5"}}')
    run handle_tools_call 1 "$params"
    assert_success
    assert_output --partial "DISPATCHED"
    assert_output --partial '"isError":false'
}

# handle_tools_call derives `arguments` out of the params before validating, and
# that derivation is what decides which types reach the validator at all. Written
# as `.arguments // {}` it substituted {} for a present `null` and a present
# `false` — jq's `//` treats both as absent — so those two were silently coerced
# into a valid empty object while every other non-object was rejected. One case
# per JSON type, because the derivation discriminates by type and nothing else.
# These are not remote-unreachable: process_request only requires the request to
# be parseable JSON, and every value below is.
_assert_call_rejects_non_object() {
    local arguments_json="$1" expected_type="$2"
    local params
    params=$(jq -n -c --argjson a "${arguments_json}" '{name: "strict", arguments: $a}')
    run handle_tools_call 1 "$params"
    assert_success
    assert_output --partial '"isError":true'
    assert_output --partial "expected a JSON object, got ${expected_type}."
    refute_output --partial "DISPATCHED"
}

@test "handle_tools_call: a null arguments value is rejected, not coerced to an empty object" {
    _assert_call_rejects_non_object 'null' "null"
}

@test "handle_tools_call: a false arguments value is rejected, not coerced to an empty object" {
    _assert_call_rejects_non_object 'false' "boolean"
}

@test "handle_tools_call: a true arguments value is not dispatched to the tool" {
    _assert_call_rejects_non_object 'true' "boolean"
}

@test "handle_tools_call: a number arguments value is not dispatched to the tool" {
    _assert_call_rejects_non_object '0' "number"
}

@test "handle_tools_call: a string arguments value is not dispatched to the tool" {
    _assert_call_rejects_non_object '"oops"' "string"
}

@test "handle_tools_call: an array arguments value is not dispatched to the tool" {
    _assert_call_rejects_non_object '[1,2]' "array"
}

@test "handle_tools_call: a call with no arguments key is dispatched when the schema requires nothing" {
    # The counterpart to the cases above: only a genuinely absent key defaults
    # to {}, and that default must stay a valid object for every tool whose
    # schema has no required field.
    local params
    params=$(jq -n -c '{name: "loose"}')
    run handle_tools_call 1 "$params"
    assert_success
    assert_output --partial "DISPATCHED:{}"
    assert_output --partial '"isError":false'
}
