# scielo.koplugin

A [KOReader](https://koreader.rocks/) plugin to search and download open access
articles from [www.scielo.br](https://www.scielo.br) (SciELO Brazil) for offline
reading.

## Features

- Keyword search over SciELO articles via the Crossref API (restricted to SciELO's
  DOI prefix `10.1590`).
- Open an article directly from a `www.scielo.br` URL, a DOI, or a SciELO article
  code (e.g. `S0034-89102013000100001`).
- Article preview before download: title, authors, journal, volume/issue, date and DOI.
- PDF download to a configurable folder, with automatic filename sanitization and
  collision handling.
- Option to open the downloaded article right away.
- Dispatcher action ("SciELO search") so the search dialog can be bound to a
  gesture or hotkey.
- Only articles hosted on `www.scielo.br` are opened from search results.

## Requirements

- KOReader (tested with the 2026.07.1 Linux emulator).
- A network connection when searching/downloading.

## Installation

Copy or symlink the `scielo.koplugin` directory into one of KOReader's plugin
directories:

- Built-in plugins: `koreader/plugins/`
- User plugins: `koreader/settings/../plugins/` (on desktop builds with
  `KO_MULTIUSER=1`, that is `~/.config/koreader/plugins/`)

Then restart KOReader and enable **SciELO** under *Plugin management*
(if `plugins_disable_external` is not set, user plugins are enabled by default).

Example for the desktop emulator:

```sh
ln -s /path/to/scielo.koplugin ~/.config/koreader/plugins/scielo.koplugin
```

## Usage

Open the plugin from the **search** tab of the main menu (both file manager and
reader):

- **Search articles** — enter keywords; results come from Crossref, filtered to
  SciELO DOIs. Tapping a result resolves the DOI to its `www.scielo.br` page,
  shows the article metadata and asks whether to download the PDF.
- **Open article from URL, DOI or code** — paste a `www.scielo.br/j/...` URL, an
  old-style `scielo.php?pid=...` URL, a DOI (`10.1590/...`) or an article code.
- **Go to download folder** — jump to the configured folder in the file manager.

Settings:

- **Download folder** — where PDFs are saved. Set this before the first download.
- **Search results per page** — number of Crossref results to fetch (1–50).

## How it works

- Search uses `https://api.crossref.org/works` with `filter=prefix:10.1590`, since
  `search.scielo.org` is protected by a JavaScript bot challenge.
- DOIs, URLs and article codes are resolved to the canonical
  `www.scielo.br/j/<journal>/a/<id>/` URL by following redirects manually
  (`https://doi.org/...` redirects to an old `scielo.php` URL, which then
  redirects to the new platform; LuaSocket refuses `https` to `http` redirects,
  so the plugin handles them itself).
- Article metadata is parsed from the page's Highwire `citation_*` meta tags.
- The PDF is downloaded from `citation_pdf_url` (typically
  `...?format=pdf`) with LuaSocket/LuaSec and KOReader's socket timeouts.

## ZenOS integration

[ZenOS](https://github.com/xZenLabs/zen-os) detects the plugin as a launchable
plugin menu, so it can be added to the Launcher, Controls, Navbar or Home book
strip (Add > Plugin Menu > SciELO). The dispatcher action "SciELO search" can
be bound to action buttons as well.

The plugin also offers an optional tappable home tile through ZenOS's Home
widget API. It is disabled by default; enable it under
*Zen Settings > Home > Widgets > Search on SciELO*.

## Project layout

```
scielo.koplugin/
├── .github/workflows/release.yml   # Auto-release on every push to main
├── _meta.lua                       # Plugin management name/description
├── LICENSE                         # GPL-3.0
├── main.lua                        # Plugin class: menu, settings, dialogs, download
└── scielo/
    └── client.lua                  # HTTP client: Crossref search, redirects, metadata, PDF
```

## Development

The plugin is pure Lua; no build step is required. For a quick syntax check:

```sh
for f in main.lua _meta.lua scielo/client.lua; do luajit -bl "$f" >/dev/null; done
```

To test with the desktop emulator, symlink the directory into
`~/.config/koreader/plugins/`, restart KOReader, and run it with debug logging
(`koreader -d`) to see plugin output and stack traces in `crash.log`.

## Limitations

- Crossref search covers all SciELO collections, not only Brazil. Results that
  resolve outside `www.scielo.br` are reported and not downloaded.
- Metadata comes from the article page; the JATS XML (`?format=xml`) is not used
  yet, so abstracts are not shown.
- Browsing by journal/issue is not implemented.

## Releases

Every push to `main` triggers the release workflow, which bumps the patch
version, packages the plugin as `scielo.koplugin-<tag>.zip` and publishes a
GitHub release. If a GitHub release ZIP is available, ZenPM uses it to install
the plugin.

## License

[GPL-3.0](LICENSE)
