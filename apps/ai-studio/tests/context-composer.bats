#!/usr/bin/env bats
load helpers/common
setup() {
    _test_setup
    source "$MOD_DIR/context-composer.sh"
    export _CLV_SKILLS_DIR="$TEST_TMPDIR/skills"
    mkdir -p "$_CLV_SKILLS_DIR"
}
teardown() { _test_teardown; }

@test "base only: writes base template content unchanged when .active is empty" {
    echo "Hello \${WHO}" > "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    : > "$_CLV_SKILLS_DIR/.active"
    WHO="world" _clv_compose_context "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/.active" "$TEST_TMPDIR/out.md"
    grep -q "Hello world" "$TEST_TMPDIR/out.md"
}

@test "appends one Skill section under '## Skill: <plugin>' heading" {
    echo "Base" > "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    mkdir -p "$_CLV_SKILLS_DIR/gibbon"
    echo "Gibbon persona" > "$_CLV_SKILLS_DIR/gibbon/CONTEXT.md.tpl"
    echo "gibbon" > "$_CLV_SKILLS_DIR/.active"
    _clv_compose_context "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/.active" "$TEST_TMPDIR/out.md"
    grep -q "^## Skill: gibbon$" "$TEST_TMPDIR/out.md"
    grep -q "Gibbon persona" "$TEST_TMPDIR/out.md"
}

@test "preserves order of multiple plugins from .active" {
    echo "Base" > "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    for p in gibbon moodle; do
        mkdir -p "$_CLV_SKILLS_DIR/$p"
        echo "$p body" > "$_CLV_SKILLS_DIR/$p/CONTEXT.md.tpl"
    done
    printf 'gibbon\nmoodle\n' > "$_CLV_SKILLS_DIR/.active"
    _clv_compose_context "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/.active" "$TEST_TMPDIR/out.md"
    g_line=$(grep -n "Skill: gibbon" "$TEST_TMPDIR/out.md" | cut -d: -f1)
    m_line=$(grep -n "Skill: moodle" "$TEST_TMPDIR/out.md" | cut -d: -f1)
    [ "$g_line" -lt "$m_line" ]
}

@test "missing per-plugin CONTEXT.md.tpl: warns and skips section, base still rendered" {
    echo "Base" > "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    echo "no-context-plugin" > "$_CLV_SKILLS_DIR/.active"
    run _clv_compose_context "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/.active" "$TEST_TMPDIR/out.md"
    [ "$status" -eq 0 ]
    grep -q "Base" "$TEST_TMPDIR/out.md"
    ! grep -q "Skill: no-context-plugin" "$TEST_TMPDIR/out.md"
    [[ "$output" == *"no CONTEXT.md.tpl"* ]]
}

@test "missing base CONTEXT.md.tpl: warns but still writes per-plugin sections" {
    mkdir -p "$_CLV_SKILLS_DIR/gibbon"
    echo "Gibbon body" > "$_CLV_SKILLS_DIR/gibbon/CONTEXT.md.tpl"
    echo "gibbon" > "$_CLV_SKILLS_DIR/.active"
    run _clv_compose_context "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/.active" "$TEST_TMPDIR/out.md"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMPDIR/out.md" ]
    grep -q "Skill: gibbon" "$TEST_TMPDIR/out.md"
    grep -q "Gibbon body" "$TEST_TMPDIR/out.md"
    [[ "$output" == *"base"* ]]
}

@test "envsubst interpolates AI_STUDIO_HOST in per-plugin section" {
    echo "Base" > "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    mkdir -p "$_CLV_SKILLS_DIR/gibbon"
    echo 'Host is ${AI_STUDIO_HOST}' > "$_CLV_SKILLS_DIR/gibbon/CONTEXT.md.tpl"
    echo "gibbon" > "$_CLV_SKILLS_DIR/.active"
    AI_STUDIO_HOST="example.com" _clv_compose_context "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/.active" "$TEST_TMPDIR/out.md"
    grep -q "Host is example.com" "$TEST_TMPDIR/out.md"
}

@test "writes output with mode 600" {
    echo "Base" > "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    : > "$_CLV_SKILLS_DIR/.active"
    _clv_compose_context "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/.active" "$TEST_TMPDIR/out.md"
    perms=$(stat -c '%a' "$TEST_TMPDIR/out.md" 2>/dev/null || stat -f '%Lp' "$TEST_TMPDIR/out.md")
    [ "$perms" = "600" ]
}

@test "no .active file: behaves like empty .active (base only)" {
    echo "Base" > "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    _clv_compose_context "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/.active" "$TEST_TMPDIR/out.md"
    grep -q "Base" "$TEST_TMPDIR/out.md"
}
