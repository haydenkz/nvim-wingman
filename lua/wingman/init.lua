local M = {
}

-- Default configuration
M.config = {
  useOllama = false,
  ollama_url = "http://localhost:11434/api/generate",
  grok_url = "https://api.x.ai/v1/chat/completions",
  api_key = "",
  model = "grok-2-latest",
  show_suggestions = true,
  auto_trigger = true,
  trigger_threshold = 3,
  temperature = 0.7,
  max_tokens = 1000,
  keymaps = { accept = "<Tab>" },
}

-- State management 
local state = {
  suggestion_text = nil,
  suggestion_virt_text_id = nil,
  timer = nil,
  prompt_in_progress = false,
  latest_request_id = 0,
}

local ns_id = vim.api.nvim_create_namespace("wingman")

-- clear_suggestion() and show_suggestion()
local function clear_suggestion()
  if state.suggestion_virt_text_id then
    pcall(vim.api.nvim_buf_del_extmark, 0, ns_id, state.suggestion_virt_text_id)
    state.suggestion_virt_text_id = nil
  end
  state.suggestion_text = nil
end

local function show_suggestion(text, line, col, request_id)
  if request_id ~= state.latest_request_id then return end
  clear_suggestion()
  if not text or text == "" then return end

  vim.schedule(function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    if cursor[1] ~= line then return end

    local current_line = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
    local clamped_col = math.min(col, #current_line)
    state.suggestion_text = text

    local lines = vim.split(text, "\n", { trimempty = true })
    if #lines == 0 then return end

    local virt_text = { { lines[1], "Comment" } }
    local virt_lines = {}
    for i = 2, #lines do
      table.insert(virt_lines, { { lines[i], "Comment" } })
    end

    state.suggestion_virt_text_id = vim.api.nvim_buf_set_extmark(0, ns_id, line - 1, clamped_col, {
      virt_text = virt_text,
      virt_text_pos = "overlay",
      virt_lines = virt_lines,
      invalidate = true,
    })
  end)
end

-- Modified get_context to include following text
local function get_context()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local col = cursor[2]
  
  -- Get current line
  local current_line = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
  col = math.min(col, #current_line)
  
  -- Get previous context (up to 100 lines before)
  local start_line = math.max(1, line - 100)
  local prev_lines = vim.api.nvim_buf_get_lines(0, start_line - 1, line - 1, false)
  local prev_context = table.concat(prev_lines, "\n")
  if #prev_context > 0 then prev_context = prev_context .. "\n" end
  prev_context = prev_context .. string.sub(current_line, 1, col)
  
  -- Get following context (up to 10 lines after)
  local end_line = math.min(line + 100, vim.api.nvim_buf_line_count(0))
  local following_lines = vim.api.nvim_buf_get_lines(0, line - 1, end_line, false)
  local following_context = table.concat(following_lines, "\n")
  following_context = string.sub(following_context, col + 1)
  
  return prev_context, following_context, line, col
end

-- Modified request_completion to include following context
local function request_completion()
  if not M.config.show_suggestions or state.prompt_in_progress then return end

  state.latest_request_id = state.latest_request_id + 1
  local request_id = state.latest_request_id

  local prev_context, following_context, line, col = get_context()
  if #prev_context < M.config.trigger_threshold then return end

  local filetype = vim.bo.filetype
  local system_prompt = "You are a coding assistant. Your task is to provide code completions that continue the given snippet without repeating the existing code that comes either before or after the insertion point. Do not generate anything other than the code, do not use markdown, just plaintext code. Do not write more than needed, less is more unless told otherwise by comment."
  local user_prompt = "Continue this " .. filetype .. " snippet starting from where the previous code ends. Do not repeat any of the existing code that comes before or after. Only provide new code that fits logically between the previous and following code:\n" ..
    "Previous code:\n```\n" .. prev_context .. "\n```\n" ..
    "Following code:\n```\n" .. following_context .. "\n```"

  state.prompt_in_progress = true
  local url = M.config.useOllama and M.config.ollama_url or M.config.grok_url
  local body
  if M.config.useOllama then
    body = vim.json.encode({
      model = M.config.model,
      prompt = system_prompt .. "\n" .. user_prompt,
      temperature = M.config.temperature,
      num_predict = M.config.max_tokens,
      stream = false,
    })
  else
    body = vim.json.encode({
      model = M.config.model,
      messages = {
        { role = "system", content = system_prompt },
        { role = "user", content = user_prompt },
      },
      temperature = M.config.temperature,
      max_tokens = M.config.max_tokens,
      stream = false,
    })
  end

  local headers = { ["Content-Type"] = "application/json" }
  if not M.config.useOllama then
    headers["Authorization"] = "Bearer " .. M.config.api_key
  end

  require("plenary.curl").post({
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

      local suggestion = M.config.useOllama and result.response or (
        result.choices and result.choices[1].message.content
      )
      if suggestion then
        suggestion = suggestion:gsub("^```[%w]*\n", ""):gsub("\n```$", "")
        show_suggestion(suggestion, line, col, request_id)
      end
    end,
  })
end

-- accept_suggestion(), setup_autocommands_and_keymaps(), setup_commands(), and M.setup() 
local function accept_suggestion()
  if not state.suggestion_text then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local col = cursor[2]
  local lines = vim.split(state.suggestion_text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(0, line - 1, col, line - 1, col, lines)

  local new_pos = #lines == 1 and { line, col + #lines[1] } or
                  { line + #lines - 1, #lines[#lines] }
  vim.api.nvim_win_set_cursor(0, new_pos)
  clear_suggestion()
end

local function setup_autocommands_and_keymaps()
  local group = vim.api.nvim_create_augroup("Wingman", { clear = true })

  if M.config.auto_trigger then
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
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
    vim.api.nvim_create_autocmd({ "CursorMovedI", "InsertLeave" }, {
      group = group,
      callback = clear_suggestion,
    })
  end

  vim.keymap.set("i", M.config.keymaps.accept, function()
    if state.suggestion_text then
      vim.schedule(accept_suggestion)
      return ""
    end
    return M.config.keymaps.accept
  end, { expr = true })
end

local function setup_commands()
  vim.api.nvim_create_user_command("WingmanToggle", function()
    M.config.show_suggestions = not M.config.show_suggestions
    print("Wingman suggestions " .. (M.config.show_suggestions and "enabled" or "disabled"))
  end, {})

  vim.api.nvim_create_user_command("WingmanComplete", request_completion, {})
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if not M.config.useOllama and M.config.api_key == "" then
    vim.notify("Wingman: API key is required when useOllama is false", vim.log.levels.WARN)
  end
  setup_autocommands_and_keymaps()
  setup_commands()
end

M.request_completion = request_completion

return M
