# Nook

A tiny macOS menu-bar app that keeps your Downloads folder tidy. New files are moved into folders based on simple rules. Every move can be undone.

- Native Swift, one source file, no dependencies, <1 MB DMG
- Rules by file extension and/or filename regex
- Waits for downloads to finish (ignores `.crdownload`, `.part`, `.download`, ...)
- Undo log, recent moves, pause/resume, launch at login

## Build

```bash
./build.sh
```

Produces `build/Nook.app` (universal) and `build/Nook.dmg`. Needs Xcode command line tools.
The app is ad-hoc signed; on first launch right-click it and choose **Open**.

## Settings

Menu bar icon → **Settings…** (⌘,). A native Preferences window with General (folders, open at login) and Rules (add, edit, delete, drag-reorder) tabs. Extensions are comma separated; the name field is an optional regex. Changes are saved automatically. Invalid regexes turn red and are not saved.

Rules are stored in `~/Library/Application Support/Nook/rules.json`, so you can also edit them by hand. The first matching rule wins.

```json
{
  "watch": "~/Downloads",
  "root": "~/Downloads",
  "rules": [
    {"dest": "Images", "ext": ["png", "jpg"]},
    {"dest": "Documents/Invoices", "name": "invoice|rechnung"}
  ]
}
```

Only top-level files in `watch` are moved; subfolders and dotfiles are left alone. Name clashes become `file (1).ext`.
