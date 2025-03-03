local api = vim.api
local curl = require("plenary.curl")
local ns_id = api.nvim_create_namespace("wingman")

-- Configuration
local config = {
  useOllama = false,                            -- Set to true for Ollama, false for Grok
  ollama_url = "http://localhost:11434/api/generate", -- Ollama endpoint
  grok_url = "https://api.x.ai/v1/chat/completions", -- Grok endpoint
  api_key = "",
  model = "grok-2-latest",                      -- Model (e.g., "llama3.2" for Ollama)
  show_suggestions = true,                      -- Toggle suggestions on/off
  auto_trigger = true,                          -- Enable automatic completion
  trigger_threshold = 3,                        -- Min characters to trigger completion
  temperature = 0.7,                            -- Controls creativity (lower for less repetition)
  max_tokens = 300,                             -- Limits output length
  keymaps = { accept = "<Tab>" },               -- Only <Tab> to accept suggestions
}

-- State Management
local state = {
  suggestion_text = nil,                        -- Current suggestion text
  suggestion_virt_text_id = nil,                -- ID of virtual text
  timer = nil,                                 -- Debounce timer
  prompt_in_progress = false,                  -- Prevent concurrent requests
  latest_request_id = 0,                       -- Track latest request
}

-- Clear Current Suggestion
local function clear_suggestion()
  if state.suggestion_virt_text_id then
    pcall(api.nvim_buf_del_extmark, 0, ns_id, state.suggestion_virt_text_id)
    state.suggestion_virt_text_id = nil
  end
  state.suggestion_text = nil
end

-- Show Suggestion as Virtual Text
local function show_suggestion(text, line, col, request_id)
  if request_id ~= state.latest_request_id then return end
  clear_suggestion()
  if not text or text == "" then return end

  vim.schedule(function()
    local cursor = api.nvim_win_get_cursor(0)
    if cursor[1] ~= line then return end

    local current_line = api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
    local clamped_col = math.min(col, #current_line)
    state.suggestion_text = text

    local lines = vim.split(text, "\n", { trimempty = true })
    if #lines == 0 then return end

    local virt_text = { { lines[1], "Comment" } }
    local virt_lines = {}
    for i = 2, #lines do
      table.insert(virt_lines, { { lines[i], "Comment" } })
    end

    state.suggestion_virt_text_id = api.nvim_buf_set_extmark(0, ns_id, line - 1, clamped_col, {
      virt_text = virt_text,
      virt_text_pos = "overlay",
      virt_lines = virt_lines,
      invalidate = true,
    })
  end)
end

-- Get Context Around Cursor
local function get_context()
  local cursor = api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local col = cursor[2]
  local current_line = api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
  col = math.min(col, #current_line)
  local start_line = math.max(1, line - 10)
  local prev_lines = api.nvim_buf_get_lines(0, start_line - 1, line - 1, false)
  local context = table.concat(prev_lines, "\n")
  if #context > 0 then context = context .. "\n" end
  context = context .. string.sub(current_line, 1, col)
  return context, line, col
end

-- Request Completion from API
local function request_completion()
  if not config.show_suggestions or state.prompt_in_progress then return end

  state.latest_request_id = state.latest_request_id + 1
  local request_id = state.latest_request_id

  local context, line, col = get_context()
  if #context < config.trigger_threshold then return end

  local filetype = vim.bo.filetype
  local system_prompt = "You are a coding assistant. Your task is to provide code completions that continue the given snippet without repeating the existing code."
  local user_prompt = "Continue this " .. filetype .. " snippet starting from where it ends. Do not repeat any of the existing code. Only provide the new code that follows:\n```\n" .. context .. "\n```"

  state.prompt_in_progress = true
  local url = config.useOllama and config.ollama_url or config.grok_url
  local body
  if config.useOllama then
    body = vim.json.encode({
      model = config.model,
      prompt = system_prompt .. "\n" .. user_prompt,
      temperature = config.temperature,
      num_predict = config.max_tokens,  -- Ollama's equivalent of max_tokens
      stream = false,
    })
  else
    body = vim.json.encode({
      model = config.model,
      messages = {
        { role = "system", content = system_prompt },
        { role = "user", content = user_prompt },
      },
      temperature = config.temperature,
      max_tokens = config.max_tokens,
      stream = false,
    })
  end

  local headers = { ["Content-Type"] = "application/json" }
  if not config.useOllama then
    headers["Authorization"] = "Bearer " .. config.api_key
  end

  curl.post({
    url = url,
    body = body,
    headers = headers,
    callback = function(response)
      state.prompt_in_progress = false
      if response.status ~= 200 then
        vim.schedule(function()
          vim.notify("Wingman: Error - Status: " .. response.status, vim.log.levels.ERROR)
        end)
        return
      end

      local success, result = pcall(vim.json.decode, response.body)
      if not success then
        vim.schedule(function()
          vim.notify("Wingman: JSON error: " .. tostring(result), vim.log.levels.ERROR)
        end)
        return
      end

      local suggestion = config.useOllama and result.response or (
        result.choices and result.choices[1].message.content
      )
      if suggestion then
        suggestion = suggestion:gsub("^```[%w]*\n", ""):gsub("\n```$", "")
        show_suggestion(suggestion, line, col, request_id)
      end
    end,
  })
end

-- Accept Suggestion and Insert into Buffer
local function accept_suggestion()
  if not state.suggestion_text then return end

  local cursor = api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local col = cursor[2]
  local lines = vim.split(state.suggestion_text, "\n", { plain = true })
  api.nvim_buf_set_text(0, line - 1, col, line - 1, col, lines)

  local new_pos = #lines == 1 and { line, col + #lines[1] } or
                  { line + #lines - 1, #lines[#lines] }
  api.nvim_win_set_cursor(0, new_pos)
  clear_suggestion()
end

-- Setup Autocommands and Keymaps
local function setup()
  local group = api.nvim_create_augroup("Wingman", { clear = true })

  if config.auto_trigger then
    api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
      group = group,
      callback = function()
        clear_suggestion()
        if state.timer then
          state.timer:stop()
          state.timer:close()
        end
        state.timer = vim.loop.new_timer()
        state.timer:start(2000, 0, vim.schedule_wrap(function()
          if vim.fn.mode() == "i" then request_completion() end
        end))
      end,
    })
    api.nvim_create_autocmd({ "CursorMovedI", "InsertLeave" }, {
      group = group,
      callback = clear_suggestion,
    })
  end

  vim.keymap.set("i", config.keymaps.accept, function()
    if state.suggestion_text then
      vim.schedule(accept_suggestion)
      return ""
    end
    return config.keymaps.accept
  end, { expr = true })
end

-- Run setup when the plugin loads
setup()

-- User Commands
api.nvim_create_user_command("WingmanToggle", function()
  config.show_suggestions = not config.show_suggestions
  print("Wingman suggestions " .. (config.show_suggestions and "enabled" or "disabled"))
end, {})

api.nvim_create_user_command("WingmanComplete", request_completion, {})