-- Suppress warnings about private methods of lsp.Client.
---@diagnostic disable: invisible

local util = require('vscoq.util')
local render = require('vscoq.render')

---@class VSCoqNvim
---@field lc lsp.Client
---@field vscoq vscoq.Config the current configuration
-- TODO: Since proofView notification doesn't send which document it is for,
-- for now we have a single proofview panel.
-- Once fixed, make config for single/multi proofview.
-- ---@field buffers table<buffer, { proofview_bufnr: buffer }>
---@field buffers table<buffer, true>
---@field proofview_panel buffer
---@field query_panel buffer
---@field query_id integer latest query id. Only the latest query result is displayed.
---@field debounce_timer uv_timer_t
---@field highlight_ns integer
---@field ag integer
local VSCoqNvim = {}
VSCoqNvim.__index = VSCoqNvim

---@type string[] command names
local commands = {}

---@param client lsp.Client
---@return VSCoqNvim
function VSCoqNvim:new(client)
  ---@type VSCoqNvim
  local new = {
    lc = client,
    vscoq = vim.deepcopy(client.config.init_options),
    buffers = {},
    proofview_panel = -1,
    query_panel = -1,
    query_id = 0,
    debounce_timer = assert(vim.loop.new_timer(), 'Could not create timer'),
    highlight_ns = vim.api.nvim_create_namespace('vscoq-progress-' .. client.id),
    ag = vim.api.nvim_create_augroup('vscoq-' .. client.id, { clear = true }),
  }
  setmetatable(new, self)
  new:ensure_proofview_panel()
  new:ensure_query_panel()
  return new
end

---change config and send notification
---@param new_config vscoq.Config
function VSCoqNvim:update_config(new_config)
  self.vscoq = vim.tbl_deep_extend('force', self.vscoq, new_config)
  self.lc.notify('workspace/didChangeConfiguration', { settings = self.vscoq })
end

function VSCoqNvim:manual()
  self:update_config { proof = { mode = 0 } }
end
function VSCoqNvim:continuous()
  self:update_config { proof = { mode = 1 } }
  self:interpretToPoint()
