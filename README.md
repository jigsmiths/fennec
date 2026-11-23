# Fennec

Fennec is a fast file browser for macOS that you can drive from the keyboard.

- Split panes, with copy and move to the other pane.
- List and grid views, a preview pane, and Quick Look.
- Fuzzy file search with Cmd+F.
- Move to Trash with Put Back, including iCloud items.

Press Cmd+/ to see every keyboard shortcut.

## Install

Fennec needs macOS 15 or later on Apple silicon.

```sh
brew install --cask jigsmiths/tap/fennec
```

The app is not notarized. The cask removes the quarantine flag so macOS opens it.

## Build from source

You need Swift 6 and [just](https://github.com/casey/just).

```sh
just          # build, bundle, and open .build/Fennec.app
just test     # run the FennecCore tests
just bench    # time loading and painting a folder of 50,000 files
```

## Releases

Each push to `main` that passes CI can cut a release. The release workflow reads the Conventional Commit messages, tags the next version, uploads the zip to GitHub Releases, and updates the cask in `jigsmiths/homebrew-tap`.
