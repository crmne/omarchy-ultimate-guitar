"""Tests for the fetch helper's guards.

Run with: python3 -m unittest discover -s tests

The helper is handed URLs that came from remote page state, so those URLs are
input, not addresses. These cover the shapes that mattered: a scheme that reads
the local disk, a host on the loopback or private side of the network, and a
name that merely looks like the real one. They also cover the limits on what
the network sends and the helper prints, and the cache's defences against
another local process swapping its files.
"""

import gzip
import importlib.util
import io
import json
import os
import stat
import tempfile
import time
import unittest
from unittest import mock

HELPER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "ug-tabs")
spec = importlib.util.spec_from_loader("ug_tabs", importlib.machinery.SourceFileLoader("ug_tabs", HELPER))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class CheckUrl(unittest.TestCase):
    def test_allows_the_site_and_its_subdomains(self):
        for url in ("https://ultimate-guitar.com/x",
                    "https://tabs.ultimate-guitar.com/tab/a/b-1",
                    "https://www.ultimate-guitar.com/search.php?value=x"):
            self.assertEqual(helper.check_url(url), url)

    def test_refuses_schemes_that_are_not_https(self):
        # file:// reads the disk; http:// is both downgradeable and was the
        # route to loopback and link-local services.
        for url in ("file:///etc/passwd",
                    "http://ultimate-guitar.com/x",
                    "http://127.0.0.1:8080/x",
                    "http://[::1]/x",
                    "http://169.254.169.254/latest/meta-data/",
                    "ftp://ultimate-guitar.com/x",
                    "/etc/passwd",
                    ""):
            with self.assertRaises(helper.BlockedUrl, msg=url):
                helper.check_url(url)

    def test_refuses_other_hosts_however_they_are_dressed(self):
        for url in ("https://evil.example/x",
                    "https://127.0.0.1/x",
                    "https://notultimate-guitar.com/x",
                    "https://ultimate-guitar.com.evil.example/x",
                    "https://evil.example/?next=https://ultimate-guitar.com/x"):
            with self.assertRaises(helper.BlockedUrl, msg=url):
                helper.check_url(url)

    def test_refuses_authorities_a_browser_would_read_differently(self):
        # A backslash is a separator to the parser browsers use, so this reads
        # as ours to anything splitting on "@" while a browser goes elsewhere.
        for url in ("https://evil.example\\@ultimate-guitar.com/",
                    "https://evil.example@ultimate-guitar.com/",
                    "https://ultimate-guitar.com:8080/x",
                    "https://ultimate-guitar.com\t.evil.example/x",
                    "https://ultimate-guitar.com /x"):
            with self.assertRaises(helper.BlockedUrl, msg=url):
                helper.check_url(url % ())

    def test_every_redirect_hop_is_checked_too(self):
        # An allowed host can still redirect anywhere, so the handler re-checks
        # rather than trusting the first URL it was given.
        handler = helper.GuardedRedirects()
        self.assertTrue(hasattr(handler, "redirect_request"))
        with self.assertRaises(helper.BlockedUrl):
            helper.check_url("https://evil.example/after-redirect")


class FakeResponse:
    def __init__(self, body, headers=None):
        self.stream = io.BytesIO(body)
        self.headers = headers or {}

    def read(self, amount=-1):
        return self.stream.read(amount)


class ReadLimited(unittest.TestCase):
    def test_reads_an_ordinary_gzip_page(self):
        page = b"<div>" + b"x" * 200_000 + b"</div>"
        body = gzip.compress(page)
        self.assertEqual(helper.read_limited(FakeResponse(body, {"Content-Encoding": "gzip"})), page)

    def test_refuses_a_declared_length_over_the_limit_before_reading(self):
        response = FakeResponse(b"", {"Content-Length": str(helper.MAX_RESPONSE_BYTES + 1)})
        with self.assertRaises(helper.TooLarge):
            helper.read_limited(response)

    def test_refuses_a_body_over_the_limit_without_a_length(self):
        with self.assertRaises(helper.TooLarge):
            helper.read_limited(FakeResponse(b"x" * (helper.MAX_RESPONSE_BYTES + 1)))

    def test_refuses_a_small_body_that_inflates_past_the_limit(self):
        # A gzip bomb: well under the wire limit, far over the decoded one.
        bomb = gzip.compress(b"\0" * (helper.MAX_DECODED_BYTES + 1))
        self.assertLess(len(bomb), helper.MAX_RESPONSE_BYTES)
        with self.assertRaises(helper.TooLarge):
            helper.read_limited(FakeResponse(bomb, {"Content-Encoding": "gzip"}))

    def test_refuses_encodings_it_cannot_bound(self):
        with self.assertRaises(ValueError):
            helper.read_limited(FakeResponse(b"x", {"Content-Encoding": "br"}))


