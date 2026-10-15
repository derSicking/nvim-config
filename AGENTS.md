# AGENTS.md — Neovim config

## Plugin manager

Uses Neovim's built-in `vim.pack` (not lazy.nvim, not packer). Lockfile is
`nvim-pack-lock.json`.

- `:PackUpdate` — update all plugins (custom cmd defined in `lua/mappings.lua`)
- Plugins declared per-file under `lua/plugins/*.lua` with
  `vim.pack.add({...})`. No lazy loading.

## Entrypoint

```
init.lua -> require("init") -> lua/init.lua
```

`lua/init.lua` requires every module in order: mappings → options → autocommands
→ plugins → lsp → formatting → custom.\* → filetypes.

Each plugin's config lives in its own file under `lua/plugins/`, wired together
by `lua/plugins/init.lua`.

## Key dependencies

| Concern                                | Library                                                          |
| -------------------------------------- | ---------------------------------------------------------------- |
| Completion                             | `blink.cmp` (not nvim-cmp)                                       |
| Picker (find/grep/buffers/diagnostics) | `snacks.nvim` (not telescope)                                    |
| File explorer                          | `oil.nvim` (default, also `<leader>e`)                           |
| Format on save                         | `conform.nvim` (1000ms timeout)                                  |
| LSP install                            | `mason.nvim` + `mason-tool-installer` (auto-install at start)    |
| LSP client                             | Neovim 0.12's `vim.lsp.config()` (not lspconfig's setup)         |
| Snippets                               | `LuaSnip` + `vim.snippets`, stored in `~/.config/nvim/snippets/` |
| tmux navigation                        | `nvim-tmux-navigation` (not vim-tmux-navigator)                  |
| Colorscheme                            | `catppuccin` (latte)                                             |

## LSP quirks

- `blink.cmp.get_lsp_capabilities()` passed to every server via
  `vim.lsp.config("*", ...)`
- `angularls` is NOT installed via mason — runs via `npx ngserver` from
  project-local `node_modules`
- `clangd` has a hardcoded `--query-driver` for ESP32 cross-compiler and looks
  for `build/compile_commands.json` in cwd
- Inlay hints enabled for `ts_ls`, `lua_ls`, `clangd`; toggled with `<leader>ih`
- LSP keymaps (`K`, `gd`, `gr`, `dp`, `dP`, `<leader>f`, `<leader>rn`) set in
  `on_attach` in `lua/lsp.lua`

## Formatting (conform + prettierd)

`prettierd` is a long-lived daemon, keyed by cwd (core_d's
`.prettierd@<encoded cwd>`), so each project directory gets its own. It resolves
the project's `prettier` _path_ per request but then `require()`s it, and Node
caches modules by path — so after `npm install` replaces
`node_modules/prettier`, a running daemon keeps formatting with the old version
and silently diverges from `prettier --check`.

- After updating dependencies in a project (or whenever formatting disagrees
  with the CLI), run `prettierd stop` to spawn fresh daemons on the next save.
- Debug with `prettierd --debug-info <file>`, but note it runs in a _fresh
  client process_, so it reports what a new daemon would load — not what a
  running daemon is actually using.
- `html`/`htmlangular` use `lsp_format = "never"`, so templates are formatted by
  prettierd (matching `prettier --check`) instead of the HTML language server.

## Keymaps summary

| Keys                                              | Action                                  |
| ------------------------------------------------- | --------------------------------------- |
| `<leader>`                                        | Space                                   |
| `<c-p>`                                           | Snacks picker: files                    |
| `<leader>ps` / `<leader>pb`                       | Snacks picker: grep / buffers           |
| `<leader>e`                                       | Oil file explorer                       |
| `<leader>a` / `<c-e>`                             | Grapple: toggle tag / toggle tags       |
| `<leader>1`-`<leader>0`                           | Grapple: select tag by index            |
| `<leader>gs`                                      | Git status (fugitive)                   |
| `<leader>h*`                                      | Gitsigns: stage, reset, blame, hunk nav |
| `<leader>o`                                       | Opencode                                |
| `go` / `goo` (operator)                           | Send range/line to opencode             |
| `<C-h/j/k/l>` / `<C-Arrows>`                      | tmux pane navigation                    |
| `<M-j/k>` / `<M-Up/Down>`                         | Move lines                              |
| `<leader>u`                                       | Undotree                                |
| `:Format` / `:FormatDisable[!]` / `:FormatEnable` | Format manually / toggle autoformat     |

## No external tooling

No tests, lints, or typecheck for the config itself. Edit, reload with `:so %`
or restart nvim to verify.
