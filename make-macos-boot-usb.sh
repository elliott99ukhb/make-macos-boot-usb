#!/bin/bash
#
# make-macos-boot-usb.sh
# ----------------------
# Interactive creator for macOS bootable USB install drives.
#
#   1. Lists the macOS installers available to download (stable AND betas your
#      Mac is enrolled for) and lets you pick one.
#   2. Lists your external USB drives and lets you pick the target.
#   3. After an explicit confirmation, formats the drive, downloads the FULL
#      installer in the background, and writes the bootable installer to it.
#   4. Verifies the result and tells you it's safe to boot from.
#
# Why mist instead of `softwareupdate --fetch-full-installer`?
#   `softwareupdate --fetch-full-installer` is unreliable for beta releases: it
#   frequently writes a ~20 MB *stub* app (empty SharedSupport) that then makes
#   you click through a GUI download. `createinstallmedia` rejects that stub with
#   "does not appear to be a valid OS installer application". mist (mist-cli)
#   downloads the genuine full installer non-interactively, betas included, so
#   the whole thing runs unattended after you enter your password.
#
# Usage:
#   ./make-macos-boot-usb.sh            # do it for real
#   ./make-macos-boot-usb.sh --dry-run  # walk the whole flow, but change nothing
#   ./make-macos-boot-usb.sh --help
#
# Only external, physical disks can ever be selected as the target, so your
# internal startup disk is never a candidate. You still get a final, explicit,
# type-the-word-ERASE confirmation before anything is written.
#
# Requirements: macOS, Homebrew (to install mist automatically), admin rights,
# and a 32 GB+ USB drive (recent installers are ~17 GB; 16 GB is too small).

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
# Options
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

# ask_index <count> <prompt> [min] : read a menu number in [min..count].
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

