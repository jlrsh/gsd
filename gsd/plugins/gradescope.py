"""Gradescope source plugin.

The plugin scrapes assignment records directly.  It deliberately has no ICS
renderer or publishing machinery: gsd consumes the returned dictionaries and
turns them into its own Items.
"""

from __future__ import annotations

import getpass
import http.cookiejar
import json
import os
import platform
import random
import re
import shutil
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from bs4 import BeautifulSoup

GS = "https://www.gradescope.com"
LOGIN_URL = f"{GS}/login"
SERVICE = "gsd.gradescope"
PASSWORD_ENV = "GSD_GRADESCOPE_PASSWORD"
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)


class GradescopeError(RuntimeError):
    pass


class AuthError(GradescopeError):
    pass


class BotCheckError(GradescopeError):
    pass


_BOT_MARKERS = (
    "just a moment",
    "cf-browser-verification",
    "cf_chl_opt",
    "attention required! | cloudflare",
    "enable javascript and cookies to continue",
    "checking if the site connection is secure",
)
_ISO_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?$"
)


def _looks_like_bot_check(html: str, headers=None) -> bool:
    lowered = (html or "")[:4000].lower()
    return any(marker in lowered for marker in _BOT_MARKERS) or bool(
        headers is not None and headers.get("cf-mitigated")
    )


def password_for(email: str) -> str | None:
    """Read a password without ever consulting gsd's config/state files."""
    if os.environ.get(PASSWORD_ENV):
        return os.environ[PASSWORD_ENV]
    if platform.system() != "Darwin":
        return None
    proc = subprocess.run(
        ["security", "find-generic-password", "-s", SERVICE, "-a", email, "-w"],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 44:
        return None
    if proc.returncode != 0:
        raise AuthError(proc.stderr.strip() or "could not read the macOS Keychain")
    return proc.stdout.rstrip("\n")


def store_password(email: str, password: str) -> None:
    if platform.system() != "Darwin":
        raise AuthError(f"No macOS Keychain; set {PASSWORD_ENV} instead")
    proc = subprocess.run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-s",
            SERVICE,
            "-a",
            email,
            "-l",
            f"gsd Gradescope ({email})",
            "-D",
            "application password",
            "-w",
            password,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise AuthError(proc.stderr.strip() or "could not write the macOS Keychain")


def delete_password(email: str) -> bool:
    if platform.system() != "Darwin":
        return False
    proc = subprocess.run(
        ["security", "delete-generic-password", "-s", SERVICE, "-a", email],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


class Session:
    def __init__(self, cookie_path: Path, timeout: int = 25):
        self.cookie_path = cookie_path
        self.timeout = timeout
        self.jar = http.cookiejar.MozillaCookieJar(str(cookie_path))
        if cookie_path.exists():
            try:
                self.jar.load(ignore_discard=True, ignore_expires=True)
            except (http.cookiejar.LoadError, OSError):
                pass
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar)
        )
        self.opener.addheaders = [
            ("User-Agent", UA),
            (
                "Accept",
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ),
            ("Accept-Language", "en-US,en;q=0.9"),
        ]

    def save(self) -> None:
        self.cookie_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.cookie_path.parent, 0o700)
        except OSError:
            pass
        self.jar.save(ignore_discard=True, ignore_expires=True)
        try:
            os.chmod(self.cookie_path, 0o600)
        except OSError:
            pass

    def _open(self, request, attempts: int = 3) -> tuple[str, str]:
        delay = 1.0
        for attempt in range(attempts):
            try:
                with self.opener.open(request, timeout=self.timeout) as res:
                    body = res.read().decode("utf-8", errors="replace")
                    if _looks_like_bot_check(body, res.headers):
                        raise BotCheckError(
                            "Gradescope presented a bot check; import browser cookies"
                        )
                    return res.geturl(), body
            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", errors="replace")
                if _looks_like_bot_check(body, exc.headers):
                    raise BotCheckError(
                        "Gradescope presented a bot check; import browser cookies"
                    ) from exc
                if (
                    exc.code in (408, 429, 500, 502, 503, 504)
                    and attempt + 1 < attempts
                ):
                    time.sleep(delay + random.uniform(0, delay / 2))
                    delay *= 2
                    continue
                raise GradescopeError(f"Gradescope returned HTTP {exc.code}") from exc
            except urllib.error.URLError as exc:
                reason = getattr(exc, "reason", exc)
                if isinstance(reason, ssl.SSLCertVerificationError):
                    raise GradescopeError(
                        "TLS certificate verification failed"
                    ) from exc
                if attempt + 1 < attempts:
                    time.sleep(delay + random.uniform(0, delay / 2))
                    delay *= 2
                    continue
                raise GradescopeError("could not reach Gradescope") from exc
        raise GradescopeError("could not reach Gradescope")

    def get(self, url: str) -> tuple[str, str]:
        return self._open(urllib.request.Request(url))

    def post(self, url: str, fields: dict) -> tuple[str, str]:
        # fields contains the password: never include it in errors or logging.
        request = urllib.request.Request(
            url,
            data=urllib.parse.urlencode(fields).encode(),
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Referer": url,
            },
        )
        return self._open(request)

    @staticmethod
    def _is_login(url: str, html: str) -> bool:
        return (
            'name="session[email]"' in html
            or urllib.parse.urlparse(url).path.rstrip("/") == "/login"
        )

    def login(self, email: str, password: str) -> None:
        _, html = self.get(LOGIN_URL)
        token = BeautifulSoup(html, "html.parser").select_one(
            'input[name="authenticity_token"]'
        )
        if token is None:
            raise AuthError("Gradescope login form was not found")
        url, html = self.post(
            LOGIN_URL,
            {
                "utf8": "✓",
                "authenticity_token": token.get("value", ""),
                "session[email]": email,
                "session[password]": password,
                "session[remember_me]": "1",
                "commit": "Log In",
                "session[remember_me_sso]": "0",
            },
        )
        if self._is_login(url, html):
            raise AuthError("Gradescope rejected that email/password")
        self.save()

    def ensure_login(self, email: str) -> None:
        try:
            url, html = self.get(f"{GS}/")
            if not self._is_login(url, html):
                return
        except BotCheckError:
            raise
        except GradescopeError:
            pass
        password = password_for(email)
        if not email or not password:
            raise AuthError("no valid session; run --gradescope-login EMAIL")
        self.login(email, password)

    def doc(self, url: str):
        final, html = self.get(url)
        if self._is_login(final, html):
            raise AuthError("Gradescope session expired")
        return BeautifulSoup(html, "html.parser")


