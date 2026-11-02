#!/bin/bash
# Install a macOS display override plist that enables extra HiDPI scaled
# resolutions for one external display. See README.md.
set -euo pipefail

OVERRIDES_DIR="/Library/Displays/Contents/Resources/Overrides"
DEFAULT_RES="3440x1440 3096x1296 3062x1282 2752x1152 2580x1080 2560x1072 2520x1055 2480x1038 2440x1021 2400x1005 2365x990"
APPLE_VENDOR=1552 # 0x610, Apple internal displays

usage() {
  cat <<'EOF'
Usage:
  hidpi-override.sh list
  hidpi-override.sh install [--display N] [--res "WxH WxH ..."] [--dry-run] [--force]
  hidpi-override.sh uninstall [--display N]

list       Print external displays as: index  vid:pid (hex)  name
install    Write the override plist for one display (needs sudo unless --dry-run).
             --display N   display index from "list" (optional with one display)
             --res "..."   looks-like resolutions, default:
                           3440x1440 3096x1296 3062x1282 2752x1152 2580x1080
                           2560x1072 2520x1055 2480x1038 2440x1021 2400x1005
                           2365x990
             --dry-run     print the target path and plist, change nothing
             --force       overwrite an existing override file
uninstall  Move that display's override file to ~/.Trash (needs sudo).
EOF
}

die() {
  printf 'hidpi-override: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  printf 'hidpi-override: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}

# ---- display discovery ------------------------------------------------------

# One record per external display: "vid<TAB>pid<TAB>name" (ids in decimal).
# Vendor, product and name come from the same ioreg line, so they cannot misalign.
DISPLAYS=()

