# Source ~/.bashrc for aliases, functions, and environment variables
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

# Auto-launch Claude Code only for interactive login shells (real terminal sessions).
# Guard required because Claude Code itself invokes bash with -l to inherit the login
# environment when running commands — without this check, every such invocation would
# launch a nested claude session instead of executing the intended command.
if [[ $- == *i* ]]; then
    claude
    exit $?
fi
