# lazy-tag.yazi

Ranger-style file tags for [yazi](https://github.com/sxyazi/yazi).

A file carries **one** tag: a single character, drawn in red directly in front
of its name. Tagging with a different character replaces the old tag; tagging
with the same one removes it.

```
 󰉋 * src/
 󰈔 a notes.md
 󰈔 README.md
 󰈔 * Cargo.toml
```

Tags are kept in yazi's [DDS](https://yazi-rs.github.io/docs/dds/) rather than
in files on disk, so every running yazi instance sees the same tags live, and
yazi persists them for you.

## Why not simple-tag?

[simple-tag.yazi](https://github.com/boydaihungst/simple-tag.yazi) is the fuller
plugin — many tags per file, colours, icons, filtering, set operations on
selections. `lazy-tag` deliberately does less:

| | simple-tag | lazy-tag |
|---|---|---|
| Tags per file | many | exactly one |
| Storage | JSON files under `~/.config/yazi/tags` | DDS static message |
| Appearance | configurable icons and colours | the tag character, red |
| Position | after the file name | in front of the file name |
| Entry | async | **sync**, so it composes with other commands |

The sync entry is the point of the "lazy" bit: `run` a tag command and an
`arrow` in the same binding and they happen in order, so holding one key walks
down a directory tagging as it goes.

## Requirements

yazi 26.5.6 or newer.

## Installation

Put the plugin at `~/.config/yazi/plugins/lazy-tag.yazi`, either by cloning it
there or by symlinking a working copy:

```sh
ln -s /path/to/lazy-tag.yazi ~/.config/yazi/plugins/lazy-tag.yazi
```

Then in `~/.config/yazi/init.lua`:

```lua
require("lazy-tag"):setup()
```

## Configuration

Every option is optional:

```lua
require("lazy-tag"):setup {
  -- Tag colour. Any yazi colour: a name, or "#rrggbb".
  color = "red",
  -- The tag `toggle` uses when no `--key` is given.
  key = "*",
  -- Where the tag is drawn on the line. `Entity` draws the icon at 2000, the
  -- search prefix at 3000 and the file name at 4000, so 3500 puts the tag
  -- immediately in front of the name. Use 1500 to put it at the far left,
  -- before the icon.
  order = 3500,
}
```

## Keys

Nothing is bound by default. In `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = "t"
run  = [ "plugin lazy-tag -- toggle", "arrow 1" ]
desc = "Toggle the default tag and move down"

[[mgr.prepend_keymap]]
on   = "\""
run  = "plugin lazy-tag -- toggle --pick"
desc = "Tag with the next key pressed"

[[mgr.prepend_keymap]]
on   = [ "T", "c" ]
run  = "plugin lazy-tag -- clear"
desc = "Remove the tag"

[[mgr.prepend_keymap]]
on   = [ "T", "s" ]
run  = "plugin lazy-tag -- select"
desc = "Select every tagged file here"

[[mgr.prepend_keymap]]
on   = [ "T", "S" ]
run  = "plugin lazy-tag -- select --pick"
desc = "Select the files carrying one tag"

[[mgr.prepend_keymap]]
on   = [ "T", "j" ]
run  = "plugin lazy-tag -- jump"
desc = "Jump to the last tagged file here"

[[mgr.prepend_keymap]]
on   = [ "T", "k" ]
run  = "plugin lazy-tag -- jump --first"
desc = "Jump to the first tagged file here"

[[mgr.prepend_keymap]]
on   = [ "T", "p" ]
run  = "plugin lazy-tag -- prune"
desc = "Forget tags whose files are gone"
```

### Actions

| Action | Flags | Does |
|---|---|---|
| `toggle` | `--key=X`, `--pick` | Tags the selected files, or the hovered one. Applies the group rule below. |
| `clear` | | Removes the tag from the selected files, or the hovered one. |
| `select` | `--key=X`, `--pick` | Replaces the selection with the tagged files in the current directory. |
| `jump` | `--key=X`, `--pick`, `--first` | Moves the cursor to the last tagged file in the current directory, or the first with `--first`. |
| `prune` | | Forgets every tag whose file no longer exists, and reports how many went. |

`--key=X` names the tag. `--pick` waits for a keypress instead — no popup, no
input box, exactly one key, `<Esc>` cancels. With neither, `toggle` uses the
configured default (`*`) and `select`/`jump` act on any tag.

`prune` is the answer to files that disappear behind yazi's back — deleted from
a shell, moved by another program, or on a drive that was unmounted. Tags only
follow files that yazi itself moved or removed, so run `prune` occasionally if
you edit the same trees from outside. It stats every tagged path, so it takes a
moment on a large database.

**The group rule.** When several files are tagged at once, the whole group is
untagged only if every one of them already carries that exact tag; otherwise
they all get it. Tagging a mixed group therefore makes it uniform first, which
is what ranger does.

### Composing with other commands

The plugin entry is synchronous, so a binding's `run` list executes in order:

```toml
run = [ "plugin lazy-tag -- toggle --key=a", "arrow 1" ]   # tag, then step down
run = [ "plugin lazy-tag -- jump", "arrow 1" ]             # last tagged, then one past
```

Two invocations step out of that order, because neither waiting for a keypress
nor stat-ing a file can happen on yazi's main thread: anything with `--pick`,
and `prune`. Those hand themselves off to the scheduler, so commands after them
in the same `run` list do not wait. (You never need `--mode=async` in a binding
— the plugin arranges it itself.)

## Storage

Tags live in a DDS static message under the kind `@lazy-tag`, as a flat map of
absolute path to tag character. Yazi's DDS server holds the current value,
replays it to every instance that connects, and writes it to
`~/.local/state/yazi/.dds` when the last instance exits. So:

- Tagging in one instance shows up in the others immediately.
- Tags survive quitting yazi, and nothing is written next to your files.
- The database is a single value. Two instances tagging within the same
  millisecond can lose one of the two changes.
- `~/.local/state/yazi/.dds` is shared with other plugins that persist state.
  Deleting it clears their state too.

Tags follow their files: renames, bulk renames, moves and copies carry the tag
along, and deleting or trashing a file drops it. Moving or deleting a directory
does the same for everything under it. Changes made outside yazi are invisible
to all of that — use `prune` to clean up after them.

To read or clear the database from a shell:

```sh
grep '^@lazy-tag,' ~/.local/state/yazi/.dds   # while yazi is not running
ya pub-to 0 @lazy-tag --json null             # clear every tag
```

## Limitations

- Only files on the local filesystem can be tagged. Archives, SFTP and other
  virtual schemes are refused.
- A file name that is not valid UTF-8 cannot be stored, because the database
  travels as JSON.
- A tag is one character. Multi-character keys are rejected.

## License

MIT.
