# Userify Shim Configuration
# @generated This is used to ignore from super-linter, since we can't have spaces around the = signs
# no spaces due to this being loaded in the shell with `source userify_config.py`

company="ChiaNetwork"
project="Default"

# This file sourced by both Python and Bash scripts, so please ensure changes
# are loadable by each.

# Enable this for additional verbosity in /var/log/userify-shim.log
debug=0

# Enable this to not actually make changes.
# This can also be used to temporary disable the shim.
dry_run=0

# Userify Enterprise/Pro licenses
shim_host="configure.userify.com"
static_host="static.userify.com"
self_signed=0
