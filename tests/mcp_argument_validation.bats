#!/usr/bin/env bats
# bats file_tags=mcp-core,argument-validation
# Tests for the shared mcpserver_core argument validator:
#   validate_tool_arguments() and its wiring into handle_tools_call().
# Enforces `required` always, `additionalProperties: false` when declared,
# a declared `type` — one name or a list of alternatives — a declared
# `pattern` (string values), `minimum`/`maximum`/`exclusiveMinimum`/
# `exclusiveMaximum` (number values), a declared array `items.type`/
# `items.enum` (each element), `enum` on any property present in the
# call's arguments, and `oneOf`. The same keywords are enforced inside nested
# schemas: a property's own schema, a schema-valued `additionalProperties`,
# `items` and each `oneOf` branch. A schema using any other keyword, annotations
# aside, is refused, and so is one holding an enforced keyword of the wrong
# type; the unknown-keyword refusal wins when both apply. Diagnostic precedence is
# missing > unknown > type > pattern > range > items > enum > oneOf.
# Sources lib/mcpserver_core.sh directly. Consumers vendor that file verbatim, so
# this suite covers the validator wherever it is vendored.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"

setup() {
    mcp_test_env "${BATS_TEST_TMPDIR}/config.json" "${BATS_TEST_TMPDIR}/tools.json"

    # Fixture tool list:
    #   strict — required:[number], additionalProperties:false, repo/mode carry enums
    #   loose  — no required, additionalProperties unset (defaults to allowed)
    #   typed  — type/pattern/items coverage: name (string+pattern), count
    #            (integer), active (boolean), tags (array of string, each
    #            enum-constrained)
    #   union  — list-form `type` coverage: count (integer or string), choice
    #            (single-member list plus an enum, for precedence), values
    #            (array whose items.type is a list)
    #   malformed — wrong-typed `type` lists, refused by the shape check: empty,
    #            and one carrying a non-string member, at a property and in items
    #   ranged — range-keyword coverage: limit (integer, minimum+maximum),
    #            score (number, minimum), above (exclusiveMinimum), below
    #            (exclusiveMaximum), untyped (minimum, no declared type),
    #            plus name/tags/mode to pin range against pattern, items and
    #            enum precedence
    #   badrange — wrong-typed bounds, refused by the shape check: a string
    #            bound, and the draft-04 boolean `exclusiveMinimum` modifier
    #   options — an `options` schema: a schema-valued
    #            additionalProperties whose values must match one of three
    #            oneOf branches
    #   nested — o (object with its own required, enum, integer type and
    #            additionalProperties:false), codes (items carrying a
    #            pattern), name (top-level pattern, for precedence)
    #   extra  — a top-level schema-valued additionalProperties
    #   choice — v (oneOf whose integer and number branches overlap)
    #   annotated — annotation keywords at the root and on a property
    #   short  — a property using minLength, which is not enforced
    #   anyof  — an anyOf nested in a property's oneOf branch
    #   rootone — a oneOf at the root schema: exactly one of a and b is required
    # shellcheck disable=SC2016 # the JSON is a literal: its regex anchors and "$schema" must not expand.
    write_fixture_files '{
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
    },
    {
      "name": "options",
      "inputSchema": {
        "type": "object",
        "properties": {
          "options": {
            "type": "object",
            "additionalProperties": {
              "oneOf": [
                {"type": "boolean"},
                {"type": "string"},
                {"type": "array", "items": {"type": "string"}}
              ]
            }
          }
        }
      }
    },
    {
      "name": "nested",
      "inputSchema": {
        "type": "object",
        "properties": {
          "o": {
            "type": "object",
            "required": ["k"],
            "properties": {
              "k": {"type": "string", "enum": ["x", "y"]},
              "n": {"type": "integer"}
            },
            "additionalProperties": false
          },
          "codes": {"type": "array", "items": {"type": "string", "pattern": "^[A-Z]{3}$"}},
          "name": {"type": "string", "pattern": "^[a-z]+$"}
        }
      }
    },
    {
      "name": "extra",
      "inputSchema": {
        "type": "object",
        "additionalProperties": {"type": "string"}
      }
    },
    {
      "name": "choice",
      "inputSchema": {
        "type": "object",
        "properties": {
          "v": {"oneOf": [{"type": "integer"}, {"type": "number"}]}
        }
      }
    },
    {
      "name": "annotated",
      "inputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "Annotated",
        "description": "A schema carrying annotation keywords.",
        "type": "object",
        "properties": {
          "when": {"type": "string", "format": "date", "description": "A day.", "default": "2020-01-01"}
        }
      }
    },
    {
      "name": "short",
      "inputSchema": {
        "type": "object",
        "properties": {
          "s": {"type": "string", "minLength": 1}
        }
      }
    },
    {
      "name": "anyof",
      "inputSchema": {
        "type": "object",
        "properties": {
          "o": {"oneOf": [{"type": "string"}, {"anyOf": [{"type": "integer"}]}]}
        }
      }
    },
    {
      "name": "rootone",
      "inputSchema": {
        "type": "object",
        "properties": {
          "a": {"type": "string"},
          "b": {"type": "string"}
        },
        "oneOf": [{"required": ["a"]}, {"required": ["b"]}]
      }
    }
  ]
}'

    source "${REPO_ROOT}/lib/mcpserver_core.sh"

    # Dispatchable stubs that echo a marker so dispatch can be observed.
    tool_strict() { printf 'DISPATCHED:%s\n' "$1"; }
    tool_loose() { printf 'DISPATCHED:%s\n' "$1"; }
}

# --- validate_tool_arguments: direct unit behavior ---

@test "validate_tool_arguments: missing required field fails with its name" {
    run validate_tool_arguments "strict" '{"repo": "a/b"}'
    assert_failure 1
    assert_output "Missing required parameter(s): number."
}

