# Nook

A tiny macOS menu-bar app that keeps your Downloads folder tidy. New files are moved into folders based on simple rules. Every move can be undone.

- Native Swift, one source file, no dependencies, ~140 KB DMG
- Rules by file extension and/or filename regex
- Waits for downloads to finish (ignores `.crdownload`, `.part`, `.download`, ...)
- Undo log, recent moves, pause/resume, launch at login

## Build

```bash
./build.sh
```

Produces `build/Nook.app` (universal) and `build/Nook.dmg`. Needs Xcode command line tools.
The app is ad-hoc signed; on first launch right-click it and choose **Open**.

## Rules

Edit via the menu: **Edit Rules…** (`~/Library/Application Support/Nook/rules.json`). Changes are picked up automatically. The first matching rule wins.

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
