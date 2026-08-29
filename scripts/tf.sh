#!/usr/bin/env bash
# Read terraform outputs safely.
#
#   tf.sh              all outputs, as KEY=VALUE lines for `eval`
#   tf.sh <name>       one output's value, or nothing
#
# `terraform output -raw NAME` cannot be used: with no state, or with an empty
# output, it prints a human-readable warning to STDOUT and still exits 0. That
# pollutes every shell variable derived from it -- which silently broke the
# spot-flip guard by making it believe a provisioning model was already set.
# The -json form is either valid JSON or nothing, so parse that instead.
set -uo pipefail

state="terraform/terraform.tfstate"
[ -s "$state" ] || exit 0

terraform -chdir=terraform output -json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

key = sys.argv[1] if len(sys.argv) > 1 else None
if key:
    v = d.get(key, {}).get("value")
    if v is not None:
        print(v)
else:
    for k, v in d.items():
        val = v.get("value")
        if val is not None and not isinstance(val, (dict, list)):
            print("%s=%s" % (k.upper(), json.dumps(str(val))))
' ${1:+"$1"} 2>/dev/null
