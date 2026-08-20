const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("MPRIS remaster and feature suffixes are stripped, with the raw title kept as a fallback", () => {
  assert.equal(Model.cleanTitle("Creep - 2011 Remaster"), "Creep")
  assert.equal(Model.cleanTitle("Song Name (Remastered 2015)"), "Song Name")
  assert.equal(Model.cleanTitle("Song Name (feat. Someone)"), "Song Name")
  assert.equal(Model.cleanTitle("Song Name [Explicit]"), "Song Name")
  assert.equal(Model.cleanArtist("Band Name feat. Guest"), "Band Name")
  // Ampersands belong to the artist, not to a feature credit.
  assert.equal(Model.cleanArtist("Simon & Garfunkel"), "Simon & Garfunkel")
  // A title that is only noise must not clean away to nothing.
  assert.equal(Model.cleanTitle("Live"), "Live")

  assert.deepEqual(Model.searchQueries("Radiohead", "Creep - 2011 Remaster"),
    ["Radiohead Creep", "Radiohead Creep - 2011 Remaster"])
  // No fallback query when cleaning changed nothing.
  assert.deepEqual(Model.searchQueries("Radiohead", "Creep"), ["Radiohead Creep"])
})

test("only tab types with a text body are renderable, ranked by the configured preference", () => {
  assert.equal(Model.typeWeight("Official", "tabs"), 0, "official tabs are player binaries")
  assert.equal(Model.typeWeight("Pro", "tabs"), 0)
  assert.equal(Model.typeWeight("Video", "tabs"), 0)
  assert.ok(Model.typeWeight("Tabs", "tabs") > Model.typeWeight("Chords", "tabs"))
  assert.ok(Model.typeWeight("Chords", "chords") > Model.typeWeight("Tabs", "chords"))
  assert.ok(Model.typeWeight("Bass Tabs", "tabs") > 0)
})

test("an instrument can be named by id, by picker label, or by the older wording", () => {
  assert.equal(Model.normalizeInstrument("bass"), "bass")
  assert.equal(Model.normalizeInstrument("Bass"), "bass")
  assert.equal(Model.normalizeInstrument("Guitar chords"), "chords")
  assert.equal(Model.normalizeInstrument("Ukulele"), "ukulele")
  assert.equal(Model.normalizeInstrument("Drums"), "drums")
  // Preferences stored before the picker existed.
  assert.equal(Model.normalizeInstrument("Chord sheets"), "chords")
  assert.equal(Model.normalizeInstrument("Tablature"), "guitar")
  // Anything unrecognised falls back to guitar rather than breaking the lookup.
  assert.equal(Model.normalizeInstrument(""), "guitar")
  assert.equal(Model.normalizeInstrument(undefined), "guitar")
  assert.equal(Model.instrumentLabel("bass"), "Bass")
})

test("tab types are named the way a person would say them", () => {
  // "Tabs" + " tab" reads as nonsense, and "Bass Tabs" is plural for one tab.
  assert.equal(Model.typeLabel("Tabs"), "Guitar tab")
  assert.equal(Model.typeLabel("Chords"), "Guitar chords")
  assert.equal(Model.typeLabel("Bass Tabs"), "Bass tab")
  assert.equal(Model.typeLabel("Ukulele Chords"), "Ukulele chords")
  assert.equal(Model.typeLabel("Drum Tabs"), "Drum tab")
  // Anything unmapped is passed through rather than mangled.
  assert.equal(Model.typeLabel("Video"), "Video")
  assert.equal(Model.typeLabel(""), "")
  assert.equal(Model.typeLabel(null), "")
})

