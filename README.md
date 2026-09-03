# KeePass

An [Omarchy](https://omarchy.org) bar widget that finds a password and puts it
on your clipboard without opening KeePass.

The password manager is the one app you open for four seconds and then close
again. This is those four seconds: a key on the bar, the master password once,
and after that a search box. Type three letters, press Enter, paste. The
clipboard cleans itself up behind you.

## Install

```bash
omarchy plugin add https://github.com/ignacehelsen/omarchy-keepass.git --enable
```

Needs `python3`, `python-pykeepass`, `wl-clipboard` and `coreutils`. Omarchy
already has all but the second: install using the Omarchy installer.

It reads `.kdbx` files directly, so it works with KeePass 2.x, KeePassXC, and
anything else writing that format. It does not talk to a running KeePass, and
it never writes to the database.

## What it does

- **The key on the bar** opens the panel. It takes the theme's accent colour
  while the database is unlocked, so an open vault is something you can see
  rather than something you have to remember.
- **On first run it asks where your database is** and remembers the answer, so
  there is nothing to configure before you can use it. *Change database…* asks
  again later. A path typed here is kept in
  `~/.local/state/omarchy/settings/keepass.json` and wins over `shell.json`.
- **Unlocking** asks for the master password once. After that the panel is a
  search box, and it stays that way until the idle timer runs out.
- **Searching** matches the title, the username, the URL and the group, with
  title matches first. An empty box lists everything, so you can arrow straight
  down to what you want.
- **Enter copies the password**, **Shift+Enter the username**. Clicking a row
  does the same, right-clicking it copies the username.
- **The clipboard clears itself** a few seconds later — but only if it still
  holds what was put there. Copy something else in the meantime and yours is
  left alone.
- **Right-clicking the key**, or *Lock now*, locks immediately and scrubs the
  clipboard on the way out.

## Security

The reason this is worth trusting, in the order it matters:

- **The widget never sees your database.** All of it happens in `kp-agent`, a
  separate process. The panel only ever holds titles and usernames.
- **The master password goes over stdin**, never a command-line argument, so it
  does not appear in the process table where any other process could read it.
- **A locked vault is not a running process.** The agent exits the moment it
  locks, rather than idling with your database in its memory.
- **The socket** it listens on lives in `$XDG_RUNTIME_DIR` and is mode `0600`.
- **The clipboard** is scrubbed after `Clear the clipboard after` seconds, and
  the check is value-based so it cannot wipe something you copied yourself.

What this does *not* protect against: anything already running as you can read
your clipboard during those seconds, and can talk to the agent's socket while
the vault is unlocked. A short idle timeout is the setting that limits that.

## Settings

Everything here can also be set in the widget's entry in `~/.config/omarchy/shell.json`,
but the database path is the only one you need, and the panel asks for that
itself.

| Setting | Default | |
| --- | --- | --- |
| Database file | `~/Database.kdbx` | The `.kdbx` to open. A leading `~` is expanded. Set it from the panel rather than by hand. |
| Key file | *(none)* | For databases that want a key file as well as a password. |
| Lock again after | 600 | Seconds of inactivity before the database is dropped. The timer restarts on every lookup. |
| Clear the clipboard after | 20 | Seconds before a copied password is scrubbed. `0` leaves it. |

## The command line

`kp-agent` is the storage side, and works on its own:

```
status              is the vault unlocked, and for how much longer
unlock              master password on stdin
search QUERY        matching entries as JSON (titles and usernames only)
copy UUID [FIELD]   put password or username on the clipboard
lock                forget the database and scrub the clipboard
```

```bash
./kp-agent --db ~/Database.kdbx status
```

## Licence

MIT.
