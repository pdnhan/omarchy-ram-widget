# Omarchy RAM Widget

A RAM usage bar widget for [Omarchy](https://omarchy.org)'s Quickshell-based
bar (`omarchy-shell`). Shows current memory usage as a percentage pill in the
bar, with a popup for details and quick actions.

## What it does

- **Bar pill**: shows RAM usage as a percentage (or a plain icon in a
  vertical bar), turning to the theme's urgent color at 90% usage.
- **Left click** opens a popup with:
  - Used / Available / Cache / Swap breakdown (read from `/proc/meminfo`).
  - An **OLLAMA** section listing any models currently loaded by a local
    [Ollama](https://ollama.com) server (`http://127.0.0.1:11434/api/ps`),
    each with an **Unload** button that evicts it immediately (equivalent to
    `ollama stop <model>`). This section only appears if Ollama is reachable
    on localhost — if it isn't running, the section is hidden.
  - A **Clear RAM** button that syncs, drops the page cache
    (`/proc/sys/vm/drop_caches`), and compacts memory
    (`/proc/sys/vm/compact_memory`) via a small root helper script run
    through `pkexec`.

  **Important:** Clear RAM only drops the page cache. It does **not** free
  memory actually held by running processes, and it does **not** free
  GPU/GTT-backed allocations — for example a model an inference server (like
  Ollama) is still keeping loaded. To free that memory, unload the model
  first (see above), then use Clear RAM if you also want to drop cached
  pages.
  - A **DISK** section with total / used / free and a usage bar for the root
    filesystem (and `/home` if it is a separate filesystem), refreshed every
    minute and whenever the popup opens.
  - A **Show cleanup candidates** button that runs the read-only `scan-disk`
    helper in the background (at idle CPU/IO priority) and lists:
    - **Cache / temp**: sizes of `~/.cache` and its biggest subdirectories,
      `/tmp` (your files), `~/.local/share/Trash`, the pacman cache, yay/paru,
      npm, cargo registry and pip caches, and the systemd journal — only those
      that exist.
    - **Large files**: the 15 largest files over 500 MB in `$HOME` (Steam
      libraries excluded).

    Nothing is ever deleted. **Click an entry** to open a terminal in that
    directory (or in the file's parent directory).
- **Right click** opens `btop` in a floating terminal.

## Requirements

- [Omarchy](https://omarchy.org) with the Quickshell-based `omarchy-shell`
  bar (the one that supports `omarchy plugin add`).
- `df`, `du`, `find`, `ionice` (coreutils / util-linux / findutils) for the
  disk section and scan.
- `xdg-terminal-exec` and `uwsm-app` (shipped with Omarchy) to open a terminal
  from a cleanup candidate.
- `curl` (used to query Ollama and to unload models).
- `pkexec` / polkit (used to authorize the Clear RAM helper).
- [Ollama](https://ollama.com) is optional — the OLLAMA section simply
  doesn't render if nothing is listening on `127.0.0.1:11434`.

## Install

```bash
omarchy plugin add https://github.com/pdnhan/omarchy-ram-widget.git
omarchy bar move pdnhan.ram --section right
```

(`--section right` matches this widget's default placement; use `left` or
`center` if you'd rather put it elsewhere.)

## Uninstall

```bash
omarchy plugin remove pdnhan.ram
```

## Interactions

| Action | Result |
| --- | --- |
| Left click | Open the popup (usage breakdown, Ollama models, Clear RAM, disk usage) |
| Click "Show cleanup candidates" | Scan for caches and large files (read-only), toggle the list |
| Click a cleanup entry | Open a terminal in that directory (file: its parent) and close the popup |
| Right click | Open `btop` |
| Enter (while popup is focused) | Run Clear RAM |

## Notes

- After editing the plugin's code, `omarchy restart shell` may be required —
  hot-reload doesn't always swap the running Quickshell instance cleanly.
- The Clear RAM helper (`clear-ram`) requires root and is invoked through
  `pkexec`, so you'll be prompted for authorization each time you use it.
