#!/bin/bash
# Tests for hidpi-override.sh. Uses ioreg fixtures; never touches /Library or sudo.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$here/hidpi-override.sh"

work=$(mktemp -d -t hidpi-test)
trap 'rm -rf "$work"' EXIT

# A sudo stub proves that --dry-run and the failing paths never reach sudo.
mkdir "$work/bin"
cat >"$work/bin/sudo" <<EOF
#!/bin/bash
echo "sudo called: \$*" >>"$work/sudo.log"
exit 99
EOF
chmod +x "$work/bin/sudo"
export PATH="$work/bin:$PATH"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# expect_eq <name> <expected> <actual>
expect_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi
}

# expect_has <name> <text> <fixed substring>
expect_has() {
  if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1"; printf '  missing: %s\n' "$3"; fi
}

# expect_fail <name> <command...>: succeeds when the command exits non-zero.
expect_fail() {
  local name=$1
  shift
  if "$@" >"$work/out" 2>"$work/err"; then
    bad "$name (exit 0, expected failure)"
  else
    ok "$name"
  fi
}

# A DisplayAttributes line as ioreg prints it, with the given identity.
display_line() { # vendor-decimal product-decimal name
  printf '    | |   |   |   "DisplayAttributes" = {"SupportsSuspend"=No,"PortID"=64,"ProductAttributes"={"YearOfManufacture"=2022,"ManufacturerID"="HWV","SerialNumber"=1,"ProductName"="%s","LegacyManufacturerID"=%s,"ProductID"=%s,"WeekOfManufacture"=8},"MaxVerticalImageSize"=33,"NativeFormatHorizontalPixels"=1920,"NativeFormatVerticalPixels"=1080}\n' "$3" "$1" "$2"
}

noise() {
  printf '+-o Root  <class IORegistryEntry>\n'
  printf '    | |   |   |   "DisplayAttributes" = {"SupportsSuspend"=No,"PortID"=1}\n'
  printf '    | |   |   |   "OtherThing" = {"ProductAttributes"={"ProductID"=1}}\n'
}

# Fixtures
{ noise; display_line 8950 27173 ZQE-CAA; } >"$work/one.txt"
{ noise; display_line 1552 40000 "Built-in Retina Display"; display_line 8950 27173 ZQE-CAA; } >"$work/apple.txt"
{ display_line 8950 27173 ZQE-CAA; display_line 20972 38483 "Other Mon"; } >"$work/two.txt"
{ display_line 8950 27173 ZQE-CAA; display_line 8950 27173 ZQE-CAA; } >"$work/dup.txt"
noise >"$work/none.txt"

run() { # fixture args...
  local fixture=$1
  shift
  HIDPI_IOREG_FIXTURE="$fixture" "$script" "$@"
}

# (a) list
expect_eq "list: one display" "1  22f6:6a25  ZQE-CAA" "$(run "$work/one.txt" list)"
expect_eq "list: Apple 0x610 skipped" "1  22f6:6a25  ZQE-CAA" "$(run "$work/apple.txt" list)"
expect_eq "list: two displays" "$(printf '1  22f6:6a25  ZQE-CAA\n2  51ec:9653  Other Mon')" "$(run "$work/two.txt" list)"
expect_eq "list: duplicate lines collapse" "1  22f6:6a25  ZQE-CAA" "$(run "$work/dup.txt" list)"
expect_fail "list: no display fails" run "$work/none.txt" list

# (b) install --dry-run, single resolution
out=$(run "$work/one.txt" install --dry-run --res 3440x1440)
expect_eq "dry-run: two data entries" "2" "$(grep -c 'bytes = 0x' <<<"$out" || true)"
expect_has "dry-run: 8-byte entry" "$out" 'length = 8, bytes = 0x00001ae000000b40}'
expect_has "dry-run: 16-byte entry" "$out" 'length = 16, bytes = 0x00001ae000000b400000000900200000}'
expect_has "dry-run: vendor id" "$out" '"DisplayVendorID" => 8950'
expect_has "dry-run: product id" "$out" '"DisplayProductID" => 27173'
expect_has "dry-run: target path" "$out" 'Target:  /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-22f6/DisplayProductID-6a25'

default_out=$(run "$work/one.txt" install --dry-run)
expect_eq "dry-run: default resolutions give 20 entries" "20" "$(grep -c 'bytes = 0x' <<<"$default_out" || true)"
two_out=$(run "$work/one.txt" install --dry-run --res "3440x1440 2752x1152")
expect_eq "dry-run: two resolutions give 4 entries" "4" "$(grep -c 'bytes = 0x' <<<"$two_out" || true)"
expect_eq "dry-run: --display 1 accepted" "0" "$(run "$work/one.txt" install --dry-run --display 1 --res 3440x1440 >/dev/null 2>&1; echo $?)"
second_out=$(run "$work/two.txt" install --dry-run --display 2 --res 3440x1440)
expect_has "dry-run: --display 2 picks the second display" "$second_out" 'DisplayVendorID-51ec/DisplayProductID-9653'

# (c) bad --res values
expect_fail "res: 3440*1440 rejected" run "$work/one.txt" install --dry-run --res '3440*1440'
expect_fail "res: 0x100 rejected" run "$work/one.txt" install --dry-run --res '0x100'
expect_fail "res: abc rejected" run "$work/one.txt" install --dry-run --res 'abc'
expect_fail "res: 100x0 rejected" run "$work/one.txt" install --dry-run --res '100x0'
expect_fail "res: one bad among good rejected" run "$work/one.txt" install --dry-run --res '3440x1440 abc'
expect_fail "res: empty rejected" run "$work/one.txt" install --dry-run --res ''

# (d) display selection
expect_fail "two displays without --display fail" run "$work/two.txt" install --dry-run
expect_fail "--display out of range fails" run "$work/one.txt" install --dry-run --display 2
expect_fail "--display 0 fails" run "$work/one.txt" install --dry-run --display 0
expect_fail "--display abc fails" run "$work/one.txt" install --dry-run --display abc
expect_fail "uninstall: two displays without --display fail" run "$work/two.txt" uninstall

# usage
for args in "-h" "--help"; do
  rc=0
  "$script" "$args" >/dev/null 2>&1 || rc=$?
  expect_eq "help exits 0 for '${args}'" "0" "$rc"
done
for args in "bogus" ""; do
  rc=0
  # shellcheck disable=SC2086  # intentional: empty args means no command
  "$script" $args >/dev/null 2>&1 || rc=$?
  expect_eq "usage exit 2 for '${args}'" "2" "$rc"
done
rc=0
"$script" install --bogus >/dev/null 2>&1 || rc=$?
expect_eq "unknown option exits 2" "2" "$rc"

# Nothing above may have reached sudo.
if [[ -e "$work/sudo.log" ]]; then
  bad "sudo was called"
  cat "$work/sudo.log"
else
  ok "sudo never called"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