def _text(node) -> str:
    return re.sub(r"\s+", " ", node.get_text()).strip() if node is not None else ""


def normalize_datetime(raw) -> str | None:
    if not raw:
        return None
    original = str(raw).strip()
    value = re.sub(r"^(\d{4}-\d{2}-\d{2})[ T]", r"\1T", original)
    match = _ISO_RE.match(value)
    if match:
        base, offset = match.groups()
        if len(base) == 16:
            base += ":00"
        if offset:
            if offset != "Z" and ":" not in offset:
                offset = offset[:3] + ":" + offset[3:]
            return base + offset
    for candidate in (
        original.replace("Z", "+00:00"),
        original.replace(" ", "T", 1).replace("Z", "+00:00"),
    ):
        try:
            return datetime.fromisoformat(candidate).isoformat()
        except ValueError:
            pass
    return None


def parse_courses(doc, all_terms: bool = False) -> list[dict]:
    groups = []
    lists = doc.select(".courseList")
    if lists:
        for listing in lists:
            terms = listing.select(".courseList--coursesForTerm")
            groups.extend(terms if all_terms else terms[:1])
    else:
        groups = [doc]
    courses, seen = [], set()
    for group in groups:
        for box in group.select("a.courseBox, .courseBox"):
            if "courseBox-new" in (box.get("class") or []):
                continue
            match = re.search(r"/courses/(\d+)", box.get("href") or "")
            if not match or match.group(1) in seen:
                continue
            cid = match.group(1)
            seen.add(cid)
            short = _text(box.select_one(".courseBox--shortname"))
            full = _text(box.select_one(".courseBox--name"))
            courses.append(
                {
                    "id": cid,
                    "name": short or full or f"Course {cid}",
                    "full_name": full or short,
                    "url": f"{GS}/courses/{cid}",
                }
            )
    return courses


def _due(row) -> str | None:
    times = row.select("time[datetime]")
    candidates = [
        t
        for t in times
        if not any(
            marker
            in f"{t.get('aria-label') or ''} {' '.join(t.get('class') or [])}".lower()
            for marker in ("released", "releasedate", "late due")
        )
    ]
    picked = next(
        (
            t
            for t in candidates
            if "due"
            in f"{t.get('aria-label') or ''} {' '.join(t.get('class') or [])}".lower()
        ),
        candidates[0] if candidates else (times[-1] if times else None),
    )
    return normalize_datetime(picked.get("datetime")) if picked else None


