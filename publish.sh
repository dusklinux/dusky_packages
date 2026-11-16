#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-/srv/offline-repo/aur}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH_DIR="${REPO_ROOT}/x86_64"

shopt -s nullglob
pkgs=("${SRC_DIR}"/dusky_*.pkg.tar.zst)
if (( ${#pkgs[@]} == 0 )); then
    echo "error: no dusky_*.pkg.tar.zst packages found in ${SRC_DIR}" >&2
    exit 1
fi

mkdir -p "${ARCH_DIR}"
rm -f "${ARCH_DIR}"/dusky_*.pkg.tar.zst "${ARCH_DIR}"/dusky.db* "${ARCH_DIR}"/dusky.files*

cp -v "${pkgs[@]}" "${ARCH_DIR}/"

repo-add "${ARCH_DIR}/dusky.db.tar.zst" "${ARCH_DIR}"/dusky_*.pkg.tar.zst
rm -f "${ARCH_DIR}/dusky.db" "${ARCH_DIR}/dusky.files"
cp "${ARCH_DIR}/dusky.db.tar.zst" "${ARCH_DIR}/dusky.db"
cp "${ARCH_DIR}/dusky.files.tar.zst" "${ARCH_DIR}/dusky.files"

python3.15 - "${REPO_ROOT}" <<'PY'
import datetime as dt
import hashlib
import json
import sys
import tarfile
from pathlib import Path

repo_root = Path(sys.argv[1])
arch_dir = repo_root / "x86_64"
packages: dict[str, dict[str, object]] = {}

for pkg_path in sorted(arch_dir.glob("dusky_*.pkg.tar.zst")):
    with pkg_path.open("rb") as f:
        pkg_sha256 = hashlib.file_digest(f, "sha256").hexdigest()

    meta: dict[str, str] = {}
    source_sha256: str | None = None

    with tarfile.open(pkg_path, mode="r:zst") as tf:
        pkginfo = tf.extractfile(".PKGINFO")
        if pkginfo is None:
            raise RuntimeError(f"Missing .PKGINFO in {pkg_path.name}")
        for line in pkginfo.read().decode("utf-8").splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                meta[k.strip()] = v.strip()

        pkgname = meta["pkgname"]
        if pkgname in packages:
            raise RuntimeError(f"Duplicate package versions found for {pkgname}")

        try:
            src_member = tf.extractfile(f"usr/share/{pkgname}/source.sha256")
            if src_member is not None:
                source_sha256 = src_member.read().decode("utf-8").strip().split()[0]
        except KeyError:
            pass

    packages[pkgname] = {
        "pkgname": pkgname,
        "pkgver": meta["pkgver"],
        "pkgdesc": meta.get("pkgdesc", ""),
        "arch": meta.get("arch", "x86_64"),
        "filename": f"x86_64/{pkg_path.name}",
        "sha256": pkg_sha256,
        "size_bytes": pkg_path.stat().st_size,
        "installed_size": int(meta.get("size", 0)),
        "build_date": int(meta.get("builddate", 0)),
        "source_sha256": source_sha256,
    }

# Verify 1:1 parity between dusky.db.tar.zst and manifest.json
with tarfile.open(arch_dir / "dusky.db.tar.zst", mode="r:zst") as db_tf:
    db_names = {
        Path(m.name).parent.name.rsplit("-", 2)[0]
        for m in db_tf.getmembers()
        if m.name.endswith("/desc")
    }

if db_names != set(packages.keys()):
    raise RuntimeError(f"DB/manifest mismatch: db={db_names}, manifest={set(packages.keys())}")

manifest = {
    "schema_version": 1,
    "repo": "dusky",
    "arch": "x86_64",
    "generated_at": dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "packages": packages,
}

(repo_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"Verified {len(packages)} packages in dusky.db and manifest.json.")
PY

cd "${REPO_ROOT}"
git add manifest.json x86_64/ .gitattributes publish.sh
if git diff-index --quiet HEAD --; then
    echo "No changes to commit."
else
    git commit -m "release: update publish script and attributes ($(date -u +%Y-%m-%d))"
    git push origin main
fi
echo "==> Done!"
