#!/bin/bash
#
# make-macos-boot-usb.sh
# ----------------------
# Interactive creator for macOS bootable USB install drives.
#
#   1. Lists the macOS installers Apple currently offers and lets you pick one.
#   2. Downloads it (or reuses one already in /Applications).
#   3. Lists your external USB drives and lets you pick the target.
#   4. Erases + formats the drive, then runs Apple's `createinstallmedia`.
#   5. Verifies the result and tells you it's safe to boot from.
#
# Usage:
#   ./make-macos-boot-usb.sh            # do it for real
#   ./make-macos-boot-usb.sh --dry-run  # walk the whole flow, but change nothing
#
# Only external, physical disks can ever be selected as the target, so your
# internal startup disk is never a candidate. You still get a final, explicit,
# type-the-word-ERASE confirmation before anything is written.

set -uo pipefail

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
  BOLD=; DIM=; RED=; GRN=; YEL=; BLU=; RST=
fi

step() { printf '\n%s==>%s %s%s%s\n' "$BLU" "$RST" "$BOLD" "$*" "$RST"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s  !%s %s\n'  "$YEL" "$RST" "$*"; }
err()  { printf '%s  ✗%s %s\n'  "$RED" "$RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Dry-run plumbing
# ---------------------------------------------------------------------------
DRY_RUN=0
case "${1:-}" in
  -n|--dry-run) DRY_RUN=1 ;;
  -h|--help)
    grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
    exit 0 ;;
  "") ;;
  *) die "Unknown option: $1  (try --help)" ;;
esac

# run <command...> : execute it, or just print it when in dry-run mode.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s    [dry-run] would run:%s %s\n' "$DIM" "$RST" "$*"
    return 0
  fi
  "$@"
}

# ask_index <count> <prompt> : read a menu number in 1..count (or the given
# minimum). Echoes the chosen number on stdout. Re-prompts until valid.
ask_index() {
  local count="$1" prompt="$2" min="${3:-1}" reply
  while true; do
    printf '%s' "$prompt" >&2
    read -r reply || die "No input; aborting."
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= min && reply <= count )); then
      printf '%s' "$reply"; return 0
    fi
    err "Please enter a number between $min and $count."
  done
}

cleanup() { printf '\n'; }
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "This script only runs on macOS."
command -v softwareupdate >/dev/null || die "'softwareupdate' not found."
command -v diskutil       >/dev/null || die "'diskutil' not found."

printf '%s%s macOS Boot USB Creator %s\n' "$BOLD" "$BLU" "$RST"
[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN MODE: nothing will be downloaded, erased, or written."

# ===========================================================================
# 1. Choose a macOS version
# ===========================================================================
step "Asking Apple which macOS installers are available…"
RAW="$(softwareupdate --list-full-installers 2>/dev/null)"
[[ -n "$RAW" ]] || die "Couldn't get the installer list from softwareupdate."

titles=(); versions=(); builds=(); sizes_kib=()
while IFS= read -r line; do
  case "$line" in *Title:*Version:*) ;; *) continue ;; esac
  t="${line#*Title: }";   t="${t%%, Version:*}"
  v="${line#*Version: }"; v="${v%%,*}"
  b="${line#*Build: }";   b="${b%%,*}"
  s="${line#*Size: }";    s="${s%%,*}"; s="${s%KiB}"
  titles+=("$t"); versions+=("$v"); builds+=("$b"); sizes_kib+=("$s")
done <<< "$RAW"