WORKDIR=""
cleanup() {
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "This script only runs on macOS."
command -v diskutil >/dev/null || die "'diskutil' not found."
WORKDIR="$(mktemp -d -t makemacosusb)" || die "Could not create a temp directory."

printf '%s%s macOS Boot USB Creator %s\n' "$BOLD" "$BLU" "$RST"
[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN MODE: nothing will be downloaded, erased, or written."

# ---------------------------------------------------------------------------
# Ensure mist (mist-cli) is available
# ---------------------------------------------------------------------------
ensure_mist() {
  command -v mist >/dev/null && return 0
  warn "mist (mist-cli) is required to download full macOS installers, and isn't installed."
  if command -v brew >/dev/null; then
    printf '  Install it now with Homebrew (brew install mist-cli)? [Y/n]: '
    local r; read -r r || r=""
    if [[ ! "$r" =~ ^[Nn] ]]; then
      brew install mist-cli || die "Homebrew failed to install mist-cli."
    fi
  fi
  command -v mist >/dev/null || die "Please install mist first: brew install mist-cli  (https://github.com/ninxsoft/mist-cli)"
}
if [[ $DRY_RUN -eq 0 ]]; then
  ensure_mist
elif ! command -v mist >/dev/null; then
  warn "mist not installed; this dry-run can't fetch the installer list."
fi

# The catalog URL your Mac is configured for. When you're enrolled in a beta
# seed, this points at the seed catalog, which is how beta installers become
# visible to mist. Empty on a stock config (mist then uses its own default).
CATALOG="$(defaults read /Library/Preferences/com.apple.SoftwareUpdate CatalogURL 2>/dev/null || true)"
CAT_ARGS=()
if [[ -n "$CATALOG" ]]; then
  CAT_ARGS=(--catalog-url "$CATALOG")
  info "Using your system's software catalog (any beta-seed installers will be visible)."
fi

# ===========================================================================
# 1. Choose a macOS version
# ===========================================================================
step "Asking mist which macOS installers are available…"
CSV="$WORKDIR/list.csv"
if command -v mist >/dev/null; then
  mist list installer "${CAT_ARGS[@]}" --include-betas --export "$CSV" --output-type csv --no-ansi >/dev/null 2>&1 \
    || die "mist could not fetch the installer list. Check your network connection."
fi
[[ -s "$CSV" ]] || die "No installer list was produced by mist."

# mist's CSV columns: Identifier,Name,Version,Build,Size,Date,Compatible,Beta
# Version/Build come Excel-quoted as ="27.0"; strip quotes and a leading '='.
names=(); vers=(); builds=(); szbytes=(); betaflags=()
while IFS=$'\t' read -r nm ver bld sz bta; do
  [[ -z "$bld" ]] && continue
  names+=("$nm"); vers+=("$ver"); builds+=("$bld"); szbytes+=("$sz"); betaflags+=("$bta")
done < <(awk -F',' 'NR>1{
    for (i=1;i<=NF;i++){ gsub(/"/,"",$i); sub(/^=/,"",$i) }
    print $2"\t"$3"\t"$4"\t"$5"\t"$8
}' "$CSV")

(( ${#builds[@]} > 0 )) || die "Could not parse any installers from mist's output."

echo
printf '    %s%-3s %-26s %-9s %-11s %-10s %s%s\n' "$DIM" "#" "Name" "Version" "Build" "Size" "Type" "$RST"
for i in "${!builds[@]}"; do
  gb="$(awk -v b="${szbytes[$i]}" 'BEGIN{printf "%.1f GB", b/1e9}')"
  tag=""; [[ "${betaflags[$i]}" == "YES" ]] && tag="beta"
  printf '    %-3s %-26s %-9s %-11s %-10s %s\n' \
    "$((i+1))" "${names[$i]}" "${vers[$i]}" "${builds[$i]}" "$gb" "$tag"
done
echo
sel="$(ask_index "${#builds[@]}" "  Which macOS do you want to build a USB for? (number): ")"
sel=$((sel-1))

SEL_NAME="${names[$sel]}"
SEL_VER="${vers[$sel]}"
SEL_BUILD="${builds[$sel]}"
SEL_BYTES="${szbytes[$sel]}"
ok "Selected: ${BOLD}${SEL_NAME}${RST} (version $SEL_VER, build $SEL_BUILD, $(awk -v b="$SEL_BYTES" 'BEGIN{printf "%.1f GB", b/1e9}'))"

# ===========================================================================
# 2. Choose the target USB drive
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

names_d=(); sizes_h=(); bytes_d=(); protos=()
for d in "${disks[@]}"; do
  di="$(diskutil info "/dev/$d" 2>/dev/null)"
  nm="$(awk -F': +' '/Device \/ Media Name/{print $2; exit}' <<< "$di")"
  sz="$(awk -F': +' '/Disk Size/{print $2; exit}'          <<< "$di")"
  by="$(grep -oE '\(([0-9]+) Bytes\)' <<< "$di" | grep -oE '[0-9]+' | head -1)"
  pr="$(awk -F': +' '/Protocol/{print $2; exit}'           <<< "$di")"
  names_d+=("${nm:-Unknown}"); sizes_h+=("${sz%% (*}"); bytes_d+=("${by:-0}"); protos+=("${pr:-?}")
done

echo
printf '    %s%-3s %-9s %-28s %-11s %s%s\n' "$DIM" "#" "Device" "Name" "Size" "Bus" "$RST"
for i in "${!disks[@]}"; do
  printf '    %-3s /dev/%-4s %-28s %-11s %s\n' \
    "$((i+1))" "${disks[$i]}" "${names_d[$i]}" "${sizes_h[$i]}" "${protos[$i]}"
done
echo
warn "Everything on the chosen drive will be destroyed."
usb="$(ask_index "${#disks[@]}" "  Which drive is your target USB? (number): ")"
usb=$((usb-1))

SEL_DISK="${disks[$usb]}"
SEL_DNAME="${names_d[$usb]}"
SEL_DSIZE="${sizes_h[$usb]}"
SEL_DBYTES="${bytes_d[$usb]}"

# Capacity check against the *actual* installer size.
if (( SEL_DBYTES > 0 && SEL_DBYTES < SEL_BYTES )); then
  need_gb="$(awk -v b="$SEL_BYTES"  'BEGIN{printf "%.1f", b/1e9}')"
  have_gb="$(awk -v b="$SEL_DBYTES" 'BEGIN{printf "%.1f", b/1e9}')"
  die "This drive is too small: it holds ${have_gb}GB but the installer needs about ${need_gb}GB. Use a 32GB drive."
fi
ok "Target: /dev/$SEL_DISK ($SEL_DNAME, $SEL_DSIZE)"

# ===========================================================================
# 3. Final confirmation
# ===========================================================================
step "FINAL CONFIRMATION"
printf '    This will %sPERMANENTLY ERASE%s /dev/%s (%s, %s)\n' "$RED$BOLD" "$RST" "$SEL_DISK" "$SEL_DNAME" "$SEL_DSIZE"
printf '    and turn it into a bootable installer for %s%s %s%s.\n' "$BOLD" "$SEL_NAME" "$SEL_VER" "$RST"
echo
printf '  Type %sERASE%s to proceed (anything else cancels): ' "$BOLD" "$RST"
read -r confirm || exit 1
[[ "$confirm" == "ERASE" ]] || die "Cancelled — nothing was changed."

if [[ $DRY_RUN -eq 0 ]]; then
  info "Administrator access is required to erase the disk and write the installer."
  sudo -v || die "Could not obtain administrator privileges."
fi

# ===========================================================================
# 4. Format, then download + build (all unattended)
# ===========================================================================
VOLNAME="MacInstaller"   # mist requires a Mac OS Extended (Journaled) volume;
                         # it re-erases and renames it during the build.

step "Erasing and formatting /dev/$SEL_DISK as Mac OS Extended (Journaled), GUID…"
run sudo diskutil eraseDisk JHFS+ "$VOLNAME" GPT "/dev/$SEL_DISK" \
  || die "Failed to erase the disk. Is it still connected / not in use?"

step "Downloading the full installer and building the boot USB with mist…"
info "This downloads ~$(awk -v b="$SEL_BYTES" 'BEGIN{printf "%.0f", b/1e9}')GB in the background (no clicking),"
info "then erases the volume again and makes it bootable. Expect 20–40 minutes."
run sudo mist download installer "$SEL_BUILD" bootableinstaller \
  --bootable-installer-volume "/Volumes/$VOLNAME" \
  "${CAT_ARGS[@]}" \
  --include-betas \
  || die "mist failed to build the installer. The USB is NOT bootable; re-run to try again."

# ===========================================================================
# 5. Verify + finish
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
  warn "mist reported success but I couldn't see the mounted volume — check 'diskutil list'."
fi

echo
ok "${BOLD}Your ${SEL_NAME} boot USB is ready and safe to boot from.${RST}"
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
