-- smart-splits-herdr.lua
--
-- A smart-splits.nvim v3 backend (protocol 3.0.0) that works in BOTH herdr
-- frontends, dispatched by environment:
--
--   herdr TUI    (HERDR_ENV=1)     → talks to the `herdr` CLI (socket-style fast
--                                    path is a TODO; CLI here matches the ported
--                                    v2 behaviour: focus / wrap / split-with-swap
--                                    / resize in split-fraction units).
--   herdr-app    (HC_TERMINAL_ID)  → talks to `herdr-app do` CLI: pane.go for
--                                    moves (verified against focused_pane in
--                                    `herdr-app status`), pane.split + pane.swap
--                                    for at_edge='split'. No resize: herdr-app
--                                    has no pane-level resize (layout.resize
--                                    needs a layout node id nvim can't know).
--
-- Required interface (PROTOCOL.md 3.0.0): name, protocol_version, detect, move.
-- Optional: resize, activate, health. Never throws; returns false when the
-- multiplexer did not handle it so core can apply at_edge.

local M = {
  name = 'smart-splits-herdr',
  protocol_version = '3.0.0',
}

M.config = {
  -- timeout for a single CLI call (ms); protocol: return promptly
  timeout = 300,
  -- refuse to move out of a zoomed herdr pane (TUI only)
  disable_nav_when_zoomed = true,
  -- cells to resize by when smart-splits passes no amount
  resize_amount = 3,
  -- safety bound for wrap-around walks
  max_wrap_steps = 32,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

--- Optional debug logging through core if it is around.
local function log_debug(fmt, ...)
  local ok, log = pcall(require, 'smart-splits.log')
  if ok then
    log.debug('smart-splits-herdr: ' .. fmt, ...)
  end
end

-- ---------------------------------------------------------------- helpers --

---@param cmd string[]
---@return table|nil parsed json of .result, nil on failure
local function cli_json(cmd)
  local obj = vim.system(cmd, { timeout = M.config.timeout }):wait()
  log_debug('cli: %s → %s', table.concat(cmd, ' '), obj.stdout)
  if obj.code ~= 0 or not obj.stdout or obj.stdout == '' then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, obj.stdout)
  if not ok or type(decoded) ~= 'table' then
    return nil
  end
  return decoded.result or decoded
end

local function binary(name)
  return vim.fn.executable(name) == 1 and vim.fn.exepath(name) or nil
end

-- ------------------------------------------------------------- dispatcher --

--- Which frontend are we in? Pure (env-only): 'tui' | 'app' | nil.
--- HERDR_ENV wins over HC_TERMINAL_ID: herdr TUI panes may also carry hc
--- variables; inside herdr the nvim→herdr-TUI path is the one that must fire.
---@return string|nil
function M.mode()
  if vim.env.HERDR_ENV == '1' then
    return 'tui'
  end
  if vim.env.HC_TERMINAL_ID ~= nil and vim.env.HC_TERMINAL_ID ~= '' then
    return 'app'
  end
  return nil
end

function M.detect()
  return M.mode() ~= nil
end

-- ------------------------------------------------------------ tui backend --

local function tui_is_zoomed()
  if not M.config.disable_nav_when_zoomed then
    return false
  end
  local layout = cli_json({ 'herdr', 'pane', 'layout', '--current' })
  if type(layout) ~= 'table' then
    return false
  end
  -- defensive: find any zoom-ish boolean true in the layout payload
  local function scan(tbl, depth)
    if depth > 4 or type(tbl) ~= 'table' then
      return false
    end
    for k, v in pairs(tbl) do
      if type(k) == 'string' and k:lower():find('zoom') and v == true then
        return true
      end
      if type(v) == 'table' and scan(v, depth + 1) then
        return true
      end
    end
    return false
  end
  return scan(layout, 0)
end

--- Focus the neighbor in `dir`. Returns ok, changed, reason.
---@return boolean ok
---@return boolean changed
---@return string|nil reason
local function tui_focus(dir)
  local res = cli_json({ 'herdr', 'pane', 'focus', '--direction', dir, '--current' })
  if type(res) ~= 'table' or res.focus == nil then
    return false, false, nil
  end
  return true, res.focus.changed == true, res.focus.reason
end

--- Walk neighbor ids without changing focus until the far edge in `dir`,
--- then focus that pane. This is the CLI-era wrap: it lands on the far edge,
--- which may not be strictly the same row/column in irregular layouts.
local function tui_wrap(dir)
  local pane = vim.env.HERDR_PANE_ID
  if pane == nil or pane == '' then
    return false
  end
  local far = pane
  for _ = 1, M.config.max_wrap_steps do
    local res = cli_json({ 'herdr', 'pane', 'neighbor', '--direction', dir, '--pane', far })
    local nid = type(res) == 'table' and res.neighbor
    nid = (type(nid) == 'table' and (nid.id or nid.pane_id or nid.pane)) or nil
    if nid == nil or nid == far then
      break
    end
    far = nid
  end
  if far == pane then
    return false
  end
  local res = cli_json({ 'herdr', 'pane', 'focus', '--pane', far })
  if type(res) ~= 'table' then
    return false
  end
  return res.focus == nil or res.focus.changed ~= false
end

--- at_edge='split'. herdr only splits right/down; left/up are split on the
--- opposite side and then swapped, so the new pane ends up on the wanted side
--- WITH focus (v2 mux port: split, then swap so the new pane lands on the wanted side).
---@return boolean
local function tui_split(dir)
  local opposite = { left = 'right', right = 'left', up = 'down', down = 'up' }
  local split_dir = dir
  local swap_after = nil
  if dir == 'left' or dir == 'up' then
    split_dir = opposite[dir]
    swap_after = opposite[dir]
  end
  local res = cli_json({ 'herdr', 'pane', 'split', '--current', '--direction', split_dir })
  if type(res) ~= 'table' then
    return false
  end
  if swap_after ~= nil then
    local swap = cli_json({ 'herdr', 'pane', 'swap', '--direction', swap_after, '--current' })
    if type(swap) ~= 'table' then
      -- split happened but the swap failed; focus is on the new pane anyway
      return true
    end
  end
  return true
end

--- herdr measures resize as a fraction of the split; smart-splits passes
--- cells. Convert: fraction = cells / (current nvim window size in cells) —
--- core only calls resize when the window fills that axis, so the nvim window
--- spans the herdr pane.
---@param dir string
---@param amount number|nil
---@return boolean
local function tui_resize(dir, amount)
  amount = amount or M.config.resize_amount
  local horizontal = dir == 'left' or dir == 'right'
  local win_size = horizontal and vim.fn.winwidth(0) or vim.fn.winheight(0)
  if win_size == 0 then
    return false
  end
  local fraction = amount / win_size
  local res = cli_json({
    'herdr', 'pane', 'resize', '--direction', dir, '--current', '--amount', tostring(fraction),
  })
  return type(res) == 'table'
end

-- ------------------------------------------------------------ app backend --

--- Returns focused_pane id or nil when herdr-app is unreachable.
---@return string|nil
local function app_focused()
  local res = cli_json({ 'herdr-app', 'status' })
  if type(res) ~= 'table' then
    return nil
  end
  return res.focused_pane
end

--- Move focus via pane.go, verified by focused_pane before/after
--- (pane.go prints nothing about whether it moved).
---@return boolean
local function app_go(dir)
  local before = app_focused()
  cli_json({ 'herdr-app', 'do', 'pane.go', '--direction', dir })
  local after = app_focused()
  if after == nil then
    return false
  end
  return before ~= nil and after ~= before
end

local function app_opposite(dir)
  return ({ left = 'right', right = 'left', up = 'down', down = 'up' })[dir]
end

--- Wrap by walking focus to the far edge in `dir` (pane.go until it stops
--- moving), which lands on the opposite edge of the pressed direction.
---@return boolean
local function app_wrap(dir)
  local before = app_focused()
  if before == nil then
    return false
  end
  for _ = 1, M.config.max_wrap_steps do
    if not app_go(dir) then
      break
    end
  end
  local far = app_focused()
  if far == nil then
    return false
  end
  if far == before then
    return false -- no walk happened at all
  end
  return true
end

--- herdr-app splits right/down; left/up = split opposite, then swap so the
--- new pane takes the wanted side carrying focus (pane.swap swaps the focused
--- pane with its neighbor, focus follows).
---@return boolean
local function app_split(dir)
  local opposite = app_opposite(dir)
  local split_dir = dir
  if dir == 'left' or dir == 'up' then
    split_dir = opposite
  end
  cli_json({ 'herdr-app', 'do', 'pane.split', '--direction', split_dir })
  if dir == 'left' or dir == 'up' then
    cli_json({ 'herdr-app', 'do', 'pane.swap', '--direction', opposite })
  end
  return true
end

-- ------------------------------------------------- protocol entry points --

---@param direction string 'left'|'right'|'up'|'down'
---@param opts table|nil {at_edge: 'stop'|'wrap'|'split'|nil}
---@return boolean
function M.move(direction, opts)
  opts = opts or {}
  local mode = M.mode()
  log_debug('move(%s, %s) mode=%s', direction, vim.inspect(opts), mode)
  if mode == 'tui' then
    if tui_is_zoomed() then
      return false
    end
    local ok, changed, reason = tui_focus(direction)
    if not ok then
      return false -- server unreachable
    end
    log_debug('tui focus: ok changed=%s reason=%s', changed, reason)
    if changed then
      return true
    end
    if reason ~= 'no_neighbor' then
      return changed
    end
    if opts.at_edge == 'wrap' then
      return tui_wrap(direction)
    elseif opts.at_edge == 'split' then
      return tui_split(direction)
    end
    return false
  end

  if mode == 'app' then
    if app_focused() == nil then
      return false -- herdr-app unreachable
    end
    if app_go(direction) then
      return true
    end
    if opts.at_edge == 'wrap' then
      return app_wrap(direction)
    elseif opts.at_edge == 'split' then
      return app_split(direction)
    end
    return false
  end

  return false
end

---@param direction string
---@param opts table|nil {amount: number|nil}
---@return boolean
function M.resize(direction, opts)
  if M.mode() ~= 'tui' then
    -- herdr-app has no pane-level resize (layout.resize needs a layout node
    -- id that nvim cannot know): leave the capability absent in that world.
    -- Core asked, which only happens when the nvim window fills the axis;
    -- doing nothing is better than corrupting a layout.
    return false
  end
  if tui_is_zoomed() then
    return false
  end
  local amount = (opts and opts.amount) or nil
  return tui_resize(direction, amount)
end

function M.activate() end -- no pane markers needed: the shim keys off
                         -- the focused pane's foreground process name

function M.health()
  local mode = M.mode()
  if mode == nil then
    vim.health.info('not inside herdr or herdr-app (no HERDR_ENV=1, no HC_TERMINAL_ID)')
    return
  end
  local herdr_bin = binary('herdr')
  if herdr_bin then
    vim.health.ok('herdr CLI: ' .. herdr_bin)
  else
    vim.health.error('herdr CLI not on PATH')
  end
  if mode == 'tui' then
    if vim.env.HERDR_PANE_ID ~= nil and vim.env.HERDR_PANE_ID ~= '' then
      vim.health.ok('HERDR_PANE_ID=' .. vim.env.HERDR_PANE_ID)
    else
      vim.health.warn('HERDR_PANE_ID is not set; wrap/split may degrade')
    end
    local path = vim.env.HERDR_SOCKET_PATH
    if path and path ~= '' then
      vim.health.info('HERDR_SOCKET_PATH=' .. path)
    end
  end
  if mode == 'app' then
    local hc = binary('herdr-app')
    if hc then
      vim.health.ok('herdr-app CLI: ' .. hc)
    else
      vim.health.error('herdr-app CLI not on PATH')
    end
    if app_focused() then
      vim.health.ok('herdr-app window reachable (status → focused_pane)')
    else
      vim.health.error('herdr-app status did not respond; open the window')
    end
    vim.health.info('resize is not supported under herdr-app (no pane-level resize in its CLI)')
  end
  vim.health.info('herdr-side keybinds are plugin_action → smart-splits-herdr.<left|down|up|right>')
end

return M