(( ${#titles[@]} > 0 )) || die "No installers were parsed from softwareupdate output."

echo
printf '    %s%-3s %-32s %-9s %-11s %s%s\n' "$DIM" "#" "Title" "Version" "Build" "Approx size" "$RST"
for i in "${!titles[@]}"; do
  gb="$(awk -v k="${sizes_kib[$i]}" 'BEGIN{printf "%.1f GB", k*1024/1e9}')"
  printf '    %-3s %-32s %-9s %-11s %s\n' \
    "$((i+1))" "${titles[$i]}" "${versions[$i]}" "${builds[$i]}" "$gb"
done
echo
sel="$(ask_index "${#titles[@]}" "  Which macOS do you want to build a USB for? (number): ")"
sel=$((sel-1))

SEL_TITLE="${titles[$sel]}"
SEL_VER="${versions[$sel]}"
SEL_BUILD="${builds[$sel]}"
SEL_KIB="${sizes_kib[$sel]}"
SEL_NEEDED_BYTES="$(awk -v k="$SEL_KIB" 'BEGIN{printf "%.0f", k*1024}')"
ok "Selected: ${BOLD}${SEL_TITLE}${RST} (version $SEL_VER, build $SEL_BUILD)"

# ===========================================================================
# 2. Obtain the installer app (download, or reuse an existing one)
# ===========================================================================
step "Preparing the installer application…"

existing=()
while IFS= read -r -d '' app; do
  existing+=("$app")
done < <(find /Applications -maxdepth 1 -name 'Install macOS*.app' -print0 2>/dev/null)

echo "    0) Download \"$SEL_TITLE\" ($SEL_VER) now with softwareupdate"
for i in "${!existing[@]}"; do
  printf '    %s) Reuse existing: %s\n' "$((i+1))" "$(basename "${existing[$i]}")"
done
echo
choice="$(ask_index "${#existing[@]}" "  Choose the installer source (number): " 0)"

INSTALLER_APP=""
if (( choice == 0 )); then
  dl_gb="$(awk -v k="$SEL_KIB" 'BEGIN{printf "%.0f", k*1024/1e9}')"
  info "Downloading — this is a large (~${dl_gb}GB) download and may take a while."
  run softwareupdate --fetch-full-installer --full-installer-version "$SEL_VER" \
    || die "Download failed. If this is a beta, enable it in System Settings › General › Software Update, then retry."
  if [[ $DRY_RUN -eq 1 ]]; then
    INSTALLER_APP="/Applications/Install macOS ${SEL_TITLE#macOS }.app"
  else
    # The freshly-downloaded app is the newest Install macOS*.app in /Applications.
    while IFS= read -r -d '' app; do
      [[ -z "$INSTALLER_APP" || "$app" -nt "$INSTALLER_APP" ]] && INSTALLER_APP="$app"
    done < <(find /Applications -maxdepth 1 -name 'Install macOS*.app' -print0 2>/dev/null)
  fi
else
  INSTALLER_APP="${existing[$((choice-1))]}"
fi

[[ -n "$INSTALLER_APP" ]] || die "Could not locate the installer application."
CIM="$INSTALLER_APP/Contents/Resources/createinstallmedia"
if [[ $DRY_RUN -eq 0 ]]; then
  [[ -x "$CIM" ]] || die "createinstallmedia not found inside $INSTALLER_APP"
fi
ok "Using installer: $INSTALLER_APP"

# ===========================================================================
# 3. Choose the target USB drive
# ===========================================================================
step "Looking for external USB drives…"

boot_whole="$(diskutil info / 2>/dev/null | awk -F': +' '/Part of Whole/{print $2; exit}')"

scan_disks() {                       # populates global 'disks' array
  disks=()
  while IFS= read -r l; do
    case "$l" in
      /dev/disk*)
        d="${l%% *}"; d="${d#/dev/}"
        [[ "$d" == "$boot_whole" ]] && continue   # never the startup disk
        disks+=("$d")
        ;;
    esac
  done < <(diskutil list external physical 2>/dev/null)
}

disks=()
scan_disks
while (( ${#disks[@]} == 0 )); do
  warn "No external USB drives detected."
  printf '  Plug in your USB drive, then press Return to rescan (or q to quit): '
  read -r r || exit 1
  [[ "$r" == q* ]] && exit 1
  scan_disks
done

# Gather human-readable info for each candidate disk.
names=(); sizes_h=(); bytes=(); protos=()
for d in "${disks[@]}"; do
  di="$(diskutil info "/dev/$d" 2>/dev/null)"
  nm="$(awk -F': +' '/Device \/ Media Name/{print $2; exit}' <<< "$di")"
  sz="$(awk -F': +' '/Disk Size/{print $2; exit}'          <<< "$di")"
  by="$(grep -oE '\(([0-9]+) Bytes\)' <<< "$di" | grep -oE '[0-9]+' | head -1)"
  pr="$(awk -F': +' '/Protocol/{print $2; exit}'           <<< "$di")"
  names+=("${nm:-Unknown}"); sizes_h+=("${sz%% (*}"); bytes+=("${by:-0}"); protos+=("${pr:-?}")
done

echo
printf '    %s%-3s %-9s %-28s %-11s %s%s\n' "$DIM" "#" "Device" "Name" "Size" "Bus" "$RST"
for i in "${!disks[@]}"; do
  printf '    %-3s /dev/%-4s %-28s %-11s %s\n' \
    "$((i+1))" "${disks[$i]}" "${names[$i]}" "${sizes_h[$i]}" "${protos[$i]}"
done
echo
warn "Everything on the chosen drive will be destroyed."
usb="$(ask_index "${#disks[@]}" "  Which drive is your target USB? (number): ")"
usb=$((usb-1))

SEL_DISK="${disks[$usb]}"
SEL_NAME="${names[$usb]}"
SEL_DSIZE="${sizes_h[$usb]}"
SEL_DBYTES="${bytes[$usb]}"

# Capacity check against the *actual* installer size (not the article's 16GB myth).
if (( SEL_DBYTES > 0 && SEL_DBYTES < SEL_NEEDED_BYTES )); then
  need_gb="$(awk -v b="$SEL_NEEDED_BYTES" 'BEGIN{printf "%.1f", b/1e9}')"
  have_gb="$(awk -v b="$SEL_DBYTES"      'BEGIN{printf "%.1f", b/1e9}')"
  die "This drive is too small: it holds ${have_gb}GB but the installer needs about ${need_gb}GB. Use a 32GB drive."
fi
ok "Target: /dev/$SEL_DISK ($SEL_NAME, $SEL_DSIZE)"

# ===========================================================================
# 4. Final confirmation
# ===========================================================================
step "FINAL CONFIRMATION"
printf '    This will %sPERMANENTLY ERASE%s /dev/%s (%s, %s)\n' "$RED$BOLD" "$RST" "$SEL_DISK" "$SEL_NAME" "$SEL_DSIZE"
printf '    and turn it into a bootable installer for %s%s %s%s.\n' "$BOLD" "$SEL_TITLE" "$SEL_VER" "$RST"
echo
printf '  Type %sERASE%s to proceed (anything else cancels): ' "$BOLD" "$RST"
read -r confirm || exit 1
[[ "$confirm" == "ERASE" ]] || die "Cancelled — nothing was changed."

# Cache the admin password once so the erase + createinstallmedia run smoothly.
if [[ $DRY_RUN -eq 0 ]]; then
  info "Administrator access is required to erase the disk and write the installer."
  sudo -v || die "Could not obtain administrator privileges."
fi

# ===========================================================================
# 5. Erase + build the boot media
# ===========================================================================
VOLNAME="MacInstaller"   # temporary; createinstallmedia renames it afterwards.

step "Erasing and formatting /dev/$SEL_DISK as Mac OS Extended (Journaled), GUID…"
run sudo diskutil eraseDisk JHFS+ "$VOLNAME" GPT "/dev/$SEL_DISK" \
  || die "Failed to erase the disk. Is it still connected / not in use?"

step "Writing the installer with createinstallmedia (can take 20–40 minutes)…"
info "It will erase the volume again, copy files, then make the disk bootable."
run sudo "$CIM" --volume "/Volumes/$VOLNAME" --nointeraction \
  || die "createinstallmedia failed. The USB is NOT bootable; re-run to try again."

# ===========================================================================
# 6. Verify + finish
# ===========================================================================
step "Verifying…"
if [[ $DRY_RUN -eq 1 ]]; then
  ok "DRY-RUN complete — the flow works. Re-run without --dry-run to build for real."
  exit 0
fi

FINAL_VOL=""
while IFS= read -r -d '' v; do FINAL_VOL="$v"; done \
  < <(find /Volumes -maxdepth 1 -name 'Install macOS*' -print0 2>/dev/null)

if [[ -n "$FINAL_VOL" ]]; then
  ok "Boot installer created and mounted at: $FINAL_VOL"
else
  warn "createinstallmedia reported success but I couldn't see the mounted volume."
  warn "Check 'diskutil list' — it may simply have been renamed."
fi

echo
ok "${BOLD}Your ${SEL_TITLE} boot USB is ready and safe to boot from.${RST}"
info "To boot an Apple Silicon Mac from it:"
info "  1. Shut the Mac down."
info "  2. Press and HOLD the power button until 'Loading startup options' appears."
info "  3. Choose the 'Install macOS…' drive, then click Continue."
info "(On an Intel Mac: hold the Option/Alt key at startup and pick the installer.)"
echo
printf '  Eject the USB now so it is safe to unplug? [y/N]: '
read -r ej || ej=""
if [[ "$ej" == y* || "$ej" == Y* ]]; then
  if diskutil eject "/dev/$SEL_DISK"; then
    ok "Ejected. You can unplug the drive."
  else
    warn "Eject failed — close any windows using the drive and eject from Finder."
  fi
else
  info "Left mounted. Eject from Finder before unplugging."
fi
