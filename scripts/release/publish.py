"""Publish identical ZIPs and advance the feeds for the selected audience."""
import base64
import hashlib
import io
import json
import os
import plistlib
import subprocess
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import qiniu
import requests
from qiniu.services.storage.uploaders import FormUploader
from qiniu.utils import etag_stream

from configure import BETA_BRANCH, BETA_FILE, cdn_origin

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
STABLE_KEY = "sirinisland/stable/appcast.xml"
BETA_KEY = "sirinisland/beta/appcast.xml"


def feed_item(data):
    items = ET.fromstring(data).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected one update in the appcast")
    item = items[0]
    enclosure = item.find("enclosure")
    return (int(item.findtext(SPARKLE + "version")), item.findtext(SPARKLE + "shortVersionString"),
            enclosure.attrib["url"], int(enclosure.attrib["length"]), enclosure.attrib[SPARKLE + "edSignature"],
            item.findtext(SPARKLE + "channel"))


def allow_promotion(current, candidate):
    if current[0] > candidate[0] or (current[0] == candidate[0] and current != candidate):
        raise ValueError(f"Refusing to replace published build {current[0]} with build {candidate[0]}")


def gh(*args):
    subprocess.run(["gh", *map(str, args)], check=True)


def public_bytes(url):
    response = requests.get(url, timeout=45)
    response.raise_for_status()
    return response.content


