# Wingman

**Wingman** is a Neovim plugin that provides intelligent code completion suggestions using either the Grok API (from xAI) or a local Ollama instance. It displays suggestions as virtual text in your buffer and allows you to accept them with a single keypress. Designed for seamless integration with LazyVim, Wingman aims to enhance your coding workflow with minimal setup.

## Features

- **Real-time code completion**: Suggestions appear as you type, based on your current context.
- **Supports Grok and Ollama**: Use either the cloud-based Grok API or a local Ollama instance for completions.
- **Configurable settings**: Customize API endpoints, models, keymaps, and more.
- **Automatic triggering**: Suggestions are triggered automatically after a configurable character threshold.
- **Toggle and manual completion**: Enable/disable suggestions or manually request completions via commands.
- **Lightweight**: Depends only on `plenary.nvim` for HTTP requests.

## Installation

Wingman.nvim is designed to work with [LazyVim](https://github.com/folke/lazy.nvim), a modern Neovim plugin manager. Follow these steps to install it:

### Using LazyVim

Add the following to your LazyVim configuration (typically in `~/.config/nvim/lua/plugins/`):

```lua
return {
  "haydenkz/nvim-wingman",
  lazy = false, -- Load immediately (recommended for real-time suggestions)
  dependencies = { "nvim-lua/plenary.nvim" }, -- Required for HTTP requests
  config = function()
    require("wingman").setup({
      api_key = "your-grok-api-key", -- Replace with your xAI Grok API key
      useOllama = false,             -- Set to true to use Ollama instead of Grok
      model = "grok-2-latest",       -- Specify the model to use
      ollama_url = "http://localhost:11434", -- Ollama API endpoint
      grok_url = "https://api.x.ai/v1/chat/completions", -- Grok API endpoint
    })
  end,
}
