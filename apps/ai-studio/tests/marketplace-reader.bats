#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers/common
setup() { _test_setup; source "$MOD_DIR/marketplace-reader.sh"; }
teardown() { _test_teardown; }

_make_marketplace() {
    # $1 = clone dir, $2 = json content
    mkdir -p "$1/.claude-plugin"
    cat > "$1/.claude-plugin/marketplace.json" <<EOF
$2
EOF
}

@test "reads all plugins when no filter is set" {
    _make_marketplace "$TEST_TMPDIR/clone" '{
        "name": "test",
        "plugins": [
            {"name": "gibbon", "version": "1.0", "description": "Gibbon DevOps", "source": "./plugins/gibbon"},
            {"name": "moodle", "version": "1.0", "description": "Moodle DevOps", "source": "./plugins/moodle"}
        ]
    }'
    run _clv_read_marketplace "$TEST_TMPDIR/clone" ""
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    [[ "$output" == *$'gibbon\t1.0\tGibbon DevOps\t./plugins/gibbon'* ]]
    [[ "$output" == *$'moodle\t1.0\tMoodle DevOps\t./plugins/moodle'* ]]
}

@test "applies plugin filter" {
    _make_marketplace "$TEST_TMPDIR/clone" '{
        "plugins": [
            {"name": "gibbon", "source": "./plugins/gibbon"},
            {"name": "moodle", "source": "./plugins/moodle"},
            {"name": "extra",  "source": "./plugins/extra"}
        ]
    }'
    run _clv_read_marketplace "$TEST_TMPDIR/clone" "gibbon,moodle"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    [[ "$output" == *gibbon* ]]
    [[ "$output" == *moodle* ]]
    [[ "$output" != *extra* ]]
}

@test "preserves marketplace order when no filter is set" {
    _make_marketplace "$TEST_TMPDIR/clone" '{
        "plugins": [
            {"name": "z-last",  "source": "./z"},
            {"name": "a-first", "source": "./a"}
        ]
    }'
    run _clv_read_marketplace "$TEST_TMPDIR/clone" ""
    first_line="$(echo "$output" | head -1)"
    [[ "$first_line" == z-last* ]]
}

@test "preserves filter order (?plugins= ordering wins over marketplace.json order)" {
    _make_marketplace "$TEST_TMPDIR/clone" '{
        "plugins": [
            {"name": "gibbon", "source": "./g"},
            {"name": "moodle", "source": "./m"}
        ]
    }'
    run _clv_read_marketplace "$TEST_TMPDIR/clone" "moodle,gibbon"
    first_line="$(echo "$output" | head -1)"
    [[ "$first_line" == moodle* ]]
}

@test "warns when filter references a name not in the marketplace and skips it" {
    _make_marketplace "$TEST_TMPDIR/clone" '{
        "plugins": [{"name": "gibbon", "source": "./g"}]
    }'
    run --separate-stderr _clv_read_marketplace "$TEST_TMPDIR/clone" "gibbon,nonexistent"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c gibbon)" -eq 1 ]
    [[ "$output" != *nonexistent* ]]
    # Warning is on stderr — captured by `run --separate-stderr` into $stderr.
    [[ "$stderr" == *nonexistent* ]]
}

@test "missing marketplace.json returns non-zero" {
    mkdir -p "$TEST_TMPDIR/clone"
    run _clv_read_marketplace "$TEST_TMPDIR/clone" ""
    [ "$status" -ne 0 ]
}

@test "malformed marketplace.json returns non-zero" {
    _make_marketplace "$TEST_TMPDIR/clone" 'this is not json'
    run _clv_read_marketplace "$TEST_TMPDIR/clone" ""
    [ "$status" -ne 0 ]
}

@test "missing version and description default to empty string" {
    _make_marketplace "$TEST_TMPDIR/clone" '{
        "plugins": [{"name": "minimal", "source": "./m"}]
    }'
    run _clv_read_marketplace "$TEST_TMPDIR/clone" ""
    [ "$status" -eq 0 ]
    [[ "$output" == minimal$'\t\t\t./m' ]]
}