end
commands[#commands + 1] = 'manual'
commands[#commands + 1] = 'continuous'

---@param highlights vscoq.UpdateHighlightsNotification
function VSCoqNvim:updateHighlights(highlights)
  local bufnr = vim.uri_to_bufnr(highlights.uri)
  vim.api.nvim_buf_clear_namespace(bufnr, self.highlight_ns, 0, -1)
  -- for _, range in ipairs(highlights.processingRange) do
  for _, range in ipairs(highlights.processedRange) do
    vim.highlight.range(
      bufnr,
      self.highlight_ns,
      'CoqtailChecked',
      util.position_lsp_to_api(bufnr, range['start'], self.lc.offset_encoding),
      util.position_lsp_to_api(bufnr, range['end'], self.lc.offset_encoding),
      { priority = vim.highlight.priorities.user + 1 }
    )
  end
end

---@param target vscoq.MoveCursorNotification
function VSCoqNvim:moveCursor(target)
  local bufnr = vim.uri_to_bufnr(target.uri)
  local wins = vim.fn.win_findbuf(bufnr) or {}
  if self.vscoq.proof.mode == 0 and self.vscoq.proof.cursor.sticky then
    local position = util.position_api_to_mark(
      util.position_lsp_to_api(bufnr, target.range['end'], self.lc.offset_encoding)
    )
    for _, win in ipairs(wins) do
      vim.api.nvim_win_set_cursor(win, position)
    end
  end
end

---@param proofView vscoq.ProofViewNotification
function VSCoqNvim:proofView(proofView)
  self:ensure_proofview_panel()

  -- TODO: smarter view? relative position?
  local wins = {} ---@type table<window, vim.fn.winsaveview.ret>
  for _, win in ipairs(vim.fn.win_findbuf(self.proofview_panel) or {}) do
    vim.api.nvim_win_call(win, function()
      wins[win] = vim.fn.winsaveview()
    end)
  end

  local lines = render.ProofView(proofView)
  vim.api.nvim_buf_set_lines(self.proofview_panel, 0, -1, false, lines)

  for win, view in pairs(wins) do
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
  end
end

-- TODO: commands in panels
function VSCoqNvim:ensure_proofview_panel()
  if vim.api.nvim_buf_is_valid(self.proofview_panel) then
    if not vim.api.nvim_buf_is_loaded(self.proofview_panel) then
      vim.fn.bufload(self.proofview_panel)
    end
    return
  end
  self.proofview_panel = vim.api.nvim_create_buf(false, true)
  vim.bo[self.proofview_panel].filetype = 'coq-goals'
end

function VSCoqNvim:ensure_query_panel()
  if vim.api.nvim_buf_is_valid(self.query_panel) then
    if not vim.api.nvim_buf_is_loaded(self.query_panel) then
      vim.fn.bufload(self.query_panel)
    end
    return
  end
  self.query_panel = vim.api.nvim_create_buf(false, true)
  vim.bo[self.query_panel].filetype = 'coq-infos'
end

function VSCoqNvim:panels()
  self:ensure_proofview_panel()
  self:ensure_query_panel()
  local win = vim.api.nvim_get_current_win()

  if vim.fn.bufwinid(self.proofview_panel) == -1 then
    vim.cmd.sbuffer {
      args = { self.proofview_panel },
      -- See `:h nvim_parse_cmd`. Note that the "split size" is `range`.
      mods = { keepjumps = true, keepalt = true, vertical = true, split = 'belowright' },
    }
    vim.cmd.clearjumps()
  end

  if vim.fn.bufwinid(self.query_panel) == -1 then
    vim.api.nvim_set_current_win(assert(vim.fn.bufwinid(self.proofview_panel)))
    vim.cmd.sbuffer {
      args = { self.query_panel },
      mods = { keepjumps = true, keepalt = true, split = 'belowright' },
    }
    vim.cmd.clearjumps()
  end

  vim.api.nvim_set_current_win(win)
end

commands[#commands + 1] = 'panels'

---@param bufnr? buffer
---@param position? MarkPosition
function VSCoqNvim:interpretToPoint(bufnr, position)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  position = position or util.guess_position(bufnr)
  local params = {
    textDocument = util.make_versioned_text_document_params(bufnr),
    position = util.make_position_params(bufnr, position, self.lc.offset_encoding),
  }
  return self.lc.notify('vscoq/interpretToPoint', params)
end
commands[#commands + 1] = 'interpretToPoint'

---@param method "vscoq/stepForward"|"vscoq/stepBackward"|"vscoq/interpretToEnd"
---@param bufnr? buffer
function VSCoqNvim:step(method, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local params = { textDocument = util.make_versioned_text_document_params(bufnr) }
  return self.lc.notify(method, params)
end

function VSCoqNvim:stepForward()
  return self:step('vscoq/stepForward')
end
function VSCoqNvim:stepBackward()
  return self:step('vscoq/stepBackward')
end
function VSCoqNvim:interpretToEnd()
  return self:step('vscoq/interpretToEnd')
end
commands[#commands + 1] = 'stepForward'
commands[#commands + 1] = 'stepBackward'
commands[#commands + 1] = 'interpretToEnd'

---@param pattern string
---@param bufnr? buffer
---@param position? MarkPosition
function VSCoqNvim:search(pattern, bufnr, position)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  position = position or util.guess_position(bufnr)
  self.query_id = self.query_id + 1
  ---@type vscoq.SearchCoqRequest
  local params = {
    id = tostring(self.query_id),
    textDocument = util.make_versioned_text_document_params(bufnr),
    position = util.make_position_params(bufnr, position, self.lc.offset_encoding),
    pattern = pattern,
  }
  util.request_async(self.lc, bufnr, 'vscoq/search', params, function(err)
    if err then
      vim.notify(
        ('[vscoq.nvim] vscoq/search error:\nparam:\n%s\nerror:%s\n'):format(
          vim.inspect(params),
          vim.inspect(err)
        ),
        vim.log.levels.ERROR
      )
      return
    end
    self:ensure_query_panel()
    -- :h undo-break
    vim.bo[self.query_panel].undolevels = vim.bo[self.query_panel].undolevels
    vim.api.nvim_buf_set_lines(self.query_panel, 0, -1, false, {})
  end)
end
commands[#commands + 1] = 'search'

---@param result vscoq.SearchCoqResult
function VSCoqNvim:searchResult(result)
  if tonumber(result.id) < self.query_id then
    return
  end
  -- Each notification sends a single item.
  local lines = render.searchCoqResult(result)
  self:ensure_query_panel()
  vim.api.nvim_buf_set_lines(self.query_panel, -1, -1, false, lines)
end

---@param method "vscoq/about"|"vscoq/check"|"vscoq/print"|"vscoq/locate"
---@param pattern string
---@param bufnr? buffer
---@param position? MarkPosition
function VSCoqNvim:simple_query(method, pattern, bufnr, position)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  position = position or util.guess_position(bufnr)
  self.query_id = self.query_id + 1
  ---@type vscoq.SimpleCoqRequest
  local params = {
    textDocument = util.make_versioned_text_document_params(bufnr),
    position = util.make_position_params(bufnr, position, self.lc.offset_encoding),
    pattern = pattern,
  }
  util.request_async(
    self.lc,
    bufnr,
    method,
    params,
    ---@param result vscoq.PpString
    function(err, result)
      if err then
        vim.notify(
          ('[vscoq.nvim] %s error:\nparam:\n%s\nerror:%s\n'):format(
            method,
            vim.inspect(params),
            vim.inspect(err)
          ),
          vim.log.levels.ERROR
        )
        return
      end
      self:ensure_query_panel()
      local lines = {}
      vim.list_extend(lines, vim.split(render.PpString(result), '\n'))
      -- :h undo-break
      vim.bo[self.query_panel].undolevels = vim.bo[self.query_panel].undolevels
      vim.api.nvim_buf_set_lines(self.query_panel, 0, -1, false, lines)
    end
  )
end

function VSCoqNvim:about(pattern)
  self:simple_query('vscoq/about', pattern)
end
function VSCoqNvim:check(pattern)
  self:simple_query('vscoq/check', pattern)
end
function VSCoqNvim:print(pattern)
  self:simple_query('vscoq/print', pattern)
end
function VSCoqNvim:locate(pattern)
  self:simple_query('vscoq/locate', pattern)
end
commands[#commands + 1] = 'about'
commands[#commands + 1] = 'check'
commands[#commands + 1] = 'print'
commands[#commands + 1] = 'locate'

---@param bufnr? buffer
function VSCoqNvim:resetCoq(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  ---@type vscoq.ResetCoqRequest
  local params = {
    textDocument = util.make_versioned_text_document_params(bufnr),
  }
  util.request_async(self.lc, bufnr, 'vscoq/resetCoq', params, function(err)
    if err then
      vim.notify(
        ('[vscoq.nvim] resetCoq error:\nparam:\n%s\nerror:%s\n'):format(
          vim.inspect(params),
          vim.inspect(err)
        ),
        vim.log.levels.ERROR
      )
      return
    end
    vim.api.nvim_buf_set_lines(self.proofview_panel, 0, -1, false, {})
  end)
end
commands[#commands + 1] = 'resetCoq'

function VSCoqNvim:on_CursorMoved()
  if self.vscoq.proof.mode == 1 then
    -- TODO: debounce_timer
    assert(self:interpretToPoint())
  end
end

---@param bufnr buffer
function VSCoqNvim:detach(bufnr)
  assert(self.buffers[bufnr])
  vim.api.nvim_buf_clear_namespace(bufnr, self.highlight_ns, 0, -1)
  vim.api.nvim_clear_autocmds { group = self.ag, buffer = bufnr }
  vim.api.nvim_buf_del_user_command(bufnr, 'VsCoq')
  self.buffers[bufnr] = nil
end

---@param bufnr buffer
function VSCoqNvim:attach(bufnr)
  assert(self.buffers[bufnr] == nil)
  self.buffers[bufnr] = true

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = self.ag,
    buffer = bufnr,
    callback = function()
      self:on_CursorMoved()
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'LspDetach' }, {
    group = self.ag,
    buffer = bufnr,
    desc = 'Unregister deleted/detached buffer',
    callback = function(ev)
      self:detach(ev.buf)
    end,
  })

  vim.api.nvim_buf_create_user_command(bufnr, 'VsCoq', function(opts)
    self:command(opts.args)
  end, {
    bang = true,
    nargs = 1,
    complete = function(arglead, _, _)
      return vim.tbl_filter(function(command)
        return command:find(arglead) ~= nil
      end, commands)
    end,
  })

  if self.vscoq.proof.mode == 1 then
    self:interpretToPoint(bufnr)
  end
end

---@param args string
function VSCoqNvim:command(args)
  local _, to, subcommand = args:find('(%w+)%s*')
  if not vim.tbl_contains(commands, subcommand) then
    error(('"%s" is not a valid VsCoq command'):format(subcommand))
  end
  args = args:sub(to + 1)
  -- TODO: check validity of args? maybe add some spec to commands
  VSCoqNvim[subcommand](self, #args > 0 and args or nil)
end

function VSCoqNvim:on_exit()
  self.debounce_timer:stop()
  self.debounce_timer:close()
  for bufnr, _ in pairs(self.buffers) do
    self:detach(bufnr)
  end
  vim.api.nvim_buf_delete(self.proofview_panel, { force = true })
  vim.api.nvim_buf_delete(self.query_panel, { force = true })
  vim.api.nvim_clear_autocmds { group = self.ag }
end

return VSCoqNvim
