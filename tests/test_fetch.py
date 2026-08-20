"""Tests for the URL guard in the fetch helper.

Run with: python3 -m unittest discover -s tests

The helper is handed URLs that came from remote page state, so those URLs are
input, not addresses. These cover the shapes that mattered: a scheme that reads
the local disk, a host on the loopback or private side of the network, and a
name that merely looks like the real one.
"""

import importlib.util
import os
import unittest

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

    def test_every_redirect_hop_is_checked_too(self):
        # An allowed host can still redirect anywhere, so the handler re-checks
        # rather than trusting the first URL it was given.
        handler = helper.GuardedRedirects()
        self.assertTrue(hasattr(handler, "redirect_request"))
        with self.assertRaises(helper.BlockedUrl):
            helper.check_url("https://evil.example/after-redirect")


if __name__ == "__main__":
    unittest.main()
