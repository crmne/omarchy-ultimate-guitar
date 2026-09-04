# Copilot instructions

Read `README.md` and `manifest.json` in full before reviewing or changing this
repository. Keep this a focused Omarchy Quattro plugin that shows publicly
available Ultimate Guitar text tabs for the current MPRIS track. Preserve
existing behavior unless the task explicitly changes it.

## Architecture and ownership

- `Service.qml` is the single persistent service. It selects the active MPRIS
  player, owns the lookup state machine, debounces track changes, invokes the
  helper, rejects stale results with serials, exposes the IPC contract, and
  opens validated links. A lookup should happen once per song even when several
  monitors instantiate `BarWidget.qml`.
- `Model.js` contains pure query cleanup, catalogue matching and ranking,
  instrument fallback, safe display shaping, URL validation, and tab rendering.
  Keep it free of QML types and compatible with both QML JavaScript and
  CommonJS so Node can test it directly.
- `bin/ug-tabs` is the only network and page-parsing layer. It uses Python's
  standard library, extracts Ultimate Guitar's embedded page state, returns one
  JSON object on stdout, and owns the search and tab caches.
- `BarWidget.qml` owns the bar entry, click behavior, and popup geometry.
  `TabView.qml` owns reader presentation, version and instrument selection,
  preferences, virtualized tab lines, and auto-scroll. Neither should fetch
  the network or duplicate the service state machine.
- `basecamp/omarchy` owns the Quattro host, plugin loader, bar and popup APIs,
  common QML controls, browser launcher, and shell lifecycle. Fix host defects
  there rather than patching packaged Omarchy files from this plugin.
- Media players own the MPRIS metadata they publish. Ultimate Guitar owns its
  catalogue, contributed tab content, and page format.
  `omacom/omarchy-plugin-marketplace` owns marketplace publication.

## Security and product boundaries

- Treat MPRIS metadata, embedded page state, tab content, version metadata,
  artwork URLs, error text, cached JSON, and redirect targets as untrusted.
- Network requests are HTTPS-only and limited to `ultimate-guitar.com` and its
  subdomains. The strict whole-URL guards in `Model.js` and `bin/ug-tabs` must
  agree and must reject userinfo, ports, backslashes, whitespace, non-HTTPS
  schemes, lookalike domains, loopback, private services, and other hosts.
  Revalidate every redirect hop and every URL immediately before fetching or
  handing it to `omarchy-launch-browser`.
- Keep remote text as `Text.PlainText` wherever possible. The deliberate rich
  text path may contain only escaped tab text plus plugin-generated chord
  spans. Preserve `safeDisplayText` for shell-owned tooltips and dropdowns,
  whose text format the plugin cannot control. Never interpret remote data as
  QML, arbitrary HTML, a command, or a local file path.
- Official and Pro tabs are binary, interactive content that only Ultimate
  Guitar's player renders. Keep them browser-only. Do not add authentication,
  paywall bypasses, DRM circumvention, headless browsers, private APIs, bulk
  downloading, or redistribution of contributed tabs.
- Preserve the dependency boundary: `/usr/bin/python3` plus the standard
  library, with no account, API key, helper daemon, or extra package. Do not run
  network or subprocess work synchronously on the shell UI thread.

## Behavior to preserve

- Player selection ignores stopped or titleless entries, prefers a playing
  non-`playerctld` source, and uses other candidates only as a fallback.
  Track changes are debounced so rapid skipping costs one lookup.
- Every asynchronous search or tab load is tied to the serial under which it
  started. Results for a previous track or instrument must never replace the
  current view. Refresh bypasses the cache for the requested lookup without
  making later unrelated lookups permanently uncached.
- Search tries cleaned MPRIS metadata first and the verbatim query only as a
  fallback. Ranking must require a plausible song match, strongly prefer the
  requested instrument and matching artist, and weight ratings by vote count.
  Songs without the chosen instrument fall back to readable guitar material.
- Only Tabs, Chords, Bass Tabs, Ukulele Chords, Drum Tabs, and Power content are
  rendered. Version menus must exclude unrenderable, URL-less, and off-site
  entries. The header must name the type actually selected.
- Preserve exact tab columns. Chord and tab markers are the only recognized
  markup, spacing does not collapse, lines do not wrap, and manual horizontal
  scrolling remains available.
- Long tabs stay responsive by using one reusable `ListView` delegate per line
  and rich text only on lines containing chords. Avoid rebuilding an entire tab
  as one rich-text item or measuring layout in a geometry feedback loop.
- Manual scrolling stops auto-scroll. Auto-scroll stops when the reader is
  hidden, the tab changes, or the end is reached. A new tab resets both axes.
- Preferences at
  `~/.local/state/omarchy/settings/ultimate-guitar.json` remain backward
  compatible and limited to reading preferences. Bar settings seed the
  instrument until the reader owns a persisted choice.
- Keep left click opening the reader, right click opening the current tab or
  search page, and middle click refreshing without cache. IPC methods and their
  `ok` or `unhandled` results are a compatibility surface.
- `manifest.json` defaults, schema types and ranges, QML fallbacks and clamps,
  and README behavior must agree. Do not bump the version, create a tag, or
  change marketplace state unless the task is explicitly a release.

## Validation

Run the complete local suite:

```bash
node --test tests/model.test.js
python3 -m unittest discover -s tests
python3 -m py_compile bin/ug-tabs
qmllint BarWidget.qml Service.qml TabView.qml
omarchy plugin validate .
jq empty manifest.json
git diff --check
```

Add focused regression tests for matching, rendering, state ordering, remote
text handling, and every URL-guard change. Security tests must exercise both
the JavaScript browser boundary and the Python fetch/redirect boundary. Visual
or interaction changes need evidence for compact and expanded readers, narrow
and wide screens, long and short tabs, light and dark themes, and missing
artwork or metadata.

## Review communication

Lead with concrete defects introduced by the change. Separate confirmed plugin
bugs from media-player metadata, Omarchy host behavior, catalogue content, and
Ultimate Guitar page-format changes. Avoid adjacent redesigns, internal
investigation diaries, and claims about checks or environments not exercised.
