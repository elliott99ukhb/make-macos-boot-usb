# make-macos-boot-usb

An interactive Bash script for macOS that builds a bootable USB install drive for
any macOS version available to download — including betas like **macOS Golden Gate
(27.0)**. Pick a version, pick a USB drive, confirm, and it downloads the full
installer and writes the boot drive **unattended** (no clicking through a GUI).

## What it does

1. **Lists available macOS installers** (via [`mist`](https://github.com/ninxsoft/mist-cli))
   and lets you choose one from a numbered menu — stable releases *and* any betas
   your Mac is enrolled to see.
2. **Lists your external USB drives** and lets you choose the target. Only
   *external, physical* disks are ever candidates — your internal startup disk can
   never be selected.
3. **Checks capacity** against the *actual* installer size (recent installers are
   ~17 GB, so a 16 GB stick is rejected — use 32 GB).
4. **Formats the drive**, then **downloads the full installer in the background**
   and writes the bootable installer to it. After you enter your password once,
   the whole thing runs unattended.
5. **Verifies** the result, tells you it's safe to boot from, shows the boot-key
   steps, and offers to eject.

## Why `mist` and not `softwareupdate`?

The obvious approach — `softwareupdate --fetch-full-installer` piped into Apple's
`createinstallmedia` — is what most guides show, and it works for many *stable*
releases. But for **beta** releases it is unreliable: on an enrolled Mac it often
writes a **~20 MB stub** application with an empty `SharedSupport` folder (the
little app that then makes *you* click to download the OS through a GUI).
`createinstallmedia` rejects that stub with:

> `… does not appear to be a valid OS installer application.`

[`mist-cli`](https://github.com/ninxsoft/mist-cli) downloads the **genuine full
installer** non-interactively — betas included — so there's nothing to click and
`createinstallmedia` has a real payload to work with. This script installs `mist`
for you (via Homebrew) if it's missing.

### How beta installers are found

Beta installers live in Apple's **developer/public-seed catalog**, which `mist`'s
default catalog doesn't include. The script reads the catalog URL your Mac is
already configured for:

```bash
defaults read /Library/Preferences/com.apple.SoftwareUpdate CatalogURL
```

and passes it to `mist` with `--catalog-url … --include-betas`. So if your Mac is
enrolled in a beta seed, that beta shows up in the menu automatically; if it isn't,
you simply see the stable releases.

## Requirements

- A Mac running macOS (Apple Silicon or Intel).
- Administrator (sudo) access.
- [Homebrew](https://brew.sh) (the script uses it to install `mist` automatically),
  or install `mist` yourself: `brew install mist-cli`.
- A **32 GB or larger** USB drive (16 GB is too small for current installers).
- For beta releases, enroll in the beta in **System Settings › General › Software
  Update** so the beta appears in your Mac's catalog.

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

`--dry-run` walks the entire interactive flow — version menu (fetched live from
`mist`), USB detection, and the final confirmation — but **changes nothing**.
Instead of running the erase/download/write commands it prints exactly what it
*would* run. Use it to confirm the script detects your drive correctly before
committing to an erase.

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

## Doing it manually

If you'd rather run the underlying command yourself (for example, onto a volume
you've already formatted as *Mac OS Extended (Journaled)* named `MacInstaller`):

```bash
sudo mist download installer "<build>" bootableinstaller \
  --bootable-installer-volume "/Volumes/MacInstaller" \
  --catalog-url "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate CatalogURL)" \
  --include-betas
```

Replace `<build>` with the build number from `mist list installer --include-betas`
(e.g. `26A5368g` for macOS Golden Gate 27.0).

## License

MIT — see [LICENSE](LICENSE).