@test "validate_tool_arguments: unknown field fails and lists allowed parameters" {
    run validate_tool_arguments "strict" '{"number": "5", "pr": 339}'
    assert_failure 1
    assert_output "Unknown parameter(s): pr. Allowed parameters: mode, number, repo."
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

@test "validate_tool_arguments: a tool the list does not declare is rejected" {
    run validate_tool_arguments "nonexistent" '{"whatever": 1}'
    assert_failure 1
    assert_output "Cannot validate arguments for nonexistent: the tool list at ${MCP_TOOLS_LIST_FILE} does not declare it."
}

@test "validate_tool_arguments: a declared entry with no inputSchema is rejected" {
    write_fixture_files '{"tools": [{"name": "bare", "description": "no schema"}]}'
    run validate_tool_arguments "bare" '{}'
    assert_failure 1
    assert_output "Cannot validate arguments for bare: its entry in ${MCP_TOOLS_LIST_FILE} declares no inputSchema."
}

@test "validate_tool_arguments: value outside the declared enum fails naming property, value, and allowed values" {
    run validate_tool_arguments "strict" '{"number": "5", "repo": "x/y"}'
    assert_failure 1
    assert_output 'Invalid value(s): repo="x/y" (allowed: a/b, c/d).'
}

@test "validate_tool_arguments: two invalid enum values in one call are both named in one message" {
    run validate_tool_arguments "strict" '{"number": "5", "repo": "x/y", "mode": "staging"}'
    assert_failure 1
    assert_output 'Invalid value(s): mode="staging" (allowed: development, production); repo="x/y" (allowed: a/b, c/d).'
}

@test "validate_tool_arguments: a non-string value against a string enum fails on type, not enum" {
    # `mode` declares both type:string and an enum; the type defect is the
    # more fundamental one, so it is the one reported.
    run validate_tool_arguments "strict" '{"number": "5", "mode": 5}'
    assert_failure 1
    assert_output 'Invalid type(s): mode expected string, got number (5).'
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
    assert_failure 1
    assert_output "Missing required parameter(s): number."
}

@test "validate_tool_arguments: precedence — a missing required parameter is reported before an unknown one" {
    run validate_tool_arguments "strict" '{"pr": 339}'
    assert_failure 1
    assert_output "Missing required parameter(s): number."
}

@test "validate_tool_arguments: precedence — an unknown parameter is reported before a type violation" {
    # `number` declares string and gets a number; `pr` is undeclared.
    run validate_tool_arguments "strict" '{"number": 5, "pr": 339}'
    assert_failure 1
    assert_output "Unknown parameter(s): pr. Allowed parameters: mode, number, repo."
}

# --- validate_tool_arguments: type, pattern, and array items ---

@test "validate_tool_arguments: valid typed arguments pass with no output" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 5, "active": true, "tags": ["a", "b"]}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a string where an integer is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": "5"}'
    assert_failure 1
    assert_output 'Invalid type(s): count expected integer, got string ("5").'
}

@test "validate_tool_arguments: a non-integer number where an integer is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 5.5}'
    assert_failure 1
    assert_output "Invalid type(s): count expected integer, got number (non-integer) (5.5)."
}

@test "validate_tool_arguments: a string where a boolean is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "active": "true"}'
    assert_failure 1
    assert_output 'Invalid type(s): active expected boolean, got string ("true").'
}

@test "validate_tool_arguments: a value violating pattern is rejected and names the pattern" {
    run validate_tool_arguments "typed" '{"name": "ABC"}'
    assert_failure 1
    assert_output 'Invalid value(s): name="ABC" does not match pattern ^[a-z]+$.'
}

@test "validate_tool_arguments: an array item of the wrong type is rejected and names the index" {
    run validate_tool_arguments "typed" '{"name": "abc", "tags": ["a", 5]}'
    assert_failure 1
    assert_output 'Invalid array item(s): tags[1] expected string, got number (5).'
}

@test "validate_tool_arguments: an array item outside the declared item enum is rejected and names the index" {
    run validate_tool_arguments "typed" '{"name": "abc", "tags": ["a", "z"]}'
    assert_failure 1
    assert_output 'Invalid array item(s): tags[1]="z" (allowed: a, b, c).'
}

@test "validate_tool_arguments: every array item matching type and enum passes" {
    run validate_tool_arguments "typed" '{"name": "abc", "tags": ["a", "b", "c"]}'
    assert_success
    assert_output ""
}

# Regression: `X // empty as $v | BODY` runs BODY zero times when X is absent,
# so a check binding `type` and `enum` together would skip every element of an
# `items` declaring only one of them. Each schema below declares exactly one.
@test "validate_tool_arguments: an items schema declaring only type (no enum) still catches a type violation" {
    write_fixture_files '{
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
}'
    run validate_tool_arguments "counts" '{"values": [1, "not-a-number"]}'
    assert_failure 1
    assert_output 'Invalid array item(s): values[1] expected integer, got string ("not-a-number").'
}

@test "validate_tool_arguments: an items schema declaring only enum (no type) still catches an enum violation" {
    write_fixture_files '{
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
}'
    run validate_tool_arguments "colors" '{"values": ["red", "purple"]}'
    assert_failure 1
    assert_output 'Invalid array item(s): values[1]="purple" (allowed: red, green, blue).'
}

# Regression: jq `index` on an array value is a subsequence search, so a
# membership test built on it accepts an array made of allowed members.
@test "validate_tool_arguments: an array value made of enum members is rejected by a property enum" {
    write_fixture_files '{
  "tools": [
    {
      "name": "picks",
      "inputSchema": {
        "type": "object",
        "properties": {
          "a": {"enum": ["x", "y"]}
        }
      }
    }
  ]
}'
    run validate_tool_arguments "picks" '{"a": ["x", "y"]}'
    assert_failure 1
    assert_output 'Invalid value(s): a="["x","y"]" (allowed: x, y).'
}

@test "validate_tool_arguments: an array element equal to the item enum's members is rejected" {
    write_fixture_files '{
  "tools": [
    {
      "name": "nested",
      "inputSchema": {
        "type": "object",
        "properties": {
          "values": {"type": "array", "items": {"enum": ["a", "b"]}}
        }
      }
    }
  ]
}'
    run validate_tool_arguments "nested" '{"values": [["a", "b"]]}'
    assert_failure 1
    assert_output 'Invalid array item(s): values[0]=["a","b"] (allowed: a, b).'
}

@test "validate_tool_arguments: an enum with an object member names its allowed values on a rejected value" {
    _write_one_tool '{"type": "object", "properties": {"x": {"enum": [{"x": 1}, "b"]}}}'
    run validate_tool_arguments "one" '{"x": "c"}'
    assert_failure 1
    assert_output 'Invalid value(s): x="c" (allowed: {"x":1}, b).'
}

@test "validate_tool_arguments: an items enum with an array member names its allowed values on a rejected element" {
    _write_one_tool '{"type": "object", "properties": {"x": {"items": {"enum": [[1], "b"]}}}}'
    run validate_tool_arguments "one" '{"x": ["c"]}'
    assert_failure 1
    assert_output 'Invalid array item(s): x[0]="c" (allowed: [1], b).'
}

