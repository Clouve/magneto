# shellcheck shell=bash
# lib.sh: what the Odoo image's entrypoint.sh and install.sh share. Both
# source it from /clouve/odoo/installer/lib.sh. It sets no shell options.

# True when NAME is a secret: one of its _-separated words is PASSWORD,
# PASSWORDS, PASSWD, PASS, PWD, SECRET, SECRETS, KEY, KEYS, TOKEN, TOKENS,
# CREDENTIAL, CREDENTIALS, PRIVATE or AUTH, in any case. A copy of
# magneto-agent's rule (image/installer/secrets/secrets-lib.sh), so one rule
# decides what a secret is in the agent and here. Its three exceptions are
# the AI Assistant's own key names, which never reach this container.
# tests/odoo-entrypoint.test.sh keeps the two in step.
_clv_is_secret_name() {
    case "${1^^}" in
        MAGNETO_AGENT_LLM_KEY|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN) return 1 ;;
    esac
    case "_${1^^}_" in
        *_PASSWORD_*|*_PASSWORDS_*|*_PASSWD_*|*_PASS_*|*_PWD_*|*_SECRET_*|*_SECRETS_*|\
        *_KEY_*|*_KEYS_*|*_TOKEN_*|*_TOKENS_*|*_CREDENTIAL_*|*_CREDENTIALS_*|\
        *_PRIVATE_*|*_AUTH_*)
            return 0 ;;
    esac
    return 1
}

# odoo_unset_secrets: unsets every exported variable whose name the rule
# calls a secret, and PGPASSWORD. Odoo doesn't need any of them: it reads
# the database password from odoo.conf. A process of odoo's could read
# them in Odoo's environment, and CLOUVE_OPS_PASSWORD would give it root
# over SSH. PGPASSWORD is one word, so the rule doesn't match it, and
# Odoo 19 takes it over odoo.conf's db_password (it reads PGPASSWORD into
# db_password and ranks the environment above the file). Shell variables
# that aren't exported stay. Prints nothing. One limit: compgen -e lists only
# names that are shell identifiers. bash passes a name such as A-B_PASSWORD on
# to Odoo without listing it, and unset couldn't take it out. Kubernetes
# accepts such names, but no Clouve manifest sets one.
odoo_unset_secrets() {
    local _odoo_name
    while IFS= read -r _odoo_name; do
        if [ "$_odoo_name" = PGPASSWORD ] || _clv_is_secret_name "$_odoo_name"; then
            unset "$_odoo_name"
        fi
    done < <(compgen -e)
}

# odoo_dbfilter NAME: prints the dbfilter that lets a browser reach the
# database NAME and no other: ^NAME\Z, with each dot escaped. Python's $
# would also match before a newline at the end; \Z doesn't. Status 1, and
# nothing printed, for a name Odoo's database manager refuses (DBNAME_PATTERN
# in addons/web/controllers/database.py: a letter or digit, then one or more
# letters, digits, _, . or -).
odoo_dbfilter() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$ ]] || return 1
    printf '^%s\\Z' "${1//./\\.}"
}
