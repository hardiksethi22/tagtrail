"""Explicit, visible upstream account-cookie and security-domain setup helper."""
import json
from pathlib import Path
import shutil
import threading
import time

from worker.errors import WorkerError

# Persistent sign-in profile inside the artifact directory. Keeping it (instead
# of deleting the profile after every attempt) means the Google session
# survives, so retries and later re-connections start already signed in.
AUTH_PROFILE = "auth-profile"


def _browser_profile_root(binary):
    """Default-profile directory of a Chromium-family browser on macOS."""
    name = Path(binary).name.lower()
    home = Path.home()
    candidates = {
        "brave": home / "Library/Application Support/BraveSoftware/Brave-Browser",
        "chrome": home / "Library/Application Support/Google/Chrome",
        "edge": home / "Library/Application Support/Microsoft Edge",
        "chromium": home / "Library/Application Support/Chromium",
        "vivaldi": home / "Library/Application Support/Vivaldi",
    }
    for marker, base in candidates.items():
        if marker in name:
            return base / "Default"
    return None


def _seed_cookies(profile, binary):
    """Best-effort copy of the user's existing browser cookies into a fresh
    sign-in profile so Google is already logged in. System privacy protection
    (macOS TCC) may deny the copy; the flow then simply asks for a sign-in
    once and the persistent profile remembers it afterwards."""
    source = _browser_profile_root(binary)
    if source is None:
        return
    target = profile / "Default"
    try:
        target.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError:
        return
    for name in ("Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm"):
        try:
            shutil.copy2(source / name, target / name)
        except (OSError, shutil.Error):
            continue


def _page_url(driver):
    """Current URL, or "" while the page is mid-navigation."""
    try:
        return driver.current_url or ""
    except Exception:
        return ""


def _rejection_failure(driver):
    """WorkerError once Google has visibly rejected the automated session,
    instead of silently polling until the five-minute deadline."""
    url = _page_url(driver)
    if "signin/rejected" in url or "signin/denied" in url:
        return WorkerError("authentication-required")
    return None


def close_owned_browser(driver, owned):
    """Bound WebDriver shutdown, then target only creation-time-verified PIDs."""
    import psutil
    snapshot = dict(owned)
    for pid, created in owned:
        try:
            process = psutil.Process(pid)
            if process.create_time() == created:
                for child in process.children(recursive=True):
                    snapshot[child.pid] = child.create_time()
        except psutil.Error:
            pass
    owned = list(snapshot.items())
    thread = threading.Thread(target=lambda: _quiet_quit(driver), daemon=True)
    thread.start()
    thread.join(timeout=2)
    survivors = []
    for pid, created in owned:
        try:
            process = psutil.Process(pid)
            if process.create_time() == created:
                process.terminate()
                survivors.append(process)
        except psutil.Error:
            pass
    _, alive = psutil.wait_procs(survivors, timeout=2)
    for process in alive:
        try:
            if process.create_time() == dict(owned)[process.pid]:
                process.kill()
        except psutil.Error:
            pass
    psutil.wait_procs(alive, timeout=1)


def _quiet_quit(driver):
    try:
        driver.quit()
    except Exception:
        pass


