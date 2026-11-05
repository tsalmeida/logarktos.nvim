# Title

We're working on a project called logarktos.nvim

# Introduction

It's basically a bunch of utilities I created for myself on my Neovim settins, and that I then exported to this plugin. So when I have any new ideas connect to these functionalities, instead of adding them to my Neovim settings directly, I make the changes in here, then I install them to my Neovim with :Lazy, just like I would any one else's plugin.

Some of the basic ideas:

1. Tabs become arrangements of buffers, with several different kinds. One central idea to this is that we create a sort of "document" shape from the standard modern widescreen shape, by dividing the widescreen shape into either two or, most frequently, three portrait-shaped buffers.

2. There are several standard types of these tabs: "Workmode", which includes two terminal buffers; Triplicate, which includes three different types of shortcut buffers, meant to be used as a starting tab for Neovim itself; Triple, which divides the tab into three vertical buffers; Dual, which divides the tab into two vertical buffers; LargeMode, which divides the tab into three vertical buffers, but with a wider middle one; Focus, which creates a new tab with two empty buffers around the current buffer, and so on. They all work upon :Oil and general buffers.

3. There's some functionality around renaming tabs.

4. There's some functionality around how things written in empty buffers are saved.

5. There's some functionality around determining a standard place in your computer where you keep your general files, which is set in a .env file in your Neovim folder.

6. There's some functionality aorund creating markdown files with timestamped filenames, and using the AI to suggest a title for them.

7. There's some functionality around organizing files in messy folders based on filetype and folder names.

8. Some bookmark functionality for files and folders.

9. Resizing buffers with the use of the directional arrow keys.

# After the work

After implementing the requested changes, write a brief report into Autarktos (`L:\Library\Coding\project-ai-prompts_package.sqlite`) on the entry this prompt came from: put it in `longtext_2` (the commit message is fine) and set `datapoint_4` to one of GPT, Grok, Claude, Gemini, Other, according to which model family processed this prompt.

Use the entry `id` from a Dispatcher's note if present. Do not pick up other Pending rows from the database; that remains the Database prompts section, used only for manual one-project prompting. Write with a small `UPDATE`, commit immediately, and stamp `updated_at` (UTC `YYYY-MM-DDTHH:MM:SS.000000Z`).

# Request

## Current situation

The live briefing for this project is the Current Situation field of its row in All My Projects (`L:\Vault\Obras\all-my-projects_package.sqlite`, column `longtext_3`). This row is titled "Logarktos.nvim" (id `58674`). Tiago almost never reads it. Models do. Read it at the start of work on this project. It is the mirror of what is happening, what is waiting, what to do next, and what the intended direction is.

**Keep it true without asking.** Do not wait for confirmation. Do not open a second current-situation note with a new timestamp, and do not store a second copy of this briefing. Edit that field in place.

When anything material changes, do both of these in the same turn:

1. **Rewrite the present.** Change the snapshot and the do-now, waiting, and next lines so they match today. Delete or recast sentences that would be false if read tomorrow. A stale now line is a bug.
2. **Add what is new.** Put new facts in the section they belong to. If a plan changes, replace the old plan. Do not leave two competing plans.

**History.** Keep a short block of only what still explains the present. Move a fact there when it is no longer current but still explains a lock or a do-not-redo. Do not grow a diary. Detailed dated notes stay in their own files.

Do not copy whole emails or whole prompts into it. Do not leave advice that was already decided.

Write the field with one small `UPDATE` of `longtext_3`, commit immediately, and stamp `updated_at` (UTC, `YYYY-MM-DDTHH:MM:SS.000000Z`). Open a short-lived connection with pooling off. Re-read the row just before changing it. Never rewrite the database file wholesale. TKHN Sync carries the file.

After editing, stamp **Last rewritten** at the top (the date, and the one-line reason).
