# logarktos.nvim

A Neovim **workspace plugin** for task-oriented tab layouts, persistent scratch
buffers, timestamped notes, and chronological file organization.

The idea: your tabs stop being "just tabs" and become *workspaces*. An editor
sits in the centre with disposable scratch buffers around it — and thanks to
**bufferfiles**, those scratch buffers autosave themselves, so you never lose a
note and never have to decide where to put it. Timestamped Markdown capture and
a couple of conservative "organize this folder" commands round it out.

> Nothing is forced on you. Installing the plugin changes **no** keymaps and
> **no** startup screen until you opt in.

## Requirements

- Neovim 0.10+
- [oil.nvim](https://github.com/stevearc/oil.nvim) — optional but recommended;
  most directory-aware features integrate with it and fall back gracefully.
- [mini.icons](https://github.com/echasnovski/mini.icons) — optional, for icons
  in the bookmark/recent panels.

## Install (lazy.nvim)

```lua
{
  "tsalmeida/logarktos.nvim",
  dependencies = { "stevearc/oil.nvim" }, -- optional
  opts = {
    -- everything is off by default; opt in to what you want
  },
}
```

`opts` is passed to `require("logarktos").setup()`. If you prefer, call it
yourself:

```lua
require("logarktos").setup({
  keymaps = true,                       -- install the default keymaps
  startup = { layout = "triplicate" },  -- open a layout on startup
})
```

## Concepts

### Bufferfiles — disposable notes that never get lost

Start typing in any empty buffer. The moment it has text, logarktos gives it a
name under a private *bufferfiles* root and autosaves it. The root keeps the
most-recent `keep` files (default 20); older ones move to `archive/`, and files
you rename move to `named/`. A freshly-created bufferfile is reloaded after its
first autosave, so Neovim treats it as a Markdown file right away. Open the root
with `:LogarktosBufferFiles`.

```lua
bufferfiles = {
  enabled = true,
  dir = nil,        -- default: stdpath("state")/logarktos/bufferfiles
  keep = 20,
  prefix = "buffer-",
}
```

Prefer setting `dir` in the user `logarktos.lua` (see below) rather than env vars.

### Layouts — tabs as workspaces

| Command | What it builds |
| --- | --- |
| `:LogarktosTriplicate [dir]` | Oil ┃ bookmarks ┃ recent files — the signature opening workspace |
| `:LogarktosLarge` / `:LogarktosNewLarge` | wide editor flanked by narrow scratch buffers |
| `:LogarktosFocus` | editor centred with empty side buffers |
| `:LogarktosWork` / `:LogarktosHereWork` | editor plus two terminals (new tab / current tab) |
| `:LogarktosAIMode` / `:AIMode` | terminal plus Oil columns (folder from Oil / bookmark under cursor / file dir) |
| `:LogarktosTriple` / `:LogarktosDual` | synchronized views of the same buffer |
| `:LogarktosFocusToggle` | toggle inactive-window dimming |
| `:LogarktosFixLayout` | even out the current tab's columns (rebalances a messed-up layout) |
| `:LogarktosSendToAI` | send selection/buffer to OpenAI (needs `ai.enabled` + API key) |

### `logarktos.lua` — user prefs + per-folder layouts

Two scopes share the same filename and Lua table format:

1. **User file** — `stdpath("config")/logarktos.lua`  
   Created on first setup if missing. Holds machine/user logarktos data:
   `start_dir` (Triplicate / “open start folder”), `ignore_dirs` (recent-files
   panel), `bufferfiles`, `ai` (model, max input chars, default instruction),
   and `bookmarks`. **Never put API keys here** — set `OPENAI_API_KEY` in the
   environment or a gitignored `.env`. When the key is missing, AI commands
   tell you where to put it.

2. **Project files** — `logarktos.lua` in any folder you open a layout from  
   Holds `aimode` / `work` pane targets. **`:AIMode` / `:LogarktosWork` /
   `:LogarktosHereWork`** ensure the matching section exists: if the file or
   section is missing, it is written from the **plain** first-run defaults
   (interactive terminal with no auto-start command; Oil columns on the layout
   folder; Work’s two right terminals also plain). No special folders
   (`frontend/sdl/`, etc.) are guessed — add those paths yourself when you want
   them. Later runs read the file. Sections can also be added into an existing
   user file when you run those layouts from the Neovim config folder.

```lua
-- What the plugin seeds on first use (plain defaults; cmd ready to fill):
return {
  aimode = {
    left = { path = ".", cmd = "" },  -- put e.g. "grok --yolo" in cmd
    center = { path = "." },          -- Oil at the layout folder
    right = { path = "." },
  },
  work = {
    right = {
      { path = ".", cmd = "" },       -- top terminal
      { path = ".", cmd = "" },       -- bottom terminal
    },
  },
}
```

Non-empty `cmd` values are typed into an interactive shell (the shell remains
the terminal job). Exiting the program (`/exit` in an AI CLI, etc.) returns
you to that shell; the pane stays open and the layout does not collapse.

Legacy `logarktos.env` (`left:…` lines) is still read and converted when no
`logarktos.lua` exists yet.

### Smart tab names

Every layout names its tab from the buffer it centres on. Names carry a
*meaningfulness tier* (`layout < note < folder < heading < manual`) so the best
clue wins and sticks, while arrangement-only labels stay disposable. Inferred
names are capped (default 12 chars); `:LogarktosTabRename` sets a manual name
that always wins. An optional tabline renderer (`tabs.tabline = true`) shows the
names with a ● for meaningful ones.

**AIMode / Work terminals:** when an AI CLI is running in a watched terminal
(`codex`, `grok`, `claude`, `agy`, …) — either auto-started from
`logarktos.lua` or launched by hand — the tab title becomes `codex-<title>`
(app name + the existing folder/title name).

### Timestamped notes

`:LogarktosNewMarkdown` creates a `YYYYMMDD - HHMMSS[ - Title].md` note in the
current Oil directory (or cwd), optionally seeded from a `template.md` found
there (a `# Title` placeholder is replaced with your title). Any `*YYYYMMDD*`
marker in the template is replaced with today's date in that format
(configurable via `markdown.date_marker`). When a template is used the note
opens straight away; if the template contains the focus marker
`*template_focus*` (configurable via `markdown.focus_marker`) it is stripped and
the cursor lands there in insert mode with the line centred. Without a template
the behaviour is unchanged — in Oil you simply land on the new file.
`:LogarktosMarkdownArchive` tucks the current file, unchanged, into an
`archive/` subfolder, then drops you into a refreshed Oil view of the original
folder so the file disappears from the listing. From an Oil buffer it can also
archive the current entry or a visual/ranged selection of Markdown files into
that Oil directory's `archive/` folder.

### logarktos.lua

- `:Logarktos` — refresh the current folder's `logarktos.lua` (Oil dir, then
  buffer dir, then cwd). Keeps every key already defined; adds any standard
  categories/keys that are still missing (`organize`, `aimode`, `work`, and
  nested defaults such as `organize.fixed`). Creates the file when absent.

### Organize

- `:LogarktosOrganize` — sort a directory's loose files and folders into dated
  buckets, with a log of everything moved. Skips `documents/`, `logarktos.lua`,
  and the Auto Ordered* buckets by default. Settings live in that folder's
  `logarktos.lua` under `organize` (written on first run if missing):

  ```lua
  organize = {
    -- basenames skipped; add more as needed
    ignore = { "documents", "logarktos.lua" },
    -- emptied into folders_bucket/<name> (no date prefix); originals stay empty
    fixed = { "fonts" },
    -- "timestamps" (default) or "extensions" (no timestamp subfolder for files)
    files = "timestamps",
  },
  ```

- `:LogarktosTimestamp` — prefix folders with their created date (Oil).
- `:LogarktosExtract` — extract every archive in an Oil directory into dated
  folders (needs 7-Zip or `tar`).
- `:LogarktosOrganizeImages` — sort images into square/portrait/landscape (needs
  `ffprobe` or ImageMagick `identify`).
- `:LogarktosSeparateDuplicates` — move duplicate files to `./Duplicates`.
- `:LogarktosRecent10` / `:LogarktosRecentFiles` — recently-modified file panels.

### Bookmarks & recent files

`:LogarktosBookmarks` opens an Oil-like list (folders first, then files, newest
first). `<CR>` opens in Neovim, `<C-v>`/`<C-x>` split, `gx` opens with the
operating system's default app, `dd` deletes, and `q` closes. Add the current/Oil
file or folder with `:LogarktosBookmarkAdd` / `:LogarktosBookmarkAddDir`.

### Working-directory mode

`:LogarktosLocal` / `:LogarktosRoot` pin the window-local cwd to the current
folder or the project root and record the mode in `vim.w.pwd_mode`, so your
pickers and terminals can scope themselves.

## Default keymaps

Set `keymaps = true` to install the leader-based defaults, or pass a table to
override individual ones (set any to `false` to disable just that mapping):

```lua
require("logarktos").setup({
  keymaps = {
    triplicate = "<leader>tt",
    here_work  = "<leader>hw",
    large      = "<leader>lm",
    new_markdown = "<leader>nm",
    organize   = "<leader>or",
    -- … see lua/logarktos/config.lua for every action
  },
})
```

The arrow keys resize the current window by default (`resize_left/right/up/down`).

## Short command aliases

Public commands are namespaced `:Logarktos*` to avoid clashes. To also get the
short forms (`:Triplicate`, `:Organize`, `:NewMarkdown`, …):

```lua
require("logarktos").setup({ short_commands = true })
```

## Optional AI filename suggester

Off by default and the only module that touches the network. Enable it and
provide an API key:

```lua
require("logarktos").setup({
  ai = { enabled = true, api_key_env = "OPENAI_API_KEY" },
  keymaps = { suggest_filename = "<leader>sf" },
})
```

`:LogarktosSuggestFilename` proposes a CamelCase name from the buffer's content,
preserving a `:LogarktosNewMarkdown` timestamp prefix when present.

For notes seeded from a `template.md` (the same `markdown.template` used by
`:LogarktosNewMarkdown`), the shared template lines are stripped before the text
is sent, so the suggestion reflects what *you* wrote rather than the boilerplate.
The template is found in the note's own folder, or — for archived notes — in the
parent of an `archive/` folder. Only the first `ai.max_input_chars` characters
(default 1000) of the trimmed text are ever sent.

## License

MIT
