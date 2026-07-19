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
  dir = nil,        -- default: stdpath("state")/logarktos/bufferfiles (or $BUFFERFILES_DIR)
  keep = 20,
  prefix = "buffer-",
}
```

### Layouts — tabs as workspaces

| Command | What it builds |
| --- | --- |
| `:LogarktosTriplicate [dir]` | Oil ┃ bookmarks ┃ recent files — the signature opening workspace |
| `:LogarktosLarge` / `:LogarktosNewLarge` | wide editor flanked by narrow scratch buffers |
| `:LogarktosFocus` | editor centred with empty side buffers |
| `:LogarktosWork` / `:LogarktosHereWork` | editor plus two terminals (new tab / current tab) |
| `:LogarktosAIMode` / `:AIMode` | terminal plus prompts/Oil columns; right Oil opens `frontend/sdl/` when the project has it |
| `:LogarktosTriple` / `:LogarktosDual` | synchronized views of the same buffer |
| `:LogarktosFocusToggle` | toggle inactive-window dimming |
| `:LogarktosFixLayout` | even out the current tab's columns (rebalances a messed-up layout) |

### Per-project `logarktos.env`

Any layout opened from a folder (`:AIMode`, `:Large`, `:Triple`, `:Work`, …)
looks for a `logarktos.env` file in that folder. If the file is missing, nothing
changes. If it is present, each line is a pane directive:

```
# comments and blank lines are ignored
left:path/to/
center:documents/prompts/
right:frontend/sdl/
left:codex --dangerously-bypass-approvals-and-sandbox
right:grok --yolo
```

- **Paths** (absolute, or relative to the layout folder, and resolvable as a
  directory — or looking like a path with `/` or a trailing slash) redirect
  that pane's Oil view / terminal cwd.
- **Commands** (anything else, e.g. `grok --yolo`) launch that shell command in
  the pane's terminal. Useful keys:
  - **AIMode `left:`** — auto-start the AI CLI in the left terminal.
  - **WorkMode `right:`** — first command → top-right terminal, second →
    bottom-right (e.g. `right: codex` then `right: grok --yolo`).

Without a `logarktos.env`, AIMode still defaults the right Oil column to
`frontend/sdl/` when that folder exists (same as writing `right:frontend/sdl/`).

### Smart tab names

Every layout names its tab from the buffer it centres on. Names carry a
*meaningfulness tier* (`layout < note < folder < heading < manual`) so the best
clue wins and sticks, while arrangement-only labels stay disposable. Inferred
names are capped (default 12 chars); `:LogarktosTabRename` sets a manual name
that always wins. An optional tabline renderer (`tabs.tabline = true`) shows the
names with a ● for meaningful ones.

**AIMode / Work terminals:** when an AI CLI is running in a watched terminal
(`codex`, `grok`, `claude`, `agy`, …) — either auto-started from
`logarktos.env` or launched by hand — the tab title becomes `codex-<title>`
(app name + the existing folder/title name).

### Timestamped notes

`:LogarktosNewMarkdown` creates a `YYYYMMDD - HHMMSS[ - Title].md` note in the
current Oil directory (or cwd), optionally seeded from a `template.md` found
there (a `# Title` placeholder is replaced with your title). When a template is
used the note opens straight away; if the template contains the focus marker
`*template_focus*` (configurable via `markdown.focus_marker`) it is stripped and
the cursor lands there in insert mode with the line centred. Without a template
the behaviour is unchanged — in Oil you simply land on the new file.
`:LogarktosMarkdownArchive` tucks the current file, unchanged, into an
`archive/` subfolder, then drops you into a refreshed Oil view of the original
folder so the file disappears from the listing. From an Oil buffer it can also
archive the current entry or a visual/ranged selection of Markdown files into
that Oil directory's `archive/` folder.

### Organize

- `:LogarktosOrganize` — sort a directory's loose files and folders into dated
  buckets, with a log of everything moved.
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
