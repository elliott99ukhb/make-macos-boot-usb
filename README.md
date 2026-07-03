# make-macos-boot-usb

An interactive Bash script for macOS that builds a bootable USB install drive for
any macOS version Apple currently offers — including betas like **macOS Golden Gate
(27.0)**. Pick a version, pick a USB drive, confirm, and it does the rest.

It wraps Apple's own supported tools (`softwareupdate` and `createinstallmedia`), so
there's no third‑party download or dependency — just a friendlier, safer front end.

## What it does

1. **Lists available macOS installers** from `softwareupdate --list-full-installers`
   and lets you choose one from a numbered menu.
2. **Downloads the installer** (or reuses one already in `/Applications`).
3. **Lists your external USB drives** and lets you choose the target. Only
   *external, physical* disks are ever candidates — your internal startup disk can
   never be selected.
4. **Checks capacity** against the *actual* installer size (recent installers are
   ~17 GB, so a 16 GB stick is rejected — use 32 GB).
5. **Erases and formats** the drive (Mac OS Extended / Journaled, GUID) and runs
   `createinstallmedia`.
6. **Verifies** the result, tells you it's safe to boot from, shows the boot-key
   steps, and offers to eject.

## Requirements

- A Mac running macOS (Apple Silicon or Intel).
- Administrator (sudo) access.
- A **32 GB or larger** USB drive (16 GB is too small for current installers).
- For beta releases, enable the beta in **System Settings › General › Software
  Update** so the installer appears in the list.

## Usage

```bash
git clone https://github.com/elliott99ukhb/make-macos-boot-usb.git
cd make-macos-boot-usb
chmod +x make-macos-boot-usb.sh

# Rehearse the whole flow without downloading, erasing, or writing anything:
./make-macos-boot-usb.sh --dry-run

# Build a boot USB for real:
./make-macos-boot-usb.sh

# Help:
./make-macos-boot-usb.sh --help
```

### Dry-run mode

`--dry-run` walks the entire interactive flow — version menu, installer choice, USB
detection, and the final confirmation — but **changes nothing**. Instead of running
the download/erase/write commands it prints exactly what it *would* run. Use it to
confirm the script detects your drive correctly before committing to an erase.

## Safety

Building a boot USB **erases the entire target disk**. The script guards against
mistakes:

- Only external, physical disks are offered as targets; the startup disk is filtered out.
- The selected drive, its name, and its size are shown before anything happens.
- You must type `ERASE` (not just `y`) to proceed.
- Drives too small for the chosen installer are rejected up front.

Even so: **double-check you've selected the right drive.** Anything on it will be
destroyed.

## Booting from the finished USB

**Apple Silicon:**
1. Shut the Mac down.
2. Press and **hold** the power button until *"Loading startup options"* appears.
3. Choose the *"Install macOS…"* drive and click **Continue**.

**Intel:** Hold the **Option/Alt** key at startup and select the installer drive.

## How it works

The script is a thin, careful wrapper around Apple's supported workflow:

```bash
softwareupdate --list-full-installers
softwareupdate --fetch-full-installer --full-installer-version <version>
diskutil eraseDisk JHFS+ MacInstaller GPT /dev/diskN
sudo "/Applications/Install macOS <name>.app/Contents/Resources/createinstallmedia" \
     --volume /Volumes/MacInstaller --nointeraction
```

## License

MIT — see [LICENSE](LICENSE).
