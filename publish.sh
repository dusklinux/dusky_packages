#!/usr/bin/env bash
# ==============================================================================
# publish.sh — Regenerate pacman DB, update manifest.json, and push updates
# ==============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

if [[ ! -d x86_64 ]]; then
    echo "Error: x86_64 directory not found." >&2
    exit 1
fi

echo "==> Updating pacman repository database..."
repo-add x86_64/dusky.db.tar.zst x86_64/*.pkg.tar.zst
rm -f x86_64/dusky.db x86_64/dusky.files
cp x86_64/dusky.db.tar.zst x86_64/dusky.db
cp x86_64/dusky.files.tar.zst x86_64/dusky.files

echo "==> Generating manifest.json..."
python3 - <<'PY'
import datetime as dt
import hashlib
import json
import tarfile
from pathlib import Path

repo_root = Path(".")
packages: dict[str, dict[str, object]] = {}

for pkg_path in sorted((repo_root / "x86_64").glob("dusky_*.pkg.tar.zst")):
    with pkg_path.open("rb") as f:
        pkg_sha256 = hashlib.file_digest(f, "sha256").hexdigest()

    meta: dict[str, str] = {}
    source_sha256: str | None = None

    with tarfile.open(pkg_path, mode="r:zst") as tf:
        pkginfo_member = tf.extractfile(".PKGINFO")
        if pkginfo_member is not None:
            for line in pkginfo_member.read().decode("utf-8").splitlines():
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    meta[k.strip()] = v.strip()

        pkgname = meta["pkgname"]
        src_hash_path = f"usr/share/{pkgname}/source.sha256"
        try:
            src_member = tf.extractfile(src_hash_path)
            if src_member is not None:
                source_sha256 = src_member.read().decode("utf-8").strip().split()[0]
        except KeyError:
            pass

    packages[pkgname] = {
        "pkgname": pkgname,
        "pkgver": meta["pkgver"],
        "pkgdesc": meta.get("pkgdesc", ""),
        "arch": meta.get("arch", "x86_64"),
        "filename": pkg_path.as_posix(),
        "sha256": pkg_sha256,
        "size_bytes": pkg_path.stat().st_size,
        "installed_size": int(meta.get("size", 0)),
        "build_date": int(meta.get("builddate", 0)),
        "source_sha256": source_sha256,
    }

manifest = {
    "schema_version": 1,
    "repo": "dusky",
    "arch": "x86_64",
    "generated_at": dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "packages": packages,
}

Path("manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"Generated manifest.json with {len(packages)} packages.")
PY

echo "==> Staging and committing..."
git add manifest.json README.md publish.sh x86_64/
if git diff-index --quiet HEAD --; then
    echo "No changes to commit."
else
    git commit -m "release: update dusky packages ($(date -u +%Y-%m-%d))"
    echo "==> Pushing to origin main..."
    git push origin main
fi
echo "==> Done!"