@test "validate_tool_arguments: type precedence — a type violation is reported before an unrelated pattern violation" {
    # count is wrong-typed; name's pattern also fails. Type is reported first.
    run validate_tool_arguments "typed" '{"name": "ABC", "count": "5"}'
    assert_failure 1
    assert_output 'Invalid type(s): count expected integer, got string ("5").'
}

@test "validate_tool_arguments: type precedence — required is still reported ahead of a type violation" {
    run validate_tool_arguments "typed" '{"count": "5"}'
    assert_failure 1
    assert_output "Missing required parameter(s): name."
}

# --- validate_tool_arguments: a `type` declared as a list of alternatives ---

# JSON Schema allows `"type": ["integer", "string"]` to mean "either", at a
# property and in `items` alike.

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
    assert_failure 1
    assert_output "Invalid type(s): count expected integer or string, got ${expected_actual}."
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
    # The list-form counterpart of the scalar-type precedence case above.
    run validate_tool_arguments "union" '{"choice": 7}'
    assert_failure 1
    assert_output 'Invalid type(s): choice expected string, got number (7).'
}

@test "validate_tool_arguments: array items declaring a union type accept every declared member" {
    run validate_tool_arguments "union" '{"values": [1, "x"]}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an array item outside a union items type is rejected and names the index" {
    run validate_tool_arguments "union" '{"values": [1, true]}'
    assert_failure 1
    assert_output 'Invalid array item(s): values[1] expected integer or string, got boolean (true).'
}

@test "validate_tool_arguments: an empty or non-string type list is refused as wrong-typed, at a property and in items" {
    # The schema is refused whatever the call sends, so one call names all four.
    run validate_tool_arguments "malformed" '{"empty": true}'
    assert_failure 1
    assert_output "Cannot validate arguments for malformed: its inputSchema keyword(s) have the wrong type: properties.empty.type must be a string or a non-empty array of strings; properties.emptyitems.items.type must be a string or a non-empty array of strings; properties.mixed.type must be a string or a non-empty array of strings; properties.mixeditems.items.type must be a string or a non-empty array of strings."
}

# --- validate_tool_arguments: numeric range keywords ---

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
    assert_failure 1
    assert_output "Out-of-range value(s): limit=0 below minimum 1."
}

@test "validate_tool_arguments: a value above maximum is rejected naming property, value, and bound" {
    run validate_tool_arguments "ranged" '{"limit": 999}'
    assert_failure 1
    assert_output "Out-of-range value(s): limit=999 above maximum 50."
}

@test "validate_tool_arguments: exclusiveMinimum rejects a value equal to the bound" {
    run validate_tool_arguments "ranged" '{"above": 0}'
    assert_failure 1
    assert_output "Out-of-range value(s): above=0 not above exclusiveMinimum 0."
}

@test "validate_tool_arguments: exclusiveMinimum accepts a value above the bound" {
    run validate_tool_arguments "ranged" '{"above": 0.5}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: exclusiveMaximum rejects a value equal to the bound" {
    run validate_tool_arguments "ranged" '{"below": 100}'
    assert_failure 1
    assert_output "Out-of-range value(s): below=100 not below exclusiveMaximum 100."
}

@test "validate_tool_arguments: exclusiveMaximum accepts a value below the bound" {
    run validate_tool_arguments "ranged" '{"below": 99}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a non-integer number is checked against the bound like any other number" {
    run validate_tool_arguments "ranged" '{"score": 0.5}'
    assert_failure 1
    assert_output "Out-of-range value(s): score=0.5 below minimum 1."
}

@test "validate_tool_arguments: a string value with maximum declared is left unenforced" {
    # A range keyword must not start rejecting strings where no type is
    # declared. jq orders every string above every number, so `maximum` is the
    # bound a string would fail if the number gate let it through.
    _write_one_tool '{"type": "object", "properties": {"x": {"maximum": 3}}}'
    run validate_tool_arguments "one" '{"x": "ab"}'
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
    assert_failure 1
    assert_output "Out-of-range value(s): untyped=2 below minimum 3."
}

@test "validate_tool_arguments: a string bound and the draft-04 boolean exclusiveMinimum are refused as wrong-typed" {
    # draft-04 spelled the exclusive bound as a modifier on `minimum`. This
    # validator implements only the numeric form, so the boolean is refused
    # rather than read as a bound. The schema is refused whatever the call
    # sends, so one call names both.
    run validate_tool_arguments "badrange" '{"stringbound": 1}'
    assert_failure 1
    assert_output "Cannot validate arguments for badrange: its inputSchema keyword(s) have the wrong type: properties.draft04.exclusiveMinimum must be a number; properties.stringbound.minimum must be a number."
}

@test "validate_tool_arguments: two out-of-range properties in one call are both named in one message" {
    run validate_tool_arguments "ranged" '{"above": 0, "limit": 999}'
    assert_failure 1
    assert_output "Out-of-range value(s): above=0 not above exclusiveMinimum 0; limit=999 above maximum 50."
}

@test "validate_tool_arguments: range precedence — a type violation is reported before a range violation on the same value" {
    # 0.5 fails both: `limit` declares integer, and 0.5 is below minimum 1.
    run validate_tool_arguments "ranged" '{"limit": 0.5}'
    assert_failure 1
    assert_output "Invalid type(s): limit expected integer, got number (non-integer) (0.5)."
}

@test "validate_tool_arguments: range precedence — a pattern violation is reported before an unrelated range violation" {
    run validate_tool_arguments "ranged" '{"name": "ABC", "limit": 0}'
    assert_failure 1
    assert_output 'Invalid value(s): name="ABC" does not match pattern ^[a-z]+$.'
}

@test "validate_tool_arguments: range precedence — a range violation is reported before an unrelated items violation" {
    run validate_tool_arguments "ranged" '{"limit": 0, "tags": [7]}'
    assert_failure 1
    assert_output "Out-of-range value(s): limit=0 below minimum 1."
}

@test "validate_tool_arguments: range precedence — a range violation is reported before an unrelated enum violation" {
    run validate_tool_arguments "ranged" '{"limit": 0, "mode": "z"}'
    assert_failure 1
    assert_output "Out-of-range value(s): limit=0 below minimum 1."
}

@test "validate_tool_arguments: precedence — an items violation is reported before an unrelated enum violation" {
    run validate_tool_arguments "ranged" '{"tags": [7], "mode": "z"}'
    assert_failure 1
    assert_output "Invalid array item(s): tags[0] expected string, got number (7)."
}

