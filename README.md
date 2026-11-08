# smart-splits-herdr

A smart-splits.nvim backend (protocol 3.0.0) for both herdr frontends, plus
the herdr-side key shim, so one `ctrl+hjkl` family navigates Neovim splits and
herdr panes. The community backend
[`smart-splits-backend-herdr`](https://github.com/adriankarlen/smart-splits-backend-herdr)
covers the herdr TUI only; this one adds herdr-app and ships the shim.

Repository contents:

```
lua/smart-splits-herdr.lua     nvim side: the backend
herdr-plugin.toml              herdr side: the shim manifest
scripts/herdr-navigate.sh      herdr side: the shim script, copied from
                               smart-splits v2.1.1-final (needs bash and jq)
```

## How the backend picks its frontend

| environment | frontend | moves and edges | resize |
|---|---|---|---|
| `HERDR_ENV=1` | herdr TUI | `herdr pane focus --direction`; with no neighbor, wrap walks the `pane neighbor` chain first, split uses `pane split` and then `pane swap` for left and up | `pane resize`, with cell counts converted to split fractions |
| `HC_TERMINAL_ID` | herdr-app | `herdr-app do pane.go`, checked against `focused_pane` in `herdr-app status`; wrap walks focus to the far edge; split uses `pane.split`, then `pane.swap` for left and up | none: herdr-app only resizes layout nodes |

`HERDR_ENV` wins when both are set, because herdr TUI panes may also carry hc
variables. With neither variable set, the backend is not detected and
smart-splits.nvim behaves as plain Neovim.

## Neovim side

```lua
{
  "smart-splits-nvim/smart-splits.nvim",
  version = "v3.0.0",
  dependencies = {
    { "pajecawav/smart-splits-herdr", version = "v0.2.0", opts = {} },
  },
  opts = { mux = { backend = "smart-splits-herdr", warn_if_unusable = false } },
}
```

Protocol conformance tests run without a multiplexer:

```lua
:lua print(table.concat(require('smart-splits.protocol_tests').run(require('smart-splits-herdr')), '\n'))
```

## herdr TUI side

```sh
herdr plugin install pajecawav/smart-splits-herdr --yes   # --yes for non-interactive shells
herdr server reload-config
# local dev variant: herdr plugin link ~/code/smart-splits-herdr
```

Bind the actions in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "ctrl+h"
type = "plugin_action"
command = "smart-splits-herdr.left"
# ctrl+j → .down, ctrl+k → .up, ctrl+l → .right
```

On each keypress the shim checks the focused pane's foreground process with
`herdr pane process-info`:

1. Vim or Neovim in focus: the key goes into the pane, and the nvim backend
   takes over at Neovim's edges.
2. Any other program: herdr moves focus if a neighbor exists in that
   direction.
3. No neighbor: the key returns to the pane, so shell `C-l` still clears and
   `C-h` still backspaces.

Programs that own `ctrl+hjkl` themselves can join case 1 by setting
`SMART_SPLITS_HERDR_PASSTHROUGH_RE` in herdr's environment.

## herdr-app without the shim

`ctrl-h/j/k/l` bound to `pane.go` intercept unconditionally, because herdr-app
0.1.13 has no conditional bindings. Inside nvim, vim-internal split navigation
goes through `ctrl+w hjkl`. Two herdr-app gaps are worth filing as issues:
a conditional `plugin_action` equivalent for key bindings, and pane-level
resize (`layout.resize` takes a layout node id, which nvim cannot know).

## herdr-app mod gotchas (from porting the lazygit popup)

- Closing a launcher mod's dialog tears down the whole mod instance, mid-await
  included. Prepare everything, then close the launcher and open the dialog in
  the same synchronous block. Opening over the still-open launcher leaves the
  keyboard on the launcher.
- `pane.focus {terminal}` fails with `no such pane` for paneless overlay
  terminals, on macOS 0.1.12 and Linux 0.1.13 alike. The dialog's terminal
  takes the keyboard on its own once the launcher is closed.
- An overlay whose layout holds a terminal block closes itself when that
  terminal ends. That is what closes the lazygit popup: its `hc` terminal
  outlives the window but ends with the program.
- `terminals()` may not include a just-spawned address yet. Checking freshness
  right after `hc run --bg` reports a live worker as dead.