discover_displays() {
  local lines line attrs vid pid name seen=" "
  DISPLAYS=()
  if [[ -n "${HIDPI_IOREG_FIXTURE:-}" ]]; then
    [[ -r "$HIDPI_IOREG_FIXTURE" ]] || die "cannot read HIDPI_IOREG_FIXTURE: $HIDPI_IOREG_FIXTURE"
    lines=$(grep '"DisplayAttributes"' -- "$HIDPI_IOREG_FIXTURE" || true)
  else
    lines=$(ioreg -l -w0 | grep '"DisplayAttributes"' || true)
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    attrs=$(printf '%s\n' "$line" | sed -n 's/.*"ProductAttributes"={\([^}]*\)}.*/\1/p')
    [[ -n "$attrs" ]] || continue
    vid=$(printf '%s\n' "$attrs" | sed -n 's/.*"LegacyManufacturerID"=\([0-9][0-9]*\).*/\1/p')
    pid=$(printf '%s\n' "$attrs" | sed -n 's/.*"ProductID"=\([0-9][0-9]*\).*/\1/p')
    name=$(printf '%s\n' "$attrs" | sed -n 's/.*"ProductName"="\([^"]*\)".*/\1/p')
    [[ -n "$vid" && -n "$pid" ]] || continue
    [[ "$((10#$vid))" -ne "$APPLE_VENDOR" ]] || continue
    # The same display can appear on several registry lines; the override
    # file is per vendor/product, so list it once.
    case "$seen" in *" $vid:$pid "*) continue ;; esac
    seen="$seen$vid:$pid "
    DISPLAYS+=("$(printf '%s\t%s\t%s' "$((10#$vid))" "$((10#$pid))" "${name:-unknown}")")
  done <<<"$lines"
}

cmd_list() {
  local i=0 rec vid pid name
  [[ $# -eq 0 ]] || die_usage "list takes no arguments"
  discover_displays
  [[ ${#DISPLAYS[@]} -gt 0 ]] || die "no external display found"
  for rec in "${DISPLAYS[@]}"; do
    i=$((i + 1))
    IFS=$'\t' read -r vid pid name <<<"$rec"
    printf '%d  %x:%x  %s\n' "$i" "$vid" "$pid" "$name"
  done
}

# Sets SEL_VID, SEL_PID (decimal) and SEL_NAME. $1 is the requested index or "".
select_display() {
  local want=$1 idx
  discover_displays
  [[ ${#DISPLAYS[@]} -gt 0 ]] || die "no external display found (run: list)"
  if [[ -n "$want" ]]; then
    [[ "$want" =~ ^[0-9]+$ ]] || die "--display needs a number, got: $want"
    idx=$((10#$want))
    { [[ $idx -ge 1 && $idx -le ${#DISPLAYS[@]} ]]; } || die "--display $want out of range (1-${#DISPLAYS[@]}, see: list)"
  elif [[ ${#DISPLAYS[@]} -eq 1 ]]; then
    idx=1
  else
    die "${#DISPLAYS[@]} external displays found: pass --display N (see: list)"
  fi
  IFS=$'\t' read -r SEL_VID SEL_PID SEL_NAME <<<"${DISPLAYS[$((idx - 1))]}"
}

# Sets VENDOR_DIR and TARGET for SEL_VID/SEL_PID.
set_paths() {
  VENDOR_DIR="$OVERRIDES_DIR/$(printf 'DisplayVendorID-%x' "$SEL_VID")"
  TARGET="$VENDOR_DIR/$(printf 'DisplayProductID-%x' "$SEL_PID")"
}

# ---- plist generation -------------------------------------------------------

# base64 of the bytes given as one hex string.
b64_of_hex() {
  printf '%s' "$1" | xxd -r -p | base64
}

# Writes the plist to $1 for SEL_VID/SEL_PID; remaining args are WxH values.
build_plist() {
  local out=$1 res w h backing
  shift
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DisplayProductID</key>
	<integer>$SEL_PID</integer>
	<key>DisplayVendorID</key>
	<integer>$SEL_VID</integer>
	<key>scale-resolutions</key>
	<array>
EOF
    for res in "$@"; do
      w=${res%x*}
      h=${res#*x}
      backing=$(printf '%08x%08x' "$((2 * 10#$w))" "$((2 * 10#$h))")
      printf '\t\t<data>%s</data>\n' "$(b64_of_hex "$backing")"
      printf '\t\t<data>%s</data>\n' "$(b64_of_hex "${backing}0000000900200000")"
    done
    cat <<'EOF'
	</array>
</dict>
</plist>
EOF
  } >"$out"
}

# ---- commands ---------------------------------------------------------------

cmd_install() {
  local display="" res="$DEFAULT_RES" dry=0 force=0 r w h
  local res_list=() valid=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --display)
        [[ $# -ge 2 ]] || die_usage "--display needs a value"
        display=$2
        shift 2
        ;;
      --res)
        [[ $# -ge 2 ]] || die_usage "--res needs a value"
        res=$2
        shift 2
        ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      *) die_usage "unknown option for install: $1" ;;
    esac
  done

  IFS=$' \t\n' read -r -a res_list <<<"$res" || true
  [[ ${#res_list[@]} -gt 0 ]] || die "--res is empty"
  for r in "${res_list[@]}"; do
    if ! [[ "$r" =~ ^([0-9]{1,5})x([0-9]{1,5})$ ]]; then
      die "invalid resolution '$r': expected WxH with positive integers, e.g. 3440x1440"
    fi
    w=${BASH_REMATCH[1]}
    h=${BASH_REMATCH[2]}
    if [[ $((10#$w)) -le 0 || $((10#$h)) -le 0 ]]; then
      die "invalid resolution '$r': width and height must be positive"
    fi
    case " ${valid[*]:-} " in *" $((10#$w))x$((10#$h)) "*) continue ;; esac
    valid+=("$((10#$w))x$((10#$h))")
  done

  select_display "$display"
  set_paths

  TMP=$(mktemp -t hidpi-override)
  trap 'rm -f "$TMP"' EXIT
  build_plist "$TMP" "${valid[@]}"
  plutil -lint "$TMP" >/dev/null || die "generated plist failed plutil -lint"

  printf 'Display: %s (%x:%x)\n' "$SEL_NAME" "$SEL_VID" "$SEL_PID"
  printf 'Target:  %s\n' "$TARGET"
  if [[ $dry -eq 1 ]]; then
    [[ ! -e "$TARGET" ]] || printf 'Note:    target exists (install needs --force)\n'
    plutil -p "$TMP"
    printf 'Dry run: nothing written.\n'
    return 0
  fi

  if [[ -e "$TARGET" && $force -ne 1 ]]; then
    die "$TARGET exists; use --force to overwrite"
  fi
  sudo install -d -o root -g wheel -m 755 "$VENDOR_DIR"
  sudo install -o root -g wheel -m 644 "$TMP" "$TARGET"
  printf 'Installed %s\n' "$TARGET"
  printf 'Unplug and replug the monitor to apply (or log out).\n'
}

cmd_uninstall() {
  local display="" trash dest stamp
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --display)
        [[ $# -ge 2 ]] || die_usage "--display needs a value"
        display=$2
        shift 2
        ;;
      *) die_usage "unknown option for uninstall: $1" ;;
    esac
  done

  select_display "$display"
  set_paths
  [[ -e "$TARGET" ]] || die "no override installed at $TARGET"
  trash="$HOME/.Trash"
  [[ -d "$trash" ]] || die "$trash does not exist"
  stamp=$(date +%Y%m%d-%H%M%S)
  dest="$trash/$(basename -- "$TARGET")-$(basename -- "$VENDOR_DIR")-$stamp"

  sudo mv -- "$TARGET" "$dest"
  sudo chown "${USER:-$(id -un)}" "$dest"
  sudo rmdir -- "$VENDOR_DIR" 2>/dev/null || true
  printf 'Moved %s to %s\n' "$TARGET" "$dest"
  printf 'Unplug and replug the monitor to apply (or log out).\n'
}

# ---- main -------------------------------------------------------------------

[[ $# -gt 0 ]] || die_usage "missing command"
command=$1
shift
case "$command" in
  list) cmd_list "$@" ;;
  install) cmd_install "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  -h | --help) usage; exit 0 ;;
  *) die_usage "unknown command: $command" ;;
esac