@test "validate_tool_arguments: precedence — an enum violation is reported before an unrelated oneOf violation" {
    _write_one_tool '{"type": "object", "properties": {"e": {"enum": ["a"]}, "o": {"oneOf": [{"type": "string"}]}}}'
    run validate_tool_arguments "one" '{"e": "z", "o": 5}'
    assert_failure 1
    assert_output 'Invalid value(s): e="z" (allowed: a).'
}

@test "validate_tool_arguments: a property carrying a bound and absent from the arguments is not reported" {
    run validate_tool_arguments "ranged" '{"name": "abc"}'
    assert_success
    assert_output ""
}

# --- validate_tool_arguments: a declared integer against a large literal ---

# `floor` converts its input to an IEEE-754 double, and at or above 2^52 =
# 4503599627370496 the double spacing reaches 1, so `val == (val | floor)`
# alone reads `4503599627370496.5` as whole. The rejection cases at that size
# pin the test on the number as jq renders it; the acceptance cases pin that
# it rejects nothing that is an integer under JSON Schema.

@test "validate_tool_arguments: a fractional literal at 2^52 where an integer is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 4503599627370496.5}'
    assert_failure 1
    assert_output "Invalid type(s): count expected integer, got number (non-integer) (4503599627370496.5)."
}

@test "validate_tool_arguments: a negative fractional literal at 2^52 where an integer is declared is rejected" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": -4503599627370496.5}'
    assert_failure 1
    assert_output "Invalid type(s): count expected integer, got number (non-integer) (-4503599627370496.5)."
}

@test "validate_tool_arguments: the whole value at 2^52 satisfies a declared integer type" {
    run validate_tool_arguments "typed" '{"name": "abc", "count": 4503599627370496}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an odd whole value above 2^53 satisfies a declared integer type" {
    # 9007199254740993 has no exact double; its rounded double and its literal
    # are both whole, so neither the `floor` test nor the literal test may
    # reject it.
    run validate_tool_arguments "typed" '{"name": "abc", "count": 9007199254740993}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an exponent-rendered fraction where an integer is declared is rejected by the value test" {
    # jq renders 1.5e-7 as "1.5E-7", which takes the exponent fallback and so
    # reaches only the `floor` comparison. This is the case that pins that
    # conjunct: drop it and this value is accepted.
    run validate_tool_arguments "typed" '{"name": "abc", "count": 1.5e-7}'
    assert_failure 1
    assert_output "Invalid type(s): count expected integer, got number (non-integer) (1.5E-7)."
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
    assert_failure 1
    assert_output "Invalid type(s): count expected integer or string, got number (non-integer) (4503599627370496.5)."
}

@test "validate_tool_arguments: a fractional array element at 2^52 against an integer items type is rejected and names the index" {
    write_fixture_files '{
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
}'
    run validate_tool_arguments "counts" '{"values": [1, 4503599627370496.5]}'
    assert_failure 1
    assert_output "Invalid array item(s): values[1] expected integer, got number (non-integer) (4503599627370496.5)."
}

@test "validate_tool_arguments: a fractional array element at 2^52 against a union items type is rejected naming both alternatives" {
    # The scalar `items.type` case above and the property-level union case each
    # reach type_ok down a different route. This one crosses them, so a
    # regression confined to a union-typed `items` cannot hide behind either.
    run validate_tool_arguments "union" '{"values": [1, 4503599627370496.5]}'
    assert_failure 1
    assert_output "Invalid array item(s): values[1] expected integer or string, got number (non-integer) (4503599627370496.5)."
}

@test "validate_tool_arguments: precedence — a fractional literal at 2^52 is reported as a type defect, not a range defect" {
    # `limit` declares integer plus minimum 1 and maximum 50, and the value
    # violates both; only the literal test sees the type defect.
    run validate_tool_arguments "ranged" '{"limit": 4503599627370496.5}'
    assert_failure 1
    assert_output "Invalid type(s): limit expected integer, got number (non-integer) (4503599627370496.5)."
}

