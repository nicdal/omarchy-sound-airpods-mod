# Sound (AirPods mod)

[Omarchy](https://omarchy.org/) 4.0's Sound panel, with AirPods battery levels
and listening-mode switching folded into it — the way macOS puts them in one
Sound menu instead of a separate widget.

It replaces the stock `omarchy.audio` widget on the bar. Volume, output picker
and per-app mixer all behave exactly as before; the AirPods parts appear only
when there are AirPods to talk about.

![the panel](docs/screenshot.png)

Battery and listening-mode data come from
[MagicPodsCore](https://github.com/steam3d/MagicPodsCore), which speaks to the
headphones over Bluetooth and exposes their state on a local WebSocket.

## Why it's a "mod"

The Omarchy shell has no API for one plugin to add a section to another plugin's
panel, so there is no way to extend `omarchy.audio` from the outside. The
supported route is to take a copy, which is what this is: `Panel.qml` and
`Model.js` are vendored from Omarchy 4.0's first-party `omarchy.audio` (MIT — see
[LICENSE](LICENSE)).

Everything added here is marked `AirPods mod`, so the vendored parts stay easy to
diff against upstream when Omarchy improves the audio panel. The flip side of a
fork: those upstream improvements don't arrive on their own.

## Requirements

- Omarchy 4.0 or newer (the Quickshell-based `omarchy-shell`)
- `magicpodscore` running and paired with your headphones:
  ```bash
  systemctl --user enable --now magicpodscore
  ```
  The package ships no unit of its own, so you'll need to supply one.
- Python 3 (already present on Omarchy)

## Install

```bash
omarchy plugin add https://github.com/nicdal/omarchy-sound-airpods-mod.git --enable --yes
omarchy bar put community.sound-airpods-mod
omarchy bar move community.sound-airpods-mod --section right
```

Then take the stock audio widget off the bar, since this one supersedes it —
remove the `omarchy.audio` entry from `bar.layout` in
`~/.config/omarchy/shell.json`.

Plugins land disabled by default so you can read the code first; `--enable`
skips that. (`omarchy bar put --section` isn't honoured, hence the separate
`move`.)

To update later:

```bash
omarchy plugin update community.sound-airpods-mod
```

## What you get

Everything the stock Sound panel has, plus:

**Battery on the output row** — the connected headphones show their charge next
to their name in the output list: `Left 82% Right 79% Case 45%` on AirPods and
AirPods Pro, a single reading on models like the AirPods Max that only report
one cell. A bolt marks anything charging. Components the device doesn't report
are omitted rather than shown as 0%.

**Noise Control** — a section listing only the modes the device actually
advertises, with a tick on the live one. Selecting a mode is optimistic: the
tick moves immediately and reconciles when the daemon confirms, so a click never
looks like it missed.

Noise Control appears **only while the headphones are the selected output** —
switch to speakers and the panel is identical to the stock one. Battery stays
visible on the row for as long as they're connected, since that's useful even
when you're listening through something else.

With no headphones connected, nothing is added at all: no empty section, no
separator.

## Options

**Show battery in bar** is a switch in the panel itself, under the output list.
It's off by default, so the bar is the stock icon alone; flip it on and the icon
gains the reading. The choice is written to `~/.config/omarchy/shell.json`, so it
survives a shell restart and a reboot.

The reading is the lowest bud, ignoring the case — the case isn't what runs out
mid-call. A bolt marks charging.

Both options can also be set from the command line:

```bash
omarchy bar set community.sound-airpods-mod showBattery true --json

# Point the panel at a synthetic device, for working on it with no headphones
# to hand.
omarchy bar set community.sound-airpods-mod demo true --json
```

With the battery hidden the bar uses Omarchy's standard `BarIconButton`, which
draws one optically-centred glyph in a fixed icon slot. Showing the reading
swaps in a button that sizes itself to its contents instead — text in the fixed
slot would be squeezed against the neighbouring widget.

The added rows are mouse-driven: they stay out of the panel's keyboard cursor
model, which is indexed against the audio device lists.

## How it works

`airpods.py` holds one WebSocket to MagicPodsCore on `127.0.0.1:2020`, reduces
each update to a compact JSON line, and prints it only when something actually
changed.

That stream is owned by `Service.qml`, which is a plugin of kind `service` —
loaded **once** for the whole shell. It matters: Omarchy builds the bar with
`Variants { model: Quickshell.screens }`, so a `bar-widget` is instantiated once
per monitor. Running the bridge inside the widget spawned one process per screen,
each with its own idea of whether the headphones were connected, and the widget
flickered whenever they disagreed. One service, one bridge, one source of truth.

The bridge also treats a dropped socket as "unknown" rather than
"disconnected" — MagicPodsCore hangs up on idle clients, and reporting every
hang-up as an absent device made the widget flap in and out of the bar. It holds
the last known state for `RECONNECT_GRACE` seconds while it reconnects.

Matching a PipeWire sink to the headphones is done on the MAC address that bluez
puts in the node name (`bluez_output.90_62_3F_9A_02_59.1`).

The bridge can be driven straight from a terminal:

```bash
~/.config/omarchy/plugins/community.sound-airpods-mod/airpods.py watch
~/.config/omarchy/plugins/community.sound-airpods-mod/airpods.py demo
~/.config/omarchy/plugins/community.sound-airpods-mod/airpods.py set-anc 2
```

## Not available

MagicPodsCore doesn't expose Spatial Audio / head tracking or Conversation
Awareness, so those parts of the macOS menu can't be reproduced. It does expose
a Bluetooth codec picker and the press-speed / press-and-hold / tone-volume
settings, none of which are surfaced here yet.

Media volume never comes from the headphones — it's PipeWire, which is what the
panel's existing slider already controls.

## License

MIT. Includes code from [Omarchy](https://omarchy.org/) (MIT), see
[LICENSE](LICENSE).
