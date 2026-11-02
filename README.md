# hidpi-override

A small bash script that installs a macOS display override plist, adding extra
HiDPI scaled resolutions for one external monitor. It uses only macOS built-ins
(`ioreg`, `plutil`, `xxd`, `base64`, `install`, `mktemp`, `sudo`) and downloads
nothing.

## What it does

macOS reads per-display overrides from
`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vid>/DisplayProductID-<pid>`
(lowercase hex, no padding, no extension). The script reads the monitor's
vendor and product ID from `ioreg`, builds that plist, checks it with
`plutil -lint`, and installs it with `sudo`. For each "looks like" resolution
WxH it adds two `scale-resolutions` entries with the backing size 2Wx2H: an
8-byte one and a 16-byte one (suffix `0x00000009 0x00200000`), as other tools
do.

## Commands

```sh
./hidpi-override.sh list
./hidpi-override.sh install [--display N] [--res "WxH WxH ..."] [--dry-run] [--force]
./hidpi-override.sh uninstall [--display N]
```

- `list` prints `index  vid:pid (hex)  name` for each external display (Apple
  internal displays, vendor 0x610, are skipped).
- `install` picks the display automatically when exactly one external display
  is connected, otherwise pass `--display N` from `list`. The default
  resolutions suit a 3440x1440 panel: `3440x1440 3096x1296 3062x1282
  2752x1152 2580x1080 2560x1072 2520x1055 2480x1038 2440x1021 2400x1005
  2365x990`. macOS drops the ones the Mac or the connection cannot drive (see
  Limits), so the list covers both HDMI and USB-C on an M2 Pro and an M3.
  Use `--res` for other panels. `--dry-run` prints the target path and the
  plist and does nothing else (no `sudo`). An existing override file is kept
  unless you pass `--force`.
- `uninstall` moves that display's override file to `~/.Trash/` with a
  timestamped name and removes the vendor folder only if it is then empty.
  Nothing is deleted.

Run `list` and `install --dry-run` first, then `install` (it asks for your
password through `sudo`).

## Apply and undo

macOS reads the override when the display connects. After `install` or
`uninstall`, unplug and replug the monitor cable; if the modes do not change,
log out or reboot. To undo: `./hidpi-override.sh uninstall`, then replug.

## Limits

On Apple Silicon, macOS may still refuse modes above the GPU or display limits
(maximum backing size, bandwidth, or what the monitor's EDID accepts). An
override only adds candidates; a mode that does not show up in System Settings
after replugging was rejected by macOS.

The limit depends on the Mac and the connection. Tested with the same Huawei
3440x1440 monitor:

| Mac | Connection | Monitor reports | Largest HiDPI accepted | Rejected |
| --- | --- | --- | --- | --- |
| Mac mini M2 Pro, macOS 15.7 | HDMI | native 1920x1080, 100 Hz | 2560x1072 (backing 5120x2144) | 2580x1080 and above |
| Mac mini M2 Pro, macOS 15.7 | USB-C | native 3440x1440, 165 Hz | 3096x1296 (backing 6192x2592) | 3440x1440 (backing 6880x2880) |
| MacBook Air M3, macOS 27.0 | USB-C | native 3440x1440, 165 Hz | 3062x1282 (backing 6124x2564), up to 144 Hz | 3096x1296 (backing 6192x2592) |

3062x1282 is in the default list for the M3. Prefer USB-C or DisplayPort
when the monitor has it.

## Tests

`bash test.sh` runs the parser and encoder against ioreg fixtures
(`HIDPI_IOREG_FIXTURE=<file>` replaces the `ioreg` output). It never calls
`sudo` and writes nothing outside a temp directory.