@test "validate_tool_arguments: exponent notation does not by itself escape the fractional-literal check" {
    # jq renders 4503599627370496.5e0 back as "4503599627370496.5" — it keeps
    # an exponent only for a value that is an exact multiple of ten or whose
    # magnitude is below about 1e-6 — so writing the fraction with a trailing
    # `e0` does not reach the exponent fallback.
    run validate_tool_arguments "typed" '{"name": "abc", "count": 4503599627370496.5e0}'
    assert_failure 1
    assert_output "Invalid type(s): count expected integer, got number (non-integer) (4503599627370496.5)."
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

# --- validate_tool_arguments: nested schemas and oneOf ---

@test "validate_tool_arguments: an options value matching a oneOf branch passes" {
    run validate_tool_arguments "options" '{"options": {"limit": "5", "verbose": true, "tags": ["a"]}}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a number options value matches no oneOf branch and is rejected" {
    run validate_tool_arguments "options" '{"options": {"limit": 5}}'
    assert_failure 1
    assert_output "Invalid value(s): options.limit=5 matches no oneOf alternative."
}

@test "validate_tool_arguments: an object options value matches no oneOf branch and is rejected" {
    run validate_tool_arguments "options" '{"options": {"limit": {"x": 1}}}'
    assert_failure 1
    assert_output 'Invalid value(s): options.limit={"x":1} matches no oneOf alternative.'
}

@test "validate_tool_arguments: a null options value matches no oneOf branch and is rejected" {
    run validate_tool_arguments "options" '{"options": {"limit": null}}'
    assert_failure 1
    assert_output "Invalid value(s): options.limit=null matches no oneOf alternative."
}

@test "validate_tool_arguments: an options array with non-string items matches no oneOf branch and is rejected" {
    run validate_tool_arguments "options" '{"options": {"a": [1, 2]}}'
    assert_failure 1
    assert_output "Invalid value(s): options.a=[1,2] matches no oneOf alternative."
}

@test "validate_tool_arguments: a value matching two overlapping oneOf branches is rejected" {
    run validate_tool_arguments "choice" '{"v": 5}'
    assert_failure 1
    assert_output "Invalid value(s): v=5 matches 2 oneOf alternatives."
}

@test "validate_tool_arguments: a value matching no oneOf branch is rejected" {
    run validate_tool_arguments "choice" '{"v": "s"}'
    assert_failure 1
    assert_output 'Invalid value(s): v="s" matches no oneOf alternative.'
}

@test "validate_tool_arguments: a value matching exactly one oneOf branch passes" {
    run validate_tool_arguments "choice" '{"v": 1.5}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a nested required property that is absent is rejected with its path" {
    run validate_tool_arguments "nested" '{"o": {}}'
    assert_failure 1
    assert_output "Missing required parameter(s): o.k."
}

@test "validate_tool_arguments: a nested property of the wrong type is rejected with its path" {
    run validate_tool_arguments "nested" '{"o": {"k": "x", "n": "1"}}'
    assert_failure 1
    assert_output 'Invalid type(s): o.n expected integer, got string ("1").'
}

@test "validate_tool_arguments: a nested property outside its enum is rejected with its path" {
    run validate_tool_arguments "nested" '{"o": {"k": "z"}}'
    assert_failure 1
    assert_output 'Invalid value(s): o.k="z" (allowed: x, y).'
}

@test "validate_tool_arguments: an undeclared nested property under additionalProperties false is rejected" {
    run validate_tool_arguments "nested" '{"o": {"k": "x", "q": 1}}'
    assert_failure 1
    assert_output "Unknown parameter(s): o.q. Allowed parameters: o.k, o.n."
}

@test "validate_tool_arguments: valid nested arguments pass" {
    run validate_tool_arguments "nested" '{"o": {"k": "y", "n": 3}, "codes": ["ABC"], "name": "abc"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an array element violating an items pattern is rejected with its index" {
    run validate_tool_arguments "nested" '{"codes": ["ABC", "abc"]}'
    assert_failure 1
    assert_output 'Invalid value(s): codes[1]="abc" does not match pattern ^[A-Z]{3}$.'
}

@test "validate_tool_arguments: a top-level schema-valued additionalProperties checks each undeclared value" {
    run validate_tool_arguments "extra" '{"x": 5}'
    assert_failure 1
    assert_output "Invalid type(s): x expected string, got number (5)."
}

@test "validate_tool_arguments: precedence — a nested type violation is reported before a top-level pattern violation" {
    run validate_tool_arguments "nested" '{"name": "ABC", "o": {"k": "x", "n": "1"}}'
    assert_failure 1
    assert_output 'Invalid type(s): o.n expected integer, got string ("1").'
}

# --- validate_tool_arguments: keywords the validator does not enforce ---

# A keyword the validator does not read would otherwise be waved through, so a
# schema using one is refused.

@test "validate_tool_arguments: a schema using minLength is refused naming the keyword's path" {
    run validate_tool_arguments "short" '{"s": "abc"}'
    assert_failure 1
    assert_output "Cannot validate arguments for short: its inputSchema uses keyword(s) this validator does not enforce: properties.s.minLength."
}

@test "validate_tool_arguments: an unenforced keyword inside a schema-valued additionalProperties is refused naming its path" {
    _write_one_tool '{"type": "object", "additionalProperties": {"minLength": 1}}'
    run validate_tool_arguments "one" '{"x": "abc"}'
    assert_failure 1
    assert_output "Cannot validate arguments for one: its inputSchema uses keyword(s) this validator does not enforce: additionalProperties.minLength."
}

@test "validate_tool_arguments: an anyOf nested in a property's oneOf branch is refused naming its path" {
    run validate_tool_arguments "anyof" '{"o": "a"}'
    assert_failure 1
    assert_output "Cannot validate arguments for anyof: its inputSchema uses keyword(s) this validator does not enforce: properties.o.oneOf[1].anyOf."
}

@test "validate_tool_arguments: a oneOf at the root passes when exactly one branch matches" {
    run validate_tool_arguments "rootone" '{"a": "x"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a oneOf at the root matching no branch names the root as arguments" {
    run validate_tool_arguments "rootone" '{}'
    assert_failure 1
    assert_output "Invalid value(s): arguments={} matches no oneOf alternative."
}

@test "validate_tool_arguments: a oneOf at the root matching two branches names the root as arguments" {
    run validate_tool_arguments "rootone" '{"a": "x", "b": "y"}'
    assert_failure 1
    assert_output 'Invalid value(s): arguments={"a":"x","b":"y"} matches 2 oneOf alternatives.'
}

@test "validate_tool_arguments: annotation keywords do not stop a valid call" {
    run validate_tool_arguments "annotated" '{"when": "2021-02-03"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: annotation keywords do not stop the type check" {
    run validate_tool_arguments "annotated" '{"when": 5}'
    assert_failure 1
    assert_output "Invalid type(s): when expected string, got number (5)."
}

# --- handle_tools_call: schema keywords with the wrong type ---

# A keyword of the wrong type cannot be enforced as declared, so the call is
# refused naming each such keyword's path, and the tool does not run.

# Replace the tools list with one tool `shape` declaring <schema-json>, call it
# through handle_tools_call with <arguments-json> (default `{}`), and assert an
# isError result whose text names exactly <defects> and that the tool did not run.
_assert_shape_refused() {
    local schema_json="$1" defects="$2" arguments_json="{}"
    if [[ $# -ge 3 ]]; then
        arguments_json="$3"
    fi
    local marker="${BATS_TEST_TMPDIR}/shape.ran"
    write_fixture_files "$(jq -nc --argjson s "${schema_json}" '{tools: [{name: "shape", inputSchema: $s}]}')"
    tool_shape() { : > "${marker}"; }
    local params
    params=$(jq -nc --argjson a "${arguments_json}" '{name: "shape", arguments: $a}')

    run handle_tools_call 1 "${params}"

    assert_success
    run jq -r '.result.isError, .result.content[0].text' <<< "${output}"
    assert_output "true
Cannot validate arguments for shape: its inputSchema keyword(s) have the wrong type: ${defects}."
    assert [ ! -e "${marker}" ]
}

# Property `x` declares <keyword> with <value-json>.
_assert_property_keyword_refused() {
    local keyword="$1" value_json="$2" shape="$3"
    _assert_shape_refused \
        "$(jq -nc --arg k "${keyword}" --argjson v "${value_json}" '{type: "object", properties: {x: {($k): $v}}}')" \
        "properties.x.${keyword} must be ${shape}"
}

# The items schema of array property `x` declares <keyword> with <value-json>.
_assert_items_keyword_refused() {
    local keyword="$1" value_json="$2" shape="$3"
    _assert_shape_refused \
        "$(jq -nc --arg k "${keyword}" --argjson v "${value_json}" '{type: "object", properties: {x: {type: "array", items: {($k): $v}}}}')" \
        "properties.x.items.${keyword} must be ${shape}"
}

# The second oneOf branch of property `x` declares <keyword> with <value-json>.
_assert_one_of_keyword_refused() {
    local keyword="$1" value_json="$2" shape="$3"
    _assert_shape_refused \
        "$(jq -nc --arg k "${keyword}" --argjson v "${value_json}" '{type: "object", properties: {x: {oneOf: [{type: "string"}, {($k): $v}]}}}')" \
        "properties.x.oneOf[1].${keyword} must be ${shape}"
}

TYPE_SHAPE="a string or a non-empty array of strings"

@test "handle_tools_call: a false type is refused naming its path" {
    _assert_property_keyword_refused type 'false' "${TYPE_SHAPE}"
}

@test "handle_tools_call: a null type is refused naming its path" {
    _assert_property_keyword_refused type 'null' "${TYPE_SHAPE}"
}

@test "handle_tools_call: a numeric type is refused naming its path" {
    _assert_property_keyword_refused type '5' "${TYPE_SHAPE}"
}

@test "handle_tools_call: a type list holding a number is refused naming its path" {
    _assert_property_keyword_refused type '[5]' "${TYPE_SHAPE}"
}

@test "handle_tools_call: a wrong-typed type inside items is refused naming its path" {
    _assert_items_keyword_refused type 'false' "${TYPE_SHAPE}"
}

@test "handle_tools_call: a false minimum is refused naming its path" {
    _assert_property_keyword_refused minimum 'false' "a number"
}

@test "handle_tools_call: a null minimum is refused naming its path" {
    _assert_property_keyword_refused minimum 'null' "a number"
}

@test "handle_tools_call: a string minimum is refused naming its path" {
    _assert_property_keyword_refused minimum '"1"' "a number"
}

@test "handle_tools_call: a wrong-typed minimum inside items is refused naming its path" {
    _assert_items_keyword_refused minimum '"1"' "a number"
}

@test "handle_tools_call: a false maximum is refused naming its path" {
    _assert_property_keyword_refused maximum 'false' "a number"
}

@test "handle_tools_call: a null maximum is refused naming its path" {
    _assert_property_keyword_refused maximum 'null' "a number"
}

@test "handle_tools_call: a string maximum is refused naming its path" {
    _assert_property_keyword_refused maximum '"1"' "a number"
}

@test "handle_tools_call: a wrong-typed maximum inside a oneOf branch is refused naming its path" {
    _assert_one_of_keyword_refused maximum 'null' "a number"
}

@test "handle_tools_call: a false exclusiveMinimum is refused naming its path" {
    _assert_property_keyword_refused exclusiveMinimum 'false' "a number"
}

@test "handle_tools_call: a null exclusiveMinimum is refused naming its path" {
    _assert_property_keyword_refused exclusiveMinimum 'null' "a number"
}

@test "handle_tools_call: a string exclusiveMinimum is refused naming its path" {
    _assert_property_keyword_refused exclusiveMinimum '"1"' "a number"
}

@test "handle_tools_call: the draft-04 exclusiveMinimum true is refused naming its path" {
    _assert_property_keyword_refused exclusiveMinimum 'true' "a number"
}

@test "handle_tools_call: a wrong-typed exclusiveMinimum inside items is refused naming its path" {
    _assert_items_keyword_refused exclusiveMinimum 'true' "a number"
}

@test "handle_tools_call: a false exclusiveMaximum is refused naming its path" {
    _assert_property_keyword_refused exclusiveMaximum 'false' "a number"
}

@test "handle_tools_call: a null exclusiveMaximum is refused naming its path" {
    _assert_property_keyword_refused exclusiveMaximum 'null' "a number"
}

@test "handle_tools_call: a string exclusiveMaximum is refused naming its path" {
    _assert_property_keyword_refused exclusiveMaximum '"1"' "a number"
}

@test "handle_tools_call: a wrong-typed exclusiveMaximum inside a oneOf branch is refused naming its path" {
    _assert_one_of_keyword_refused exclusiveMaximum 'true' "a number"
}

PATTERN_SHAPE="a string holding a valid regular expression"

@test "handle_tools_call: a false pattern is refused naming its path" {
    _assert_property_keyword_refused pattern 'false' "${PATTERN_SHAPE}"
}

@test "handle_tools_call: a null pattern is refused naming its path" {
    _assert_property_keyword_refused pattern 'null' "${PATTERN_SHAPE}"
}

@test "handle_tools_call: a numeric pattern is refused naming its path" {
    _assert_property_keyword_refused pattern '5' "${PATTERN_SHAPE}"
}

@test "handle_tools_call: a pattern that does not compile is refused naming its path" {
    _assert_property_keyword_refused pattern '"("' "${PATTERN_SHAPE}"
}

@test "handle_tools_call: a wrong-typed pattern inside items is refused naming its path" {
    _assert_items_keyword_refused pattern '"("' "${PATTERN_SHAPE}"
}

@test "handle_tools_call: a false required is refused naming its path" {
    _assert_property_keyword_refused required 'false' "an array of strings"
}

@test "handle_tools_call: a null required is refused naming its path" {
    _assert_property_keyword_refused required 'null' "an array of strings"
}

@test "handle_tools_call: a string required is refused naming its path" {
    _assert_property_keyword_refused required '"x"' "an array of strings"
}

@test "handle_tools_call: a required list holding a number is refused naming its path" {
    _assert_property_keyword_refused required '[5]' "an array of strings"
}

@test "handle_tools_call: a wrong-typed required inside a oneOf branch is refused naming its path" {
    _assert_one_of_keyword_refused required 'false' "an array of strings"
}

@test "handle_tools_call: a false enum is refused naming its path" {
    _assert_property_keyword_refused enum 'false' "an array"
}

@test "handle_tools_call: a null enum is refused naming its path" {
    _assert_property_keyword_refused enum 'null' "an array"
}

@test "handle_tools_call: a numeric enum is refused naming its path" {
    _assert_property_keyword_refused enum '5' "an array"
}

@test "handle_tools_call: a wrong-typed enum inside items is refused naming its path" {
    _assert_items_keyword_refused enum 'null' "an array"
}

@test "handle_tools_call: a false properties is refused naming its path" {
    _assert_property_keyword_refused properties 'false' "an object"
}

@test "handle_tools_call: a null properties is refused naming its path" {
    _assert_property_keyword_refused properties 'null' "an object"
}

@test "handle_tools_call: a numeric properties is refused naming its path" {
    _assert_property_keyword_refused properties '5' "an object"
}

@test "handle_tools_call: a property schema that is not an object is refused naming its path" {
    _assert_shape_refused '{"type": "object", "properties": {"x": 5}}' "properties.x must be an object"
}

@test "handle_tools_call: a wrong-typed properties inside a oneOf branch is refused naming its path" {
    _assert_one_of_keyword_refused properties 'false' "an object"
}

@test "handle_tools_call: a false items is refused naming its path" {
    _assert_property_keyword_refused items 'false' "an object"
}

@test "handle_tools_call: a null items is refused naming its path" {
    _assert_property_keyword_refused items 'null' "an object"
}

@test "handle_tools_call: a numeric items is refused naming its path" {
    _assert_property_keyword_refused items '5' "an object"
}

@test "handle_tools_call: a tuple-form items array is refused naming its path" {
    _assert_property_keyword_refused items '[{"type": "string"}]' "an object"
}

@test "handle_tools_call: a wrong-typed items inside items is refused naming its path" {
    _assert_items_keyword_refused items 'false' "an object"
}

AP_SHAPE="a boolean or an object"

@test "handle_tools_call: a null additionalProperties is refused naming its path" {
    _assert_property_keyword_refused additionalProperties 'null' "${AP_SHAPE}"
}

@test "handle_tools_call: a numeric additionalProperties is refused naming its path" {
    _assert_property_keyword_refused additionalProperties '5' "${AP_SHAPE}"
}

@test "handle_tools_call: a string additionalProperties is refused naming its path" {
    _assert_property_keyword_refused additionalProperties '"x"' "${AP_SHAPE}"
}

@test "handle_tools_call: a wrong-typed additionalProperties inside a oneOf branch is refused naming its path" {
    _assert_one_of_keyword_refused additionalProperties 'null' "${AP_SHAPE}"
}

@test "handle_tools_call: a wrong-typed keyword inside a schema-valued additionalProperties is refused naming its path" {
    _assert_shape_refused '{"type": "object", "additionalProperties": {"minimum": "1"}}' "additionalProperties.minimum must be a number"
}

@test "handle_tools_call: a false oneOf is refused naming its path" {
    _assert_property_keyword_refused oneOf 'false' "an array of objects"
}

@test "handle_tools_call: a null oneOf is refused naming its path" {
    _assert_property_keyword_refused oneOf 'null' "an array of objects"
}

@test "handle_tools_call: a numeric oneOf is refused naming its path" {
    _assert_property_keyword_refused oneOf '5' "an array of objects"
}

@test "handle_tools_call: a oneOf holding a number is refused naming its path" {
    _assert_property_keyword_refused oneOf '[5]' "an array of objects"
}

@test "handle_tools_call: a wrong-typed oneOf inside items is refused naming its path" {
    _assert_items_keyword_refused oneOf 'null' "an array of objects"
}

@test "handle_tools_call: a wrong-typed keyword at the root is refused naming its bare path" {
    _assert_shape_refused '{"type": "object", "required": false}' "required must be an array of strings"
}

@test "handle_tools_call: a numeric inputSchema is refused as inputSchema" {
    _assert_shape_refused '5' "inputSchema must be an object"
}

@test "handle_tools_call: a false inputSchema is refused as inputSchema" {
    _assert_shape_refused 'false' "inputSchema must be an object"
}

@test "handle_tools_call: an array inputSchema is refused as inputSchema" {
    _assert_shape_refused '[]' "inputSchema must be an object"
}

@test "handle_tools_call: every wrong-typed keyword is named, in tree order" {
    _assert_shape_refused \
        '{"type": "object", "required": false, "properties": {"b": {"enum": null}, "a": {"minimum": "1"}}}' \
        "properties.a.minimum must be a number; properties.b.enum must be an array; required must be an array of strings"
}

@test "handle_tools_call: a wrong-typed keyword is refused before the arguments are checked" {
    # `null` arguments would otherwise answer the non-object rejection.
    _assert_shape_refused '{"type": "object", "required": false}' "required must be an array of strings" 'null'
}

# An unknown keyword and a wrong-typed one in the same schema answer the
# unenforced-keyword message: that check runs first, and its message names
# every keyword the schema would need the validator to enforce.
@test "handle_tools_call: an unknown keyword beside a wrong-typed one answers the unenforced-keyword message" {
    local marker="${BATS_TEST_TMPDIR}/shape.ran"
    write_fixture_files '{"tools": [{"name": "shape", "inputSchema": {"type": "object", "properties": {"x": {"minLength": 1, "required": false}}}}]}'
    tool_shape() { : > "${marker}"; }

    run handle_tools_call 1 '{"name": "shape", "arguments": {}}'

    assert_success
    run jq -r '.result.isError, .result.content[0].text' <<< "${output}"
    assert_output "true
Cannot validate arguments for shape: its inputSchema uses keyword(s) this validator does not enforce: properties.x.minLength."
    assert [ ! -e "${marker}" ]
}

# The unenforced-keyword walk does not descend into a wrong-typed position, so
# an unknown keyword inside a tuple-form `items` array answers the shape message.
@test "handle_tools_call: an unknown keyword inside a wrong-typed items answers the shape message" {
    _assert_property_keyword_refused items '[{"minLength": 1}]' "an object"
}

# --- validate_tool_arguments: well-typed keywords keep their behavior ---

# Guards of behavior the shape check keeps: each keyword below has a value of
# the accepted shape that a value test could mistake for a wrong or absent one.

# Replace the tools list with one tool `one` declaring <schema-json>.
_write_one_tool() {
    write_fixture_files "$(jq -nc --argjson s "$1" '{tools: [{name: "one", inputSchema: $s}]}')"
}

@test "validate_tool_arguments: a type list naming null accepts null (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"type": ["string", "null"]}}}'
    run validate_tool_arguments "one" '{"x": null}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a minimum of 0 is enforced (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"minimum": 0}}}'
    run validate_tool_arguments "one" '{"x": -1}'
    assert_failure 1
    assert_output "Out-of-range value(s): x=-1 below minimum 0."
}

@test "validate_tool_arguments: a maximum of 0 is enforced (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"maximum": 0}}}'
    run validate_tool_arguments "one" '{"x": 1}'
    assert_failure 1
    assert_output "Out-of-range value(s): x=1 above maximum 0."
}

@test "validate_tool_arguments: an exclusiveMinimum of 0 is enforced (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"exclusiveMinimum": 0}}}'
    run validate_tool_arguments "one" '{"x": 0}'
    assert_failure 1
    assert_output "Out-of-range value(s): x=0 not above exclusiveMinimum 0."
}

