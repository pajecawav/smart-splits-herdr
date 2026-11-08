# smart-splits-herdr

A hand-rolled [smart-splits.nvim](https://github.com/smart-splits-nvim/smart-splits.nvim)
backend (protocol 3.0.0) for both herdr frontends, dispatched by environment
variable, **plus** the herdr-side key shim so one `ctrl+hjkl` family navigates
Neovim splits and herdr panes alike.

```
lua/smart-splits-herdr.lua     ← the nvim-side plugin (the backend)
herdr-plugin.toml              ← the herdr-side shim manifest
scripts/herdr-navigate.sh      ← the herdr-side shim (from smart-splits v2,
                                  body unchanged; needs bash + jq)
```

## Which frontend, how it decides

| environment | frontend | transport | move | resize |
|---|---|---|---|---|
| `HERDR_ENV=1` | herdr TUI 0.9.5 | `herdr` CLI | `pane focus --direction` (+ `neighbor`-chain wrap, split-with-swap) | `pane resize` (cells → split fraction) |
| `HC_TERMINAL_ID` | herdr-app | `herdr-app do` CLI | `pane.go` + focused_pane verified against `herdr-app status`; wrap = focus-walk to the far edge, split = `pane.split` (+ `pane.swap` for left/up) | none (no pane-level resize in herdr-app) |

`HERDR_ENV` wins when both are set (herdr TUI panes may also carry hc
variables). Outside any of them the backend is not detected and
smart-splits.nvim behaves as plain Neovim.

## nvim side

```lua
{
  "smart-splits-nvim/smart-splits.nvim",
  version = "v3.0.0",
  dependencies = {
    { dir = "~/code/smart-splits-herdr", name = "smart-splits-herdr", opts = {} },
  },
  opts = { mux = { backend = "smart-splits-herdr", warn_if_unusable = false } },
}
```

Publishing this repo would let `dir =` become `"<user>/smart-splits-herdr"`;
the module name (`smart-splits-herdr`) deliberately does not collide with the
community backend `adriankarlen/smart-splits-backend-herdr` (which covers the
herdr TUI only).

Verify without touching multiplexers:

```lua
:lua print(table.concat(require('smart-splits.protocol_tests').run(require('smart-splits-herdr')), '\n'))
```

## herdr side

```sh
herdr plugin link ~/code/smart-splits-herdr      # or: herdr plugin install <user>/smart-splits-herdr
herdr server reload-config
```

`config.toml`:

```toml
[[keys.command]]
key = "ctrl+h"
type = "plugin_action"
command = "smart-splits-herdr.left"
# ... ctrl+j → .down, ctrl+k → .up, ctrl+l → .right
```

Per keypress, the shim: 1) focused pane runs Vim/Neovim (`herdr pane
process-info`) → forwards the key into it (the nvim backend takes over at
Neovim's edges); 2) otherwise moves herdr focus if a neighbor exists; 3) if
there is no neighbor, sends the key back to the pane (shell `C-l` = clear and
`C-h` = backspace keep working). Programs that own `ctrl+hjkl` themselves can
be listed in `SMART_SPLITS_HERDR_PASSTHROUGH_RE` (herdr environment).

## herdr-app half only (no shim), keys.json

`ctrl-h/j/k/l` are bound to `pane.go` and the interception is unconditional
(herdr-app had no conditional bindings as of 0.1.13): inside nvim, vim-internal
split navigation goes through `ctrl+w hjkl`. Known herdr-app gaps, candidates
for issues there: conditional `plugin_action`-style dispatch, pane-level
resize.

## Gotchas baked into the code

- Do not `await` anything between `closeOverlay(launcher)` and
  `openOverlay(dialog)` in a launcher mod: closing the launcher's dialog tears
  the whole mod instance down, mid-await included. The working order is
  close launcher → open dialog (the dialog keeps the keyboard this way);
  opening over a still-open launcher leaves the keyboard on the launcher.
- `pane.focus {terminal}` on a paneless overlay terminal fails with
  "no such pane" (mac session §7.1; still true in 0.1.13 on Linux) — the
  dialog's terminal takes the keyboard on its own.
- An `overlay` whose layout is a terminal block closes itself when that
  terminal ends — which is what closes the lazygit popup (its `hc` terminal
  outlives the window but ends with the program).
- `terminals()` may not include a just-spawned address yet; re-checking
  freshness right after `hc run --bg` flags a live worker as dead.