test("the chosen instrument outranks every other type", () => {
  assert.ok(Model.typeWeight("Bass Tabs", "bass") > Model.typeWeight("Tabs", "bass"))
  assert.ok(Model.typeWeight("Ukulele Chords", "ukulele") > Model.typeWeight("Chords", "ukulele"))
  assert.ok(Model.typeWeight("Drum Tabs", "drums") > Model.typeWeight("Tabs", "drums"))
  assert.ok(Model.typeWeight("Chords", "chords") > Model.typeWeight("Tabs", "chords"))
  // Within an instrument, the first listed type wins.
  assert.ok(Model.typeWeight("Tabs", "guitar") > Model.typeWeight("Power", "guitar"))

  const bass = { song: "Creep", artist: "Radiohead", type: "Bass Tabs", rating: 4.0, votes: 40 }
  const guitar = { song: "Creep", artist: "Radiohead", type: "Tabs", rating: 5, votes: 90000 }
  assert.equal(Model.pickBest([guitar, bass], "Radiohead", "Creep", "bass"), bass,
    "a modest bass tab still beats a great guitar one when bass was asked for")
  assert.equal(Model.pickBest([guitar, bass], "Radiohead", "Creep", "guitar"), guitar)
})

test("a song nobody tabbed for that instrument falls back instead of showing nothing", () => {
  const guitar = { song: "Creep", artist: "Radiohead", type: "Tabs", rating: 4.7, votes: 5000 }
  assert.equal(Model.pickBest([guitar], "Radiohead", "Creep", "bass"), guitar)
  assert.equal(Model.pickBest([guitar], "Radiohead", "Creep", "drums"), guitar)
})

test("a well-voted tab beats a thinly-voted perfect score", () => {
  const popular = { song: "Creep", artist: "Radiohead", type: "Tabs", rating: 4.6, votes: 40000 }
  const untested = { song: "Creep", artist: "Radiohead", type: "Tabs", rating: 5, votes: 2 }
  const results = [untested, popular]
  assert.equal(Model.pickBest(results, "Radiohead", "Creep", "tabs"), popular)
})

test("the preferred type wins even when another type is rated higher", () => {
  const chords = { song: "Creep", artist: "Radiohead", type: "Chords", rating: 4.9, votes: 40000 }
  const tabs = { song: "Creep", artist: "Radiohead", type: "Tabs", rating: 4.2, votes: 900 }
  assert.equal(Model.pickBest([chords, tabs], "Radiohead", "Creep", "tabs"), tabs)
  assert.equal(Model.pickBest([chords, tabs], "Radiohead", "Creep", "chords"), chords)
})

test("a matching artist outranks a same-titled song by someone else", () => {
  const cover = { song: "Creep", artist: "Some Cover Band", type: "Tabs", rating: 5, votes: 90000 }
  const original = { song: "Creep", artist: "Radiohead", type: "Tabs", rating: 4.1, votes: 30 }
  assert.equal(Model.pickBest([cover, original], "Radiohead", "Creep", "tabs"), original)
})

test("nothing is picked when no result is the song that is playing", () => {
  const other = { song: "A Different Song", artist: "Radiohead", type: "Tabs", rating: 5, votes: 5000 }
  assert.equal(Model.pickBest([other], "Radiohead", "Creep", "tabs"), null)
  assert.equal(Model.pickBest([], "Radiohead", "Creep", "tabs"), null)
  assert.equal(Model.pickBest(null, "Radiohead", "Creep", "tabs"), null)
})

test("only renderable versions reach the version dropdown, best first", () => {
  const ug = "https://tabs.ultimate-guitar.com/tab/a/"
  const versions = [
    { type: "Official", version: 1, rating: 5, votes: 10000, url: ug + "official-1" },
    { type: "Chords", version: 2, rating: 4.8, votes: 4000, url: ug + "chords-2" },
    { type: "Tabs", version: 3, rating: 4.1, votes: 100, url: ug + "tabs-3" },
    { type: "Tabs", version: 4, rating: 4.9, votes: 8000, url: ug + "tabs-4" },
    { type: "Chords", version: 5, rating: 5, votes: 1, url: "" }
  ]
  const ranked = Model.renderableVersions(versions, "tabs")
  assert.deepEqual(ranked.map(v => v.version), [4, 3, 2], "no official, no url-less entry")
})