def authenticate_browser(adapter):
    import gpsoauth
    import requests
    from selenium import webdriver
    from selenium.webdriver.chrome.service import Service
    from selenium.common.exceptions import NoAlertPresentException
    from worker.adapter import FCMTransport
    from KeyBackup.shared_key_request import get_security_domain_request_url
    from KeyBackup.response_parser import get_fmdn_shared_key

    config = adapter.request["browser_helper"]
    if config.get("enabled") is not True:
        raise WorkerError("authentication-required")
    driver_path = Path(config.get("chromedriver_path", ""))
    artifact_root = Path(config.get("artifact_directory", "worker/.browser-state"))
    if not driver_path.is_absolute() or not driver_path.is_file():
        raise WorkerError("authentication-required")
    if artifact_root.is_absolute() or ".." in artifact_root.parts:
        raise WorkerError("protocol-error")
    if not artifact_root.resolve().is_relative_to(Path.cwd().resolve()):
        raise WorkerError("protocol-error")
    username = adapter.cache.get_cached_value("username")
    if not isinstance(username, str) or not username:
        raise WorkerError("authentication-required")
    # One persistent, permission-restricted profile is reused across attempts
    # so the Google session is remembered; stale per-attempt directories are
    # removed. Existing browser instances and profiles are never touched.
    artifact_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    profile = artifact_root / AUTH_PROFILE
    profile.mkdir(mode=0o700, exist_ok=True)
    for entry in artifact_root.iterdir():
        if entry.is_dir() and entry.name != AUTH_PROFILE:
            shutil.rmtree(entry, ignore_errors=True)
    chrome_binary = config.get("chrome_binary")
    if chrome_binary and not (profile / "Default" / "Cookies").exists():
        _seed_cookies(profile, chrome_binary)
    options = webdriver.ChromeOptions()
    options.add_argument("--user-data-dir=" + str(profile.resolve()))
    options.add_argument("--start-maximized")
    # Google rejects the legacy EmbeddedSetup sign-in when it detects WebDriver
    # automation ("Couldn't sign you in"). Hide the automation markers so the
    # browser presents as a normal, user-driven Chromium session, and use the
    # real Keychain so copied session cookies still decrypt.
    options.add_experimental_option("excludeSwitches",
                                    ["enable-automation", "use-mock-keychain"])
    options.add_experimental_option("useAutomationExtension", False)
    options.add_argument("--disable-blink-features=AutomationControlled")
    if chrome_binary:
        options.binary_location = chrome_binary
    driver = None
    service = Service(executable_path=str(driver_path))
    owned = []
    try:
        adapter.emit("progress", payload={"stage": "browser-authentication"})
        driver = webdriver.Chrome(service=service, options=options)
        driver.execute_cdp_cmd("Page.addScriptToEvaluateOnNewDocument", {
            "source": "Object.defineProperty(navigator, 'webdriver', {get: () => undefined});"
        })
        import psutil
        if driver.service.process:
            process = psutil.Process(driver.service.process.pid)
            owned = [(item.pid, item.create_time()) for item in
                     [process, *process.children(recursive=True)]]
        browser_pid = driver.capabilities.get("goog:processID")
        if browser_pid:
            browser = psutil.Process(browser_pid)
            if "--user-data-dir=" + str(profile.resolve()) in browser.cmdline():
                owned.extend((item.pid, item.create_time()) for item in
                             [browser, *browser.children(recursive=True)])
        driver.command_executor._client_config.timeout = min(15, adapter.remaining())
        driver.set_page_load_timeout(min(30, adapter.remaining()))
        driver.get("https://accounts.google.com/EmbeddedSetup")
        token = None
        while token is None:
            adapter.remaining()
            if failure := _rejection_failure(driver):
                raise failure
            try:
                cookie = driver.get_cookie("oauth_token")
            except Exception:
                cookie = None
            if cookie and cookie.get("value"):
                token = cookie["value"]
                break
            time.sleep(0.2)
        adapter.fcm = FCMTransport(adapter.remaining)
        adapter.fcm.register()
        android_id = str(adapter.cache.get_cached_value("fcm_credentials")["gcm"]["android_id"])
        original = gpsoauth._perform_auth_request
        def bounded(data, proxies=None):
            from worker.adapter import check_http
            with requests.Session() as session:
                session.mount(gpsoauth.AUTH_URL, gpsoauth.AuthHTTPAdapter())
                session.headers.update({"Accept-Encoding": "identity",
                                        "Content-type": "application/x-www-form-urlencoded",
                                        "User-Agent": gpsoauth.USER_AGENT})
                response = session.post(gpsoauth.AUTH_URL, data=data, verify=True,
                                        timeout=min(15, adapter.remaining()))
                check_http(response)
                return gpsoauth.google.parse_auth_response(response.text)
        gpsoauth._perform_auth_request = bounded
        try:
            exchanged = gpsoauth.exchange_token(username, token, android_id)
        finally:
            gpsoauth._perform_auth_request = original
        if not exchanged.get("Token"):
            raise WorkerError("authentication-required")
        adapter.cache.set_cached_value("aas_token", exchanged["Token"])
        if exchanged.get("Email"):
            adapter.cache.set_cached_value("username", exchanged["Email"])
        driver.get("https://accounts.google.com/")
        while not _page_url(driver).startswith("https://myaccount.google.com"):
            adapter.remaining()
            if failure := _rejection_failure(driver):
                raise failure
            time.sleep(0.2)
        driver.get(get_security_domain_request_url())
        driver.execute_script("""
            window.mm = {
              setVaultSharedKeys: function(str, vaultKeys) {
                alert(JSON.stringify({method:'setVaultSharedKeys', vaultKeys:vaultKeys}));
              },
              closeView: function() { alert(JSON.stringify({method:'closeView'})); }
            };
        """)
        while True:
            adapter.remaining()
            try:
                alert = driver.switch_to.alert
                data = json.loads(alert.text)
                alert.accept()
                if data.get("method") == "setVaultSharedKeys":
                    shared = get_fmdn_shared_key(data["vaultKeys"])
                    if not shared:
                        raise WorkerError("decryption-error")
                    adapter.cache.set_cached_value("shared_key", shared.hex())
                    break
                if data.get("method") == "closeView":
                    raise WorkerError("authentication-required")
            except NoAlertPresentException:
                time.sleep(0.1)
    finally:
        if driver:
            close_owned_browser(driver, owned)
        elif service.process and service.process.poll() is None:
            import psutil
            try:
                process = psutil.Process(service.process.pid)
                owned = [(item.pid, item.create_time()) for item in
                         [process, *process.children(recursive=True)]]
                close_owned_browser(None, owned)
            except psutil.Error:
                pass
        # The auth profile is deliberately kept: it holds the Google session
        # for the next attempt. Remove it only to force a fresh sign-in.