def wait_for(url, matches, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            data = public_bytes(url)
            if matches(data):
                return data
        except requests.RequestException as error:
            print(f"Waiting for {url}: {error}", flush=True)
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Public download did not match the expected object: {url}")
        time.sleep(10)


def github_beta_entry(api, repo_url):
    response = api.get(f"{repo_url}/contents/{BETA_FILE}", params={"ref": BETA_BRANCH}, timeout=30)
    if response.status_code == 404:
        return None
    response.raise_for_status()
    return response.json()


def publish_github_beta_feed(api, repo_url, previous, path, tag):
    # Contents API updates the fixed URL atomically. A stale SHA fails instead of overwriting a newer feed.
    data = path.read_bytes()
    if previous and base64.b64decode(previous["content"]) == data:
        return
    body = {"message": f"Publish update feed for {tag}", "branch": BETA_BRANCH,
            "content": base64.b64encode(data).decode("ascii")}
    if previous:
        body["sha"] = previous["sha"]
    else:
        branch = api.get(f"{repo_url}/git/ref/heads/{BETA_BRANCH}", timeout=30)
        if branch.status_code == 404:
            api.post(f"{repo_url}/git/refs", json={"ref": f"refs/heads/{BETA_BRANCH}",
                     "sha": os.environ["GITHUB_SHA"]}, timeout=30).raise_for_status()
        else:
            branch.raise_for_status()
    api.put(f"{repo_url}/contents/{BETA_FILE}", json=body, timeout=30).raise_for_status()


class Kodo:
    def __init__(self):
        self.bucket = os.environ["QINIU_BUCKET"]
        if not self.bucket:
            raise ValueError("Missing QINIU_BUCKET")
        self.auth = qiniu.Auth(os.environ["QINIU_ACCESS_KEY"], os.environ["QINIU_SECRET_KEY"])
        self.uploader = FormUploader(self.bucket, auth=self.auth, preferred_scheme="https")
        self.storage = qiniu.BucketManager(self.auth, preferred_scheme="https")
        self.cdn = qiniu.CdnManager(self.auth)
        self.cdn.server = "https://fusion.qiniuapi.com"

    def stored_hash(self, key):
        result, info = self.storage.stat(self.bucket, key)
        if info.status_code == 612:  # Kodo's explicit "no such file"
            return None
        if info.status_code != 200:
            raise RuntimeError(f"Kodo stat {key}: {info.status_code}")
        return result["hash"]

    def upload(self, key, path, *, immutable):
        expected = qiniu.etag(str(path))
        existing = self.stored_hash(key)
        if existing == expected:
            return
        if immutable and existing is not None:
            raise ValueError(f"Versioned object already exists with different bytes: {key}")
        token = self.auth.upload_token(self.bucket, key, policy={"insertOnly": int(immutable)})
        mime = "application/zip" if immutable else "application/rss+xml"
        result, info = self.uploader.upload(key, file_path=str(path), mime_type=mime, up_token=token)
        if info.status_code != 200 or result.get("hash") != expected:
            raise RuntimeError(f"Kodo upload {key}: {info.status_code} or hash mismatch")

    def refresh(self, url):
        result, info = self.cdn.refresh_urls([url])
        if info.status_code != 200 or result.get("code") != 200:
            raise RuntimeError(f"CDN refresh failed: {info.status_code}, {result}")


def main():
    dist = Path(os.environ["DIST"])
    package = Path(os.environ["ARCHIVE"])
    tag = os.environ["TAG"]
    beta = "-beta." in tag
    repo = os.environ["GITHUB_UPDATE_REPOSITORY"]
    origin = cdn_origin()
    zip_key = f"sirinisland/releases/{tag}/{package.name}"
    feeds = {channel: dist / channel / "appcast.xml" for channel in ("cdn", "github")}
    cdn_item, github_item = (feed_item(feeds[name].read_bytes()) for name in ("cdn", "github"))
    config = plistlib.loads((dist / "expected.plist").read_bytes())
    version = int(config["CFBundleVersion"])
    size = package.stat().st_size
    github_zip_url = f"https://github.com/{repo}/releases/download/{tag}/{package.name}"
    for item, url in [(cdn_item, f"{origin}/{zip_key}"), (github_item, github_zip_url)]:
        if (item[:4] != (version, tag[1:], url, size) or item[4] != cdn_item[4]
                or item[5] != ("beta" if beta else None)):
            raise ValueError(f"Unexpected version, URL, length or signature in feed for {url}")

    release = json.loads((dist / "release.json").read_text())
    assets = {asset["name"]: asset["state"] for asset in release["assets"]}

    def stage_asset(path):
        state = assets.get(path.name)
        if state == "uploaded":  # Recovered and verified earlier in this run.
            return
        if not release["isDraft"]:
            raise ValueError(f"Missing asset in published release: {path.name}")
        # GitHub may leave a zero-byte 'starter' after a failed asset upload.
        flags = ["--clobber"] if state == "starter" else []
        gh("release", "upload", tag, path, *flags)

    # Persist the canonical notarized bytes first so a failed mirror can always resume.
    stage_asset(package)
    api = requests.Session()
    api.headers["Authorization"] = f"Bearer {os.environ['GH_TOKEN']}"
    repo_url = f"https://api.github.com/repos/{repo}"
    latest = api.get(f"{repo_url}/releases/latest", timeout=30)
    if latest.status_code != 404:
        latest.raise_for_status()
        previous = latest.json()
        if any(asset["name"] == "appcast.xml" for asset in previous["assets"]):
            previous_feed = dist / "previous.xml"
            gh("release", "download", previous["tag_name"], "-p", "appcast.xml", "-O", previous_feed)
            allow_promotion(feed_item(previous_feed.read_bytes()), github_item)
        else:
            # A pre-Sparkle release has no CFBundleVersion to compare.
            previous_tag = previous["tag_name"]
            previous_version = tuple(map(int, previous_tag.removeprefix("v").split(".")))
            if previous_version >= tuple(map(int, tag[1:].split("-")[0].split("."))):
                raise ValueError(f"Release must be newer than {previous_tag}")

    kodo = Kodo()
    # Beta subscribers receive each newer build, including the next stable release.
    # Check both channels even for a beta so existing stable installations can opt in.
    for key in (STABLE_KEY, BETA_KEY):
        current_hash = kodo.stored_hash(key)
        if current_hash:
            current = wait_for(f"{origin}/{key}", lambda data: etag_stream(io.BytesIO(data)) == current_hash, 660)
            allow_promotion(feed_item(current), cdn_item)
    public_github = "SirinGitHubFeedURL" in config
    previous_beta = github_beta_entry(api, repo_url) if public_github else None
    if previous_beta:
        allow_promotion(feed_item(base64.b64decode(previous_beta["content"])), github_item)

    with ThreadPoolExecutor(max_workers=2) as pool:
        github_feed_upload = pool.submit(stage_asset, feeds["github"])
        kodo.upload(zip_key, package, immutable=True)
        github_feed_upload.result()
    digest = hashlib.sha256(package.read_bytes()).digest()
    wait_for(cdn_item[2], lambda data: hashlib.sha256(data).digest() == digest, 180)

    if release["isDraft"]:
        gh("release", "edit", tag, "--draft=false", "--latest=false" if beta else "--latest")
    # Check the published assets through the same access path as their audience.
    if public_github:
        versioned_feed = f"https://github.com/{repo}/releases/download/{tag}/appcast.xml"
        wait_for(versioned_feed if beta else config["SirinGitHubFeedURL"],
                 lambda data: data == feeds["github"].read_bytes(), 180)
        wait_for(github_item[2], lambda data: hashlib.sha256(data).digest() == digest, 180)
        publish_github_beta_feed(api, repo_url, previous_beta, feeds["github"], tag)
        wait_for(config["SirinGitHubBetaFeedURL"], lambda data: data == feeds["github"].read_bytes(), 660)
    else:
        mirror_zip = dist / "github-download.zip"
        gh("release", "download", tag, "-p", package.name, "-O", mirror_zip)
        if hashlib.sha256(mirror_zip.read_bytes()).digest() != digest:
            raise ValueError("GitHub asset checksum mismatch")

    for key in ([BETA_KEY] if beta else [STABLE_KEY, BETA_KEY]):
        url = f"{origin}/{key}"
        kodo.upload(key, feeds["cdn"], immutable=False)
        kodo.refresh(url)
        wait_for(url, lambda data: data == feeds["cdn"].read_bytes(), 660)
    print(f"{tag} published to GitHub and {origin}. SHA-256 {digest.hex()}")


if __name__ == "__main__":
    main()
