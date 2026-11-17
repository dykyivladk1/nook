# Nook

A small macOS app that keeps your Downloads folder tidy. New files are moved into folders based on simple rules. Every move can be undone.

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

## Browse Files

Nook is a regular Mac app (Dock icon, ⌘Tab, no menu-bar icon). Launching it from Alfred, Spotlight, Finder or the Dock opens this window first. Closing the window keeps Nook sorting in the background; click the Dock icon to reopen it, ⌘Q to quit. When macOS starts Nook at login it starts without a window.

Everything the old menu-bar icon did now lives in the app: the **Sorting** menu in the menu bar (Pause/Resume, Sort Now ⇧⌘R, Undo Last Move ⌥⌘Z, Recent Moves, Open at Login), the wand button in the explorer, and the Dock icon's right-click menu.

Menu bar icon → **Browse Files…** opens a Finder-style window inside Nook:

- Sidebar with Favorites and your Nook folders; sortable Name / Date / Size / Kind columns; search
- Back / forward / enclosing folder (⌘[ ⌘] ⌘↑), clickable path menu, double-click to open
- Copy, cut, paste (⌘C ⌘X ⌘V, works with Finder), duplicate, compress, rename, new folder (⇧⌘N), Move to Trash (⌫)
- Drag and drop between folders, the sidebar and Finder (hold ⌥ to copy); **Move To** in the context menu
- Quick Look, Show in Finder, show hidden files, live refresh when Nook sorts something
- Drag moves are logged, so **Undo Last Move** works for them too

## Smart search

The search box in **Browse Files** understands plain language and searches names **and file contents** (PDFs, Word, text, ...) through Spotlight:

- `pdf about taxes last week`, `images bigger than 5 mb`, `invoice yesterday`, `videos smaller than 200 mb this month`
- Scope switch: This Folder / Everywhere; right-click a result → **Show in Folder**

**Optional OpenAI mode** (Settings → Search): paste your API key (stored in your Keychain, never in the repo), turn it on, and press Return in the search box. Only the text you typed is sent to OpenAI, which expands it into synonyms/translations, dates and sizes (`Rechnung telekom last month` also finds "invoice"). File names and contents never leave your Mac. Without a key everything still works locally.

## Settings

**Nook → Settings…** (⌘,). A native Preferences window with General (folders, open at login) and Rules tabs. Extensions are comma separated; the name field is an optional regex. 
Making rules is point-and-click:

- **Add Rule** → pick a ready-made kind (Images, Documents, Video, ...) for a one-click rule, or **Custom Rule…** to choose several kinds, add extra file types, an optional "name contains" filter and a folder.
- **Drop a file** onto the Rules tab to create a rule for its type.
- New rules go on top and the first match wins; drag to reorder.

Nook offers to open at login on first launch; you can also toggle **Open at Login** in the menu or in Settings → General.

**Sort new files** (General tab) lets recent files sit untouched for a while (1 minute up to 1 week) before they are moved. **Sort Now** in the menu ignores the wait.

Changes are saved automatically. Invalid regexes turn red and are not saved.

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
