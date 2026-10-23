#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(mktemp -d "${TMPDIR:-/tmp}/pip-files-promote-test.XXXXXX")"
trap 'python3 -c '\''import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)'\'' "$root"' EXIT
mkdir -p "$root/output.app" "$root/stage.app"
printf 'old-package' > "$root/output.app/marker"
printf 'new-package' > "$root/stage.app/marker"
swift scripts/promote.swift "$root/stage.app" "$root/output.app"
test "$(cat "$root/output.app/marker")" = 'new-package'
test "$(cat "$root/stage.app/marker")" = 'old-package'

mkdir -p "$root/first.app"
printf 'first-package' > "$root/first.app/marker"
swift scripts/promote.swift "$root/first.app" "$root/first-output.app"
test "$(cat "$root/first-output.app/marker")" = 'first-package'
test ! -e "$root/first.app"

mkdir -p "$root/kept-output.app"
printf 'known-good' > "$root/kept-output.app/marker"
if swift scripts/promote.swift "$root/missing-stage.app" "$root/kept-output.app" 2>"$root/error.log"; then
  echo 'promotion unexpectedly succeeded with a missing stage' >&2
  exit 1
fi
test "$(cat "$root/kept-output.app/marker")" = 'known-good'
grep -q 'staging and previous output are kept' "$root/error.log"
echo 'PASS: existing output swap, first promotion, and failed promotion retention'