test("chord markers become colored spans and every alignment space survives", () => {
  const rendered = Model.renderTab("[ch]Am[/ch]  [ch]G[/ch]\nplaceholder words", "#ff0000")
  assert.equal(rendered,
    '<span style="color:#ff0000">Am</span>&nbsp;&nbsp;' +
    '<span style="color:#ff0000">G</span><br/>placeholder&nbsp;words')
})

test("tab block markers are dropped without disturbing the notation inside", () => {
  assert.equal(Model.renderTab("[tab]e|--0--|[/tab]", "#fff"), "e|--0--|")
  assert.equal(Model.plainTab("[tab][ch]Am[/ch] e|--0--|[/tab]"), "Am e|--0--|")
})

test("tab text cannot inject markup into the rich text view", () => {
  const rendered = Model.renderTab("<script>alert(1)</script> & \"quotes\"", "#fff")
  assert.ok(!rendered.includes("<script>"))
  assert.ok(rendered.includes("&lt;script&gt;"))
  assert.ok(rendered.includes("&amp;"))
})

test("an unclosed chord marker colors the rest instead of throwing", () => {
  assert.equal(Model.renderTab("[ch]Am", "#fff"), '<span style="color:#fff">Am</span>')
  assert.equal(Model.renderTab("[/ch]Am", "#fff"), "Am")
  assert.equal(Model.renderTab("", "#fff"), "")
  assert.equal(Model.renderTab(null, "#fff"), "")
})

test("the reader gets one entry per line, rich only where chords appear", () => {
  const lines = Model.tabLines("[ch]Am[/ch] here\n[tab]e|--0--|[/tab]\n", "#f00")
  assert.equal(lines.length, 3, "trailing newline keeps its empty line")
  assert.deepEqual(lines[0], { text: '<span style="color:#f00">Am</span>&nbsp;here', rich: true })
  assert.deepEqual(lines[1], { text: "e|--0--|", rich: false })
  assert.deepEqual(lines[2], { text: "", rich: false })

  // Plain tablature must not pay for rich text at all.
  const tab = Model.tabLines("e|--0--|\nB|--2--|", "#f00")
  assert.ok(tab.every(l => l.rich === false))

  assert.deepEqual(Model.tabLines("", "#f00"), [{ text: "", rich: false }])
  assert.deepEqual(Model.tabLines(null, "#f00"), [{ text: "", rich: false }])
})

test("the widest line is measured without its markup", () => {
  assert.equal(Model.longestLine("ab\nabcd\nabc"), "abcd")
  // Markers would otherwise make a short line look like the widest one.
  assert.equal(Model.longestLine("[ch]Am[/ch]\nabcdef"), "abcdef")
  assert.equal(Model.longestLine(""), "")
})

test("vote counts and metadata read the way they do on the site", () => {
  assert.equal(Model.formatVotes(43754), "43.8k")
  assert.equal(Model.formatVotes(4797), "4.8k")
  assert.equal(Model.formatVotes(414), "414")
  assert.equal(Model.formatRating(4.87157, 43754), "★4.9 (43.8k)")
  assert.equal(Model.formatRating(0, 0), "")

  assert.equal(
    Model.metaLine({ type: "Chords", version: 1, rating: 4.87157, votes: 43754, key: "G",
                     capo: 0, tuningName: "Standard", tuning: "E A D G B E", difficulty: "novice" }),
    "Chords · Ver 1 · ★4.9 (43.8k) · Key G · E A D G B E · novice")
  assert.equal(
    Model.metaLine({ type: "Tabs", version: 2, capo: 2, tuningName: "Drop D" }),
    "Tabs · Ver 2 · Capo 2 · Drop D tuning")
  assert.equal(Model.metaLine(null), "")
})