@test "validate_tool_arguments: an exclusiveMaximum of 0 is enforced (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"exclusiveMaximum": 0}}}'
    run validate_tool_arguments "one" '{"x": 0}'
    assert_failure 1
    assert_output "Out-of-range value(s): x=0 not below exclusiveMaximum 0."
}

@test "validate_tool_arguments: an empty pattern accepts any string (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"pattern": ""}}}'
    run validate_tool_arguments "one" '{"x": "anything"}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an empty required list requires nothing (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "required": []}'
    run validate_tool_arguments "one" '{}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an enum holding false is enforced (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"enum": [false]}}}'
    run validate_tool_arguments "one" '{"x": true}'
    assert_failure 1
    assert_output 'Invalid value(s): x="true" (allowed: false).'
}

@test "validate_tool_arguments: an items enum holding false is enforced (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"items": {"enum": [false]}}}}'
    run validate_tool_arguments "one" '{"x": [false, true]}'
    assert_failure 1
    assert_output "Invalid array item(s): x[1]=true (allowed: false)."
}

@test "validate_tool_arguments: an empty properties object allows any property (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {}}'
    run validate_tool_arguments "one" '{"y": 1}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: an empty items schema accepts any element (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"items": {}}}}'
    run validate_tool_arguments "one" '{"x": [1, "a", null]}'
    assert_success
    assert_output ""
}