def parse_assignments(doc, course: dict) -> list[dict]:
    table = doc.select_one("#assignments-student-table")
    scope = table if table is not None else doc
    rows = scope.select("tbody tr") or scope.select("tr")
    out, used = [], set()
    for row in rows:
        if not row.select_one("td"):
            continue
        cells = row.select("th, td")
        first = cells[0]
        link = first.select_one('a[href*="/assignments/"]')
        button = first.select_one("button[data-assignment-id]") or first.select_one(
            "button"
        )
        title, due = _text(link or button or first), _due(row)
        if not title or not due:
            continue
        aid = button.get("data-assignment-id") if button else None
        if not aid and link:
            match = re.search(r"assignments/(\d+)", link.get("href") or "")
            aid = match.group(1) if match else None
        key = f"a{aid}" if aid else f"t:{title}"
        base, suffix = key, 2
        while key in used:
            key, suffix = f"{base}#{suffix}", suffix + 1
        used.add(key)
        out.append(
            {
                "key": key,
                "title": title,
                "due_iso": due,
                "status": _text(cells[1]) if len(cells) > 1 else "",
                "course": course["name"],
                "course_id": course["id"],
                "url": f"{GS}/courses/{course['id']}/assignments/{aid}"
                if aid
                else course["url"],
            }
        )
    return out


def _submitted(status: str) -> bool:
    return bool(re.search(r"submitted|graded|\d+\s*/\s*\d+", status or "", re.I))


def fetch(
    config: dict, cookie_path: Path, timeout: int, horizon_days: int
) -> list[dict]:
    """Return a complete, healthy scrape or raise so gsd keeps its old cache."""
    email = str(config.get("email") or "").strip()
    session = Session(cookie_path, timeout=max(10, timeout))
    session.ensure_login(email)
    courses = parse_courses(session.doc(f"{GS}/"), bool(config.get("all_terms")))
    if not courses:
        raise GradescopeError("no courses found on the Gradescope dashboard")

    errors = []

    def one(course):
        try:
            return parse_assignments(session.doc(course["url"]), course)
        except (AuthError, BotCheckError):
            raise
        except Exception as exc:
            errors.append(type(exc).__name__)
            return []

    with ThreadPoolExecutor(max_workers=3) as pool:
        rows = [item for group in pool.map(one, courses) for item in group]
    if errors:
        raise GradescopeError(f"{len(errors)} course(s) failed; kept previous cache")

    now = datetime.now(timezone.utc)
    floor, ceiling = now - timedelta(days=365), now + timedelta(days=horizon_days)
    kept = []
    for item in rows:
        try:
            due = datetime.fromisoformat(item["due_iso"].replace("Z", "+00:00"))
        except ValueError:
            continue
        if due.tzinfo is None:
            due = due.replace(tzinfo=timezone.utc)
        if floor <= due <= ceiling and not (
            config.get("skip_submitted") and _submitted(item["status"])
        ):
            kept.append(item)
    return sorted(kept, key=lambda item: item["due_iso"])


def login(email: str, cookie_path: Path) -> None:
    password = os.environ.get(PASSWORD_ENV)
    from_environment = bool(password)
    if not password and platform.system() == "Darwin":
        password = getpass.getpass("Gradescope password: ")
    if not password:
        raise AuthError(f"set {PASSWORD_ENV} before logging in on this platform")
    session = Session(cookie_path)
    session.login(email, password)
    if not from_environment:
        store_password(email, password)


def import_cookies(source: Path, cookie_path: Path) -> None:
    jar = http.cookiejar.MozillaCookieJar(str(source))
    try:
        jar.load(ignore_discard=True, ignore_expires=True)
    except (OSError, http.cookiejar.LoadError) as exc:
        raise AuthError("not a Netscape/Mozilla cookies.txt file") from exc
    if not any("gradescope.com" in cookie.domain for cookie in jar):
        raise AuthError("cookie file contains no gradescope.com cookies")
    cookie_path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(cookie_path.parent, 0o700)
    shutil.copyfile(source, cookie_path)
    os.chmod(cookie_path, 0o600)


def write_cache(path: Path, assignments: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(assignments, indent=1) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_cache(path: Path) -> tuple[list[dict], float | None]:
    try:
        value = json.loads(path.read_text())
        return (value if isinstance(value, list) else []), path.stat().st_mtime
    except (OSError, ValueError):
        return [], None