test("only Ultimate Guitar's own URLs are handed to the browser", () => {
  const ok = "https://tabs.ultimate-guitar.com/tab/tool/sober-tabs-1"
  assert.equal(Model.externalUrl(ok), ok)
  assert.ok(Model.isAllowedUrl("https://ultimate-guitar.com/x"))
  assert.ok(Model.isAllowedUrl("https://www.ultimate-guitar.com/search.php?value=x"))

  // The panel labels these controls as Ultimate Guitar links, so anything else
  // must come back empty rather than being opened under that label.
  for (const bad of ["http://tabs.ultimate-guitar.com/x",
                     "https://evil.example/x",
                     "https://notultimate-guitar.com/x",
                     "https://ultimate-guitar.com.evil.example/x",
                     "https://evil.example/?next=https://ultimate-guitar.com/x",
                     "https://evil.example@ultimate-guitar.com.attacker/x",
                     "file:///etc/passwd",
                     "javascript:alert(1)",
                     "",
                     null]) {
    assert.equal(Model.externalUrl(bad), "", String(bad))
    assert.equal(Model.isAllowedUrl(bad), false, String(bad))
  }
})

test("a version pointing off-site never reaches the dropdown", () => {
  const versions = [
    { type: "Tabs", version: 1, rating: 4.5, votes: 100, url: "https://tabs.ultimate-guitar.com/tab/a-1" },
    { type: "Tabs", version: 2, rating: 5, votes: 900, url: "https://evil.example/tab/a-2" },
  ]
  const ranked = Model.renderableVersions(versions, "guitar")
  assert.deepEqual(ranked.map(v => v.version), [1])
})

test("the fallback search link points at the cleaned query", () => {
  assert.equal(Model.searchPageUrl("Radiohead", "Creep - 2011 Remaster"),
    "https://www.ultimate-guitar.com/search.php?search_type=title&value=Radiohead%20Creep")
})

test("an ampersand in a track title matches the spelled-out catalogue entry", () => {
  // Players report "Forty Six & 2"; Ultimate Guitar files it as "Forty Six And 2".
  assert.equal(Model.normalize("Forty Six & 2"), "forty six and 2")
  assert.ok(Model.looseMatch("Forty Six & 2", "Forty Six And 2"))
  assert.ok(Model.looseMatch("Simon & Garfunkel", "Simon and Garfunkel"))

  const tab = { song: "Forty Six And 2", artist: "Tool", type: "Tabs", rating: 4.8, votes: 900 }
  assert.equal(Model.pickBest([tab], "TOOL", "Forty Six & 2", "tabs"), tab)
})

test("accents and punctuation do not stop a title from matching", () => {
  assert.ok(Model.looseMatch("Café del Mar", "Cafe del Mar"))
  assert.ok(Model.looseMatch("Don't Stop", "Dont Stop"))
  assert.ok(Model.looseMatch("Creep", "Creep (Acoustic)"))
  assert.ok(!Model.looseMatch("Creep", "Karma Police"))
  assert.ok(!Model.looseMatch("", "Creep"))
})

test("text handed to shell-drawn components cannot look like markup", () => {
  // The bar tooltip and the dropdown labels are rendered by the shell, whose
  // Text elements use QML's markup-sniffing default. Angle brackets are what
  // makes Qt switch a string to rich text, so they must not survive.
  assert.equal(Model.safeDisplayText('<img src="https://evil.example/x">'),
    'img src="https://evil.example/x"')
  assert.equal(Model.safeDisplayText("<b>bold</b>"), "bbold/b")
  assert.ok(!Model.safeDisplayText("a <tag> b").includes("<"))
  assert.ok(!Model.safeDisplayText("a <tag> b").includes(">"))

  // Ordinary text, including newlines the tooltip relies on, is left alone.
  assert.equal(Model.safeDisplayText("Artist \u2014 Song\nSecond line"),
    "Artist \u2014 Song\nSecond line")
  assert.equal(Model.safeDisplayText("Me & You"), "Me & You")
  assert.equal(Model.safeDisplayText(""), "")
  assert.equal(Model.safeDisplayText(null), "")
  assert.equal(Model.safeDisplayText(undefined), "")
})

test("a crafted tab type cannot smuggle markup into a dropdown label", () => {
  const version = { type: '<img src=x>', version: 3, rating: 4.5, votes: 10 }
  const label = Model.versionLabel(version)
  assert.ok(!label.includes("<"), label)
  assert.ok(!label.includes(">"), label)
  assert.ok(!Model.typeLabel("<img src=x>").includes("<"))
})
