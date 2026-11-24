"""Write release-only settings into the staged application's Info.plist."""
import base64
import os
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

BETA_BRANCH = "sparkle-updates"
BETA_FILE = "beta.xml"


def cdn_origin():
    origin = os.environ["UPDATE_CDN_ORIGIN"].rstrip("/")
    url = urlsplit(origin)
    if url.scheme != "https" or not url.hostname or url.netloc != url.hostname or url.path or url.query or url.fragment:
        raise ValueError("UPDATE_CDN_ORIGIN must be an HTTPS origin, e.g. https://updates.example.com")
    return origin


if __name__ == "__main__":
    repo = os.environ["GITHUB_UPDATE_REPOSITORY"]
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise ValueError("Expected GITHUB_UPDATE_REPOSITORY=owner/repo")
    key = os.environ["SPARKLE_PUBLIC_KEY"].strip()
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Invalid Sparkle public key")
    path = Path(sys.argv[1])
    info = plistlib.loads(path.read_bytes())
    if tag := os.getenv("TAG"):
        match = re.fullmatch(r"v(\d+(?:\.\d+){1,2})(?:-beta\.[1-9]\d*)?", tag)
        if not match or match[1] != info["CFBundleShortVersionString"]:
            raise ValueError("Expected v<bundle version> or v<bundle version>-beta.N")
        info["SirinReleaseVersion"] = tag[1:]
    info.update(SUFeedURL=f"{cdn_origin()}/sirinisland/stable/appcast.xml",
                SirinBetaFeedURL=f"{cdn_origin()}/sirinisland/beta/appcast.xml",
                SUPublicEDKey=key, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True)
    if os.getenv("GITHUB_RELEASE_PRIVATE") != "true":
        info["SirinGitHubFeedURL"] = f"https://github.com/{repo}/releases/latest/download/appcast.xml"
        info["SirinGitHubBetaFeedURL"] = f"https://raw.githubusercontent.com/{repo}/{BETA_BRANCH}/{BETA_FILE}"
    path.write_bytes(plistlib.dumps(info))
