# fontget

`~/.local/bin/fontget` previews and installs fonts for the current user only
(no sudo): files land in `~/.local/share/fonts/custom/` with a `CUSTOM-` prefix
on both the file name and the internal family name, so they are easy to tell
apart from packaged fonts.

Out of the box it can fetch from **no site at all**. Adapters for a few font
sites live in `sites-available/`; none is active until you enable it:

    fontget sites                 # what is available / enabled
    fontget sites enable dafont   # your call: you accept that site's terms
    fontget sites disable dafont

Enabling links the adapter into `sites/` (kept out of the dotfiles repo, so it
is a per-machine choice). The order you enable in is the lookup order for bare
font names. Your own adapters can be dropped straight into `sites/`; the header
of any shipped adapter documents the small class they must define.

Menu rows (Install > Style > Font) and the SUPER SHIFT ALT F binding call
`fontget install -i` / `fontget preview`; with no site enabled they just say so.
