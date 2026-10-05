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
- **Right click** opens `btop` in a floating terminal.

## Requirements

- [Omarchy](https://omarchy.org) with the Quickshell-based `omarchy-shell`
  bar (the one that supports `omarchy plugin add`).
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
| Left click | Open the popup (usage breakdown, Ollama models, Clear RAM) |
| Right click | Open `btop` |
| Enter (while popup is focused) | Run Clear RAM |

## Notes

- After editing the plugin's code, `omarchy restart shell` may be required —
  hot-reload doesn't always swap the running Quickshell instance cleanly.
- The Clear RAM helper (`clear-ram`) requires root and is invoked through
  `pkexec`, so you'll be prompted for authorization each time you use it.
