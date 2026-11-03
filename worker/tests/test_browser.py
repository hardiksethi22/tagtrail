import json
from pathlib import Path
import shutil
import sys
import time
import unittest
from unittest.mock import Mock, patch

from worker.adapter import GoogleAdapter, load_upstream
from worker.browser import authenticate_browser, close_owned_browser
from worker.errors import WorkerError
from worker.tests.fixtures import bundle, OWNER, SECRET


class BrowserTests(unittest.TestCase):
    def test_explicit_helper_real_cookie_exchange_and_upstream_shared_key_parser(self):
        from selenium import webdriver
        import gpsoauth
        _, _, cache = load_upstream()
        request = {"command": "authenticate", "credential_bundle": {"username": "synthetic@example.invalid"},
                   "browser_helper": {"enabled": True, "chromedriver_path": sys.executable,
                                      "artifact_directory": "worker/browser-test-artifacts"}}
        adapter = GoogleAdapter(request, lambda *args, **kwargs: None, time.monotonic() + 10)
        driver = Mock()
        driver.service.process = None
        driver.capabilities = {}
        driver.get_cookie.return_value = {"value": SECRET}
        driver.current_url = "https://myaccount.google.com/security"
        keys = json.dumps({"finder_hw": [{"epoch": 1, "key": {str(i): byte for i, byte in enumerate(OWNER)}}]})
        driver.switch_to.alert.text = json.dumps({"method": "setVaultSharedKeys", "vaultKeys": keys})
        transport = Mock()
        transport.register.side_effect = lambda: cache.set_cached_value("fcm_credentials", bundle()["fcm_credentials"])
        try:
            with patch.object(webdriver, "Chrome", return_value=driver) as chrome, patch("worker.adapter.FCMTransport", return_value=transport), patch.object(gpsoauth, "exchange_token", return_value={"Token": SECRET}) as exchange:
                authenticate_browser(adapter)
            exchange.assert_called_once_with("synthetic@example.invalid", SECRET, "123456")
            self.assertEqual(cache.get_cached_value("shared_key"), OWNER.hex())
            self.assertEqual(cache.get_cached_value("aas_token"), SECRET)
            driver.quit.assert_called_once()
            self.assertTrue(all("--headless" not in option for option in chrome.call_args.kwargs["options"].arguments))
            self.assertEqual(list(Path("worker/browser-test-artifacts").iterdir()), [])
        finally:
            adapter.close()
            shutil.rmtree("worker/browser-test-artifacts", ignore_errors=True)

    def test_browser_is_never_implicitly_launched(self):
        from selenium import webdriver
        request = {"command": "authenticate", "credential_bundle": {},
                   "browser_helper": {"enabled": False}}
        adapter = GoogleAdapter(request, lambda *args, **kwargs: None, time.monotonic() + 10)
        with patch.object(webdriver, "Chrome") as browser, self.assertRaises(WorkerError):
            authenticate_browser(adapter)
        browser.assert_not_called()

    def test_cleanup_does_not_terminate_reused_pid(self):
        import psutil
        driver = Mock()
        process = Mock()
        process.create_time.return_value = 999
        with patch.object(psutil, "Process", return_value=process), patch.object(psutil, "wait_procs", return_value=([], [])):
            close_owned_browser(driver, [(1234, 123)])
        process.terminate.assert_not_called()
        process.kill.assert_not_called()
        driver.quit.assert_called_once()

    def test_cleanup_terminates_only_owned_matching_process(self):
        import psutil
        driver = Mock()
        process = Mock(pid=1234)
        process.create_time.return_value = 123
        process.children.return_value = []
        with patch.object(psutil, "Process", return_value=process), patch.object(psutil, "wait_procs", side_effect=[([], [process]), ([process], [])]):
            close_owned_browser(driver, [(1234, 123)])
        process.terminate.assert_called_once()
        process.kill.assert_called_once()


if __name__ == "__main__":
    unittest.main()
