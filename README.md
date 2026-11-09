# Codex Seat Switcher

**Seat Picker** is a small Windows tool for people who have the OpenAI **Codex desktop app** signed in to
several ChatGPT workspaces ("seats") with one login. With one click it:

1. closes Codex,
2. copies your project list from the seat you were in to every other seat, so all seats show the same projects,
3. switches Codex to the seat you picked,
4. reopens Codex.

It also shows each seat's last known weekly Codex usage, and keeps a list of the usage-limit resets you type in,
with a one-click "used" button.

![icon](assets/seat-icon.png)

## Why

Codex keeps the sidebar layout (projects, order, groups) separately for each workspace, so every new seat starts
empty. Switching seats also takes a trip through Codex's own menu. Seat Picker keeps the layout the same
everywhere and makes switching a single click.

## How switching works

All seats of one ChatGPT login share the same refresh token; only the **workspace ID** and the short-lived
**access token** differ per seat. Seat Picker:

- saves the current seat's login into a local slot (`logins/`) every time you switch away from it,
- writes only the target seat's workspace ID and access token into Codex's `auth.json`,
- always keeps the newest refresh token, and never writes an old one back,
- refuses to switch if a saved login belongs to a different sign-in, or if a file format is unknown.

A seat becomes "Auto switch" after you have switched to it once through Codex's own menu and then switched away
with Seat Picker. If a seat's saved access token has expired, Codex renews it on start and may open a different
seat once; switch in Codex's menu that time and the picker saves the fresh token.

## Safety

- Everything stays on your PC. Nothing is sent anywhere.
- A backup of Codex's state file is made before every sync (`backups/`), and of `auth.json` before every switch
  (`logins/auth-backups/`, last 10 kept).
- Nothing is written while Codex is running. "Quit Codex for me" ends Codex only when you click it.
- `logins/` holds your Codex login data. Treat it like a password. It is listed in `.gitignore`.
- If a Codex update changes its file formats, the tool stops and changes nothing.

This is an unofficial tool, not affiliated with OpenAI. Codex's internal files can change at any time. Use it only
with seats you are entitled to use; it does not pool or extend usage limits.

## Requirements

- Windows 10/11 with the Codex desktop app (Microsoft Store / MSIX version)
- Python 3 on PATH, or set the environment variable `SEAT_PICKER_PYTHON` to your `python.exe`
- Windows PowerShell 5.1 (built in)

## Install

```powershell
git clone https://github.com/<you>/codex-seat-switcher.git
cd codex-seat-switcher
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This creates a **Seat Picker** shortcut on your Desktop. Keep the folder outside `AppData` so Explorer can see it.

## Use

- **Switch**: click "Switch" on a seat (or double-click the row).
- **Sync only**: the orange round button copies the current seat's projects to all seats.
- **Rename** (pencil) and **Usage resets** (calendar) per seat; mark a reset used with its check mark.
- Drag a row by its dot handle to reorder seats. F5 refreshes, Esc closes.

## Command line

```powershell
python codex_seat_sync.py status                 # list seats and their layout
python codex_seat_sync.py seats                  # JSON: seats, usage, saved-login info
python codex_seat_sync.py sync --from active     # copy layout from the current seat to all seats
python codex_seat_sync.py switch --to <seat-id>  # plant a saved seat (Codex must be closed)
python codex_seat_sync.py restore <backup-file>  # put a state-file backup back
```

Add `--home <folder>` to work on a copy of the `.codex` folder instead of the real one.

## Files

| File | Purpose |
|---|---|
| `Codex-Seat-Picker.ps1` | the Seat Picker window (WinForms) |
| `codex_seat_sync.py` | layout sync, seat switching, usage reading |
| `install.ps1` | creates the Desktop shortcut |
| `assets/` | app icon and the script that draws it |