@test "validate_tool_arguments: a oneOf of one empty branch accepts any value (guard: unchanged behavior)" {
    _write_one_tool '{"type": "object", "properties": {"x": {"oneOf": [{}]}}}'
    run validate_tool_arguments "one" '{"x": 1}'
    assert_success
    assert_output ""
}

# --- validate_tool_arguments: arguments that are not a JSON object ---

# The validator rejects a non-object before it checks any argument, because
# `required`, `additionalProperties` and `properties` apply only to an object.
_assert_rejects_non_object() {
    local arguments="$1" expected_type="$2"
    run validate_tool_arguments "strict" "${arguments}"
    assert_failure 1
    assert_output "Invalid arguments: expected a JSON object, got ${expected_type}."
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
    assert_failure 1
    assert_output "Missing required parameter(s): number."
}

# --- validate_tool_arguments: a jq failure is a rejection, not a skip ---

@test "validate_tool_arguments: arguments that are not JSON at all are rejected" {
    run validate_tool_arguments "strict" '{not valid json'
    assert_failure 1
    assert_output "Cannot validate arguments for strict: they could not be evaluated against its schema."
}

@test "validate_tool_arguments: a missing tool list file is rejected rather than skipping validation" {
    # A validator that could not read its schemas has not validated anything.
    rm -f -- "${MCP_TOOLS_LIST_FILE}"
    run validate_tool_arguments "strict" '{"number": "5"}'
    assert_failure 1
    assert_output "Cannot validate arguments for strict: the tool list at ${MCP_TOOLS_LIST_FILE} is missing or does not hold one JSON object."
}