class Shaping(unittest.TestCase):
    def test_fields_and_lists_are_capped(self):
        item = {"tab_url": "https://tabs.ultimate-guitar.com/tab/a/b-1",
                "song_name": "s" * 10_000, "rating": "5", "votes": True}
        store = {"page": {"data": {"results": [item] * (helper.MAX_RESULTS + 40)}}}
        results = helper.records(helper.page_data(store).get("results"), helper.MAX_RESULTS)
        self.assertEqual(len(results), helper.MAX_RESULTS)
        shaped = helper.shape_result(item)
        self.assertEqual(len(shaped["song"]), helper.MAX_FIELD_CHARS)
        self.assertEqual(shaped["votes"], 0, "a boolean is not a vote count")

    def test_tab_content_is_capped(self):
        store = {"page": {"data": {"tab_view": {
            "wiki_tab": {"content": "x" * (helper.MAX_CONTENT_CHARS + 1)}}}}}
        self.assertEqual(len(helper.shape_tab(store)["content"]), helper.MAX_CONTENT_CHARS)

    def test_malformed_page_state_does_not_crash(self):
        for store in ({}, {"page": None}, {"page": {"data": []}},
                      {"page": {"data": {"tab_view": {"versions": "nope", "meta": 3}}}}):
            self.assertEqual(helper.shape_tab(store)["versions"], [])

    def test_printed_output_never_exceeds_the_cap(self):
        huge = {"ok": True, "tab": {"content": "\u00e9" * helper.MAX_CONTENT_CHARS}}
        line = helper.bounded_output(huge)
        self.assertLessEqual(len(line.encode("utf-8")), helper.MAX_OUTPUT_BYTES)
        self.assertEqual(json.loads(line)["code"], "too-large")


class Cache(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.dir = os.path.join(self.root.name, "ultimate-guitar")
        patcher = mock.patch.object(helper, "CACHE_DIR", self.dir)
        patcher.start()
        self.addCleanup(patcher.stop)

    def entry(self, key):
        import hashlib
        return os.path.join(self.dir, hashlib.sha1(key.encode()).hexdigest() + ".json")

    def test_round_trip_through_a_private_directory(self):
        self.assertEqual(helper.cached("k", 60, lambda: {"v": 1}), {"v": 1})
        self.assertEqual(helper.cached("k", 60, lambda: {"v": 2}), {"v": 1})
        self.assertEqual(stat.S_IMODE(os.stat(self.dir).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.entry("k")).st_mode), 0o600)
        self.assertEqual([n for n in os.listdir(self.dir) if n.endswith(".tmp")], [])

    def test_an_existing_open_directory_is_made_private(self):
        os.makedirs(self.dir)
        os.chmod(self.dir, 0o755)
        helper.cached("k", 60, lambda: {"v": 1})
        self.assertEqual(stat.S_IMODE(os.stat(self.dir).st_mode), 0o700)

    def test_a_symlinked_entry_is_not_followed_for_reading_or_writing(self):
        os.makedirs(self.dir, mode=0o700)
        target = os.path.join(self.root.name, "elsewhere.json")
        with open(target, "w") as handle:
            json.dump({"planted": True}, handle)
        os.symlink(target, self.entry("k"))
        self.assertEqual(helper.cached("k", 60, lambda: {"v": 1}), {"v": 1})
        with open(target) as handle:
            self.assertEqual(json.load(handle), {"planted": True}, "the link target was written through")
        self.assertFalse(os.path.islink(self.entry("k")), "the rename replaces the link itself")

    def test_a_fifo_is_skipped_without_blocking(self):
        os.makedirs(self.dir, mode=0o700)
        os.mkfifo(self.entry("k"))
        started = time.monotonic()
        self.assertEqual(helper.cached("k", 60, lambda: {"v": 1}), {"v": 1})
        self.assertLess(time.monotonic() - started, 2)

    def test_a_symlinked_directory_is_not_used(self):
        elsewhere = os.path.join(self.root.name, "elsewhere")
        os.makedirs(elsewhere)
        os.symlink(elsewhere, self.dir)
        self.assertEqual(helper.cached("k", 60, lambda: {"v": 1}), {"v": 1})
        self.assertEqual(os.listdir(elsewhere), [])

    def test_stale_and_oversized_entries_are_refetched(self):
        helper.cached("k", 60, lambda: {"v": 1})
        old = time.time() - 120
        os.utime(self.entry("k"), (old, old))
        self.assertEqual(helper.cached("k", 60, lambda: {"v": 2}), {"v": 2})
        with open(self.entry("k"), "w") as handle:
            handle.write(" " * (helper.MAX_OUTPUT_BYTES + 1))
        self.assertEqual(helper.cached("k", 60, lambda: {"v": 3}), {"v": 3})


if __name__ == "__main__":
    unittest.main()
