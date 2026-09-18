#!/usr/bin/env bash
# Cross-entry invariants that Bicep cannot express without the experimental `assert` keyword.
# Run in CI before `az deployment sub what-if`. See the guards note in main.bicep.
#
#   scripts/preflight.sh envs/prod.bicepparam
set -euo pipefail

PARAMS="${1:?usage: preflight.sh envs/<env>.bicepparam}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BICEP="${BICEP:-bicep}"
fail=0

note() { printf '  %s\n' "$*"; }

# Resolve the params file the same way a deployment would, so the checks see final values.
json=$("$BICEP" build-params "$ROOT/$PARAMS" --stdout)
fleets=$(printf '%s' "$json" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["parametersJson"]))' \
  | python3 -c 'import sys,json; print(json.dumps(json.loads(json.load(sys.stdin))["parameters"]["fleets"]["value"]))')

echo "1/3 fleet names unique"
dupes=$(printf '%s' "$fleets" | python3 -c '
import sys, json, collections
names = [f["name"] for f in json.load(sys.stdin)]
print(" ".join(n for n, c in collections.Counter(names).items() if c > 1))')
if [[ -n "$dupes" ]]; then
  note "FAIL duplicate fleet names: $dupes"
  fail=1
fi

echo "2/3 every declared bootstrap is registered in main.bicep"
declared=$(printf '%s' "$fleets" | python3 -c '
import sys, json
print(" ".join(f["name"] for f in json.load(sys.stdin) if f.get("userDataFile")))')
for name in $declared; do
  # The registry is a literal map because loadFileAsBase64() needs a compile-time path.
  if ! grep -qE "^  ${name}: loadFileAsBase64\(" "$ROOT/main.bicep"; then
    note "FAIL $name declares userDataFile but has no entry in main.bicep's userDataByFleet"
    note "     add:  ${name}: loadFileAsBase64('userdata/<file>.sh')"
    fail=1
  fi
done

echo "3/3 bootstrap scripts within Azure's 64 KB custom-data limit"
# Enforced at VM create, so exceeding it means the scale set silently never reaches capacity.
while IFS= read -r script; do
  bytes=$(wc -c < "$script" | tr -d ' ')
  if (( bytes > 65536 )); then
    note "FAIL $(basename "$script") is ${bytes} bytes (limit 65536)"
    fail=1
  fi
done < <(find "$ROOT/userdata" -name '*.sh' -type f)

if (( fail )); then
  echo "preflight FAILED"
  exit 1
fi
echo "preflight OK"