@test "validate_tool_arguments: a tool list file holding unparseable JSON is rejected rather than skipping validation" {
    # A list that cannot be parsed yields no schemas, so nothing was validated.
    printf '%s' '{"tools": [ broken' > "${MCP_TOOLS_LIST_FILE}"
    run validate_tool_arguments "strict" '{"number": "5"}'
    assert_failure 1
    assert_output "Cannot validate arguments for strict: the tool list at ${MCP_TOOLS_LIST_FILE} is missing or does not hold one JSON object."
}

@test "validate_tool_arguments: a tool list file whose only document is not an object is rejected rather than skipping validation" {
    # `42` parses as JSON but is not the object the tools list must be.
    printf '%s' '42' > "${MCP_TOOLS_LIST_FILE}"
    run validate_tool_arguments "strict" '{"number": "5"}'
    assert_failure 1
    assert_output "Cannot validate arguments for strict: the tool list at ${MCP_TOOLS_LIST_FILE} is missing or does not hold one JSON object."
}

@test "validate_tool_arguments: a tools list whose tools hold a non-object element is rejected" {
    # `{"tools": [1]}` passes read_json_file's object gate; `select` then
    # errors indexing the numeric element, so this rejection is the jq-failure
    # branch's own message.
    printf '%s' '{"tools": [1]}' > "${MCP_TOOLS_LIST_FILE}"
    run validate_tool_arguments "strict" '{"number": "5"}'
    assert_failure 1
    assert_output "Cannot validate arguments for strict: the tool list at ${MCP_TOOLS_LIST_FILE} does not hold a usable tools list."
}

# --- handle_tools_call: wiring (validation runs before dispatch) ---

@test "handle_tools_call: invalid arguments return an isError result, not a dispatch" {
    local params
    params=$(jq -n -c '{name: "strict", arguments: {repo: "a/b"}}')
    run handle_tools_call 1 "$params"
    assert_success
    mcp_assert_tool_result "${output}" 1 true "Missing required parameter(s): number."
}

@test "handle_tools_call: a schema using an unenforced keyword returns an isError result, not a dispatch" {
    tool_short() { touch "${BATS_TEST_TMPDIR}/tool_short_ran"; }
    local params
    params=$(jq -n -c '{name: "short", arguments: {s: "abc"}}')
    run handle_tools_call 1 "$params"
    assert_success
    mcp_assert_tool_result "${output}" 1 true \
        "Cannot validate arguments for short: its inputSchema uses keyword(s) this validator does not enforce: properties.s.minLength."
    assert [ ! -e "${BATS_TEST_TMPDIR}/tool_short_ran" ]
}

@test "handle_tools_call: valid arguments are dispatched to the tool" {
    local params
    params=$(jq -n -c '{name: "strict", arguments: {number: "5"}}')
    run handle_tools_call 1 "$params"
    assert_success
    mcp_assert_tool_result "${output}" 1 false 'DISPATCHED:{"number":"5"}'
}

# handle_tools_call derives `arguments` from the params before validating. jq's
# `//` treats a present `null` and `false` as absent, so a derivation built on it
# would coerce both into a valid empty object. One case per JSON type, because
# the derivation discriminates by type and nothing else. process_request only
# requires the request to be parseable JSON, so a client can send every value
# below.
_assert_call_rejects_non_object() {
    local arguments_json="$1" expected_type="$2"
    local params
    params=$(jq -n -c --argjson a "${arguments_json}" '{name: "strict", arguments: $a}')
    run handle_tools_call 1 "$params"
    assert_success
    mcp_assert_tool_result "${output}" 1 true "Invalid arguments: expected a JSON object, got ${expected_type}."
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
    mcp_assert_tool_result "${output}" 1 false "DISPATCHED:{}"
}
