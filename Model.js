// Pure helpers for the Ultimate Guitar bar widget: turning MPRIS metadata into
// a usable search query, picking which of the ~50 results to show, and turning
// Ultimate Guitar's tab markup into Qt rich text.
//
// Kept free of QML types so `node --test tests/model.test.js` can exercise the
// matching and rendering rules directly.

// Types whose content is plain text we can render. "Pro" and "Official" tabs
// are Guitar Pro-style binaries driven by Ultimate Guitar's own player, and
// "Video" is a lesson link -- none of them have a text body to show.
var RENDERABLE_TYPES = ["Tabs", "Chords", "Bass Tabs", "Ukulele Chords", "Drum Tabs", "Power"]

// Junk MPRIS metadata carries that Ultimate Guitar's catalogue never has.
var BRACKETED_NOISE = /\s*[([][^)\]]*\b(remaster(ed)?|remix|live|acoustic|version|edit|mix|mono|stereo|deluxe|bonus|expanded|explicit|anniversary|feat\.?|featuring|with)\b[^)\]]*[)\]]/gi
var TRAILING_NOISE = /\s+-\s+.*\b(remaster(ed)?|radio edit|single version|album version|live|mono|stereo|re-?recorded|\d{4}\s+version)\b.*$/i
var FEATURING = /\s+[-(]?\s*\b(feat|ft|featuring)\b\.?\s+.*$/i

function normalize(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .replace(/['\u2019`]/g, "")
    // Ultimate Guitar spells out what players abbreviate: a track called
    // "Forty Six & 2" is filed as "Forty Six And 2".
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
}

function cleanTitle(title) {
  var cleaned = String(title || "")
    .replace(BRACKETED_NOISE, "")
    .replace(TRAILING_NOISE, "")
    .replace(FEATURING, "")
    .trim()
  return cleaned || String(title || "").trim()
}

function cleanArtist(artist) {
  var cleaned = String(artist || "").replace(FEATURING, "").trim()
  return cleaned || String(artist || "").trim()
}

// Ultimate Guitar's title search matches "artist song" well, but MPRIS titles
// often carry remaster/version suffixes it has never heard of. Try the tidied
// query first and keep the verbatim one as a fallback.
function searchQueries(artist, title) {
  var queries = []
  var tidy = (cleanArtist(artist) + " " + cleanTitle(title)).trim()
  var verbatim = (String(artist || "") + " " + String(title || "")).trim()
  if (tidy) queries.push(tidy)
  if (verbatim && normalize(verbatim) !== normalize(tidy)) queries.push(verbatim)
  return queries
}

// What the reader can be pointed at, in the order the picker lists them. Each
// maps to the Ultimate Guitar types that count as that instrument, best first.
// These are exactly the types that carry a text body -- there is nothing to
// point at for piano or vocals, because those are Pro tabs.
var INSTRUMENTS = [
  { id: "guitar", label: "Guitar tab", types: ["Tabs", "Power"] },
  { id: "chords", label: "Guitar chords", types: ["Chords"] },
  { id: "bass", label: "Bass", types: ["Bass Tabs"] },
  { id: "ukulele", label: "Ukulele", types: ["Ukulele Chords"] },
  { id: "drums", label: "Drums", types: ["Drum Tabs"] }
]

// Accepts an id, the label shown in the picker, or the older tablature/chords
// wording, so a stored preference keeps working.
function normalizeInstrument(value) {
  var wanted = String(value || "").toLowerCase().trim()
  for (var i = 0; i < INSTRUMENTS.length; i++) {
    if (wanted === INSTRUMENTS[i].id || wanted === INSTRUMENTS[i].label.toLowerCase()) {
      return INSTRUMENTS[i].id
    }
  }
  if (wanted.indexOf("bass") !== -1) return "bass"
  if (wanted.indexOf("ukulele") !== -1) return "ukulele"
  if (wanted.indexOf("drum") !== -1) return "drums"
  if (wanted.indexOf("chord") !== -1) return "chords"
  return "guitar"
}

function instrumentFor(value) {
  var id = normalizeInstrument(value)
  for (var i = 0; i < INSTRUMENTS.length; i++) {
    if (INSTRUMENTS[i].id === id) return INSTRUMENTS[i]
  }
  return INSTRUMENTS[0]
}

function instrumentLabel(value) {
  return instrumentFor(value).label
}

// Ultimate Guitar's own type names do not read as English on their own:
// "Tabs" + " tab" is nonsense, and "Bass Tabs" is plural for one tab.
function typeLabel(type) {
  switch (String(type || "")) {
  case "Tabs": return "Guitar tab"
  case "Chords": return "Guitar chords"
  case "Bass Tabs": return "Bass tab"
  case "Ukulele Chords": return "Ukulele chords"
  case "Drum Tabs": return "Drum tab"
  case "Power": return "Power chords"
  case "Official": return "Official tab"
  }
  return String(type || "")
}

function typeWeight(type, instrument) {
  var candidate = String(type || "")
  if (RENDERABLE_TYPES.indexOf(candidate) === -1) return 0
  var chosen = instrumentFor(instrument).types.indexOf(candidate)
  if (chosen !== -1) return 100 - chosen * 10
  // Not the instrument that was asked for, but still readable. Plenty of songs
  // have never been tabbed for bass or ukulele, and a guitar tab beats an empty
  // panel; the type is named in the header, so the fallback is visible.
  if (candidate === "Tabs" || candidate === "Chords") return 5
  return 1
}

function looseMatch(left, right) {
  var a = normalize(left)
  var b = normalize(right)
  if (!a || !b) return false
  return a === b || a.indexOf(b) !== -1 || b.indexOf(a) !== -1
}

// A five-star tab with 3 votes is not better than a 4.8 with 40,000; weight the
// rating by how much of it we can believe.
function confidence(rating, votes) {
  var count = Math.max(0, Number(votes) || 0)
  return (Number(rating) || 0) * (count / (count + 25))
}

function scoreResult(result, artist, title, prefer) {
  if (!result) return -1
  var weight = typeWeight(result.type, prefer)
  if (!weight) return -1
  if (!looseMatch(result.song, cleanTitle(title))) return -1
  var score = weight * 1000 + confidence(result.rating, result.votes) * 100
  if (looseMatch(result.artist, cleanArtist(artist))) score += 10000
  if (result.verified) score += 25
  return score
}

function pickBest(results, artist, title, prefer) {
  var best = null
  var bestScore = -1
  var list = results || []
  for (var i = 0; i < list.length; i++) {
    var score = scoreResult(list[i], artist, title, prefer)
    if (score > bestScore) {
      best = list[i]
      bestScore = score
    }
  }
  return bestScore < 0 ? null : best
}

// Versions Ultimate Guitar lists for the tab we are showing, in the order the
// dropdown should present them: renderable ones first, best first.
function renderableVersions(versions, prefer) {
  var list = (versions || []).filter(function (version) {
    return typeWeight(version.type, prefer) > 0 && version.url
  })
  return list.sort(function (a, b) {
    var delta = typeWeight(b.type, prefer) - typeWeight(a.type, prefer)
    if (delta !== 0) return delta
    return confidence(b.rating, b.votes) - confidence(a.rating, a.votes)
  })
}

function formatVotes(votes) {
  var count = Math.max(0, Number(votes) || 0)
  if (count >= 10000) return (count / 1000).toFixed(1).replace(/\.0$/, "") + "k"
  if (count >= 1000) return (count / 1000).toFixed(1) + "k"
  return String(count)
}

function formatRating(rating, votes) {
  if (!Number(rating)) return ""
  return "★" + (Number(rating).toFixed(1)) + " (" + formatVotes(votes) + ")"
}

function versionLabel(version) {
  if (!version) return ""
  var parts = []
  if (Number(version.version)) parts.push("Ver " + version.version)
  if (version.type) parts.push(version.type)
  var rating = formatRating(version.rating, version.votes)
  if (rating) parts.push(rating)
  return parts.join(" · ")
}

function metaLine(tab) {
  if (!tab) return ""
  var parts = []
  if (tab.type) parts.push(tab.type)
  if (Number(tab.version)) parts.push("Ver " + tab.version)
  var rating = formatRating(tab.rating, tab.votes)
  if (rating) parts.push(rating)
  if (tab.key) parts.push("Key " + tab.key)
  if (Number(tab.capo)) parts.push("Capo " + tab.capo)
  if (tab.tuningName && tab.tuningName !== "Standard") parts.push(tab.tuningName + " tuning")
  else if (tab.tuning) parts.push(tab.tuning)
  if (tab.difficulty) parts.push(tab.difficulty)
  return parts.join(" · ")
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

// Chord sheets and tablature both align on exact column positions, so every
// space has to survive as a non-breaking one and nothing may wrap.
function renderSegment(piece, isChord, chordColor) {
  if (!piece) return ""
  var body = escapeHtml(piece).replace(/ /g, "&nbsp;").replace(/\n/g, "<br/>")
  return isChord ? '<span style="color:' + chordColor + '">' + body + "</span>" : body
}

// Ultimate Guitar wraps chord names in [ch]...[/ch] and tablature blocks in
// [tab]...[/tab]. Chords become colored spans; the block markers just go away.
function renderTab(content, chordColor) {
  var text = String(content || "").replace(/\r\n/g, "\n")
  var markers = /\[(\/?)(ch|tab)\]/g
  var rendered = ""
  var depth = 0
  var cursor = 0
  var match
  while ((match = markers.exec(text)) !== null) {
    rendered += renderSegment(text.slice(cursor, match.index), depth > 0, chordColor)
    if (match[2] === "ch") depth = match[1] ? Math.max(0, depth - 1) : depth + 1
    cursor = markers.lastIndex
  }
  return rendered + renderSegment(text.slice(cursor), depth > 0, chordColor)
}

function plainTab(content) {
  return String(content || "").replace(/\[\/?(ch|tab)\]/g, "")
}

// One entry per line, so the reader can hand them to a ListView and lay out
// only the handful of lines actually on screen. Rendering a whole tab as a
// single rich text item costs seconds on long tablature, and Qt pays that cost
// again every time the popup is shown.
//
// Only lines that actually carry chords need rich text; plain tablature lines
// are far cheaper to lay out as plain text.
function tabLines(content, chordColor) {
  var raw = String(content || "").replace(/\r\n/g, "\n").split("\n")
  var lines = []
  for (var i = 0; i < raw.length; i++) {
    var hasChords = raw[i].indexOf("[ch]") !== -1
    lines.push({
      text: hasChords ? renderTab(raw[i], chordColor) : plainTab(raw[i]),
      rich: hasChords
    })
  }
  return lines
}

// The widest line decides how far the reader can pan sideways. Tabs are
// monospaced, so the longest line is also the widest one.
function longestLine(content) {
  // Ultimate Guitar serves CRLF, and a stray carriage return both inflates the
  // count by one and confuses the metrics that size the panel.
  var lines = plainTab(content).replace(/\r\n/g, "\n").split("\n")
  var longest = ""
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].length > longest.length) longest = lines[i]
  }
  return longest
}

function searchPageUrl(artist, title) {
  var query = (cleanArtist(artist) + " " + cleanTitle(title)).trim()
  return "https://www.ultimate-guitar.com/search.php?search_type=title&value=" + encodeURIComponent(query)
}

if (typeof module !== "undefined") {
  module.exports = {
    RENDERABLE_TYPES: RENDERABLE_TYPES,
    normalize: normalize,
    cleanTitle: cleanTitle,
    cleanArtist: cleanArtist,
    searchQueries: searchQueries,
    INSTRUMENTS: INSTRUMENTS,
    normalizeInstrument: normalizeInstrument,
    instrumentFor: instrumentFor,
    instrumentLabel: instrumentLabel,
    typeLabel: typeLabel,
    typeWeight: typeWeight,
    looseMatch: looseMatch,
    confidence: confidence,
    scoreResult: scoreResult,
    pickBest: pickBest,
    renderableVersions: renderableVersions,
    formatVotes: formatVotes,
    formatRating: formatRating,
    versionLabel: versionLabel,
    metaLine: metaLine,
    escapeHtml: escapeHtml,
    renderTab: renderTab,
    plainTab: plainTab,
    tabLines: tabLines,
    longestLine: longestLine,
    searchPageUrl: searchPageUrl
  }
}
