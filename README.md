# Dusky Precompiled Packages Repository

Precompiled Arch Linux x86_64 packages for Dusky desktop components, hosted directly on GitHub CDN for fast installation without compiling Rust code locally.

## Packages Included

| Package | Description | Binary Path |
| :--- | :--- | :--- |
| `dusky_calendar` | Native Rust calendar for Hyprland | `/usr/bin/dusky_calendar` |
| `dusky_casts` | Wayland podcast and local audio player | `/usr/bin/dusky_casts` |
| `dusky_center` | Control center for Hyprland | `/usr/bin/dusky_center` |
| `dusky_network` | Network meter for Waybar & Glance | `/usr/bin/dusky_network` |
| `dusky_overview` | Workspace switcher for Hyprland | `/usr/bin/dusky_overview` |
| `dusky_papers` | Wallpaper browser for Hyprland | `/usr/bin/dusky_papers` |
| `dusky_snap` | Screenshot and annotation tool | `/usr/bin/dusky_snap` |
| `dusky_tray` | System tray manager for Hyprland | `/usr/bin/dusky_tray` |

## Usage Options

### Option 1: Native Pacman Repository
Add the following block to your `/etc/pacman.conf`:

```ini
[dusky]
SigLevel = Optional TrustAll
Server = https://raw.githubusercontent.com/dusklinux/dusky_packages/main/$arch
```

Then synchronize and install:
```bash
sudo pacman -Sy dusky_calendar dusky_casts dusky_center dusky_overview dusky_papers dusky_snap dusky_tray dusky_network
```

### Option 2: Dusky Package Sync Tool (`dusky-pkg-sync`)
Use the dedicated standalone Python 3.15 sync script:

```bash
# Check for available updates (dry run)
dusky-pkg-sync --check

# Install / update all dusky packages
dusky-pkg-sync

# Force reinstall all packages
dusky-pkg-sync --force
```

## Repository Structure

```
dusky_packages/
├── manifest.json                 # Machine-readable metadata index
├── README.md                     # Documentation
└── x86_64/
    ├── dusky.db                  # Pacman sync database (raw CDN compatible)
    ├── dusky.db.tar.zst          # Pacman sync database archive
    ├── dusky.files               # Pacman files database (raw CDN compatible)
    ├── dusky.files.tar.zst       # Pacman files database archive
    └── *.pkg.tar.zst             # Precompiled package archives
```
