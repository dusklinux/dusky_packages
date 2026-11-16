#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="/srv/offline-repo/aur"
ALLOW_DOWNGRADE=0
FORCE_PUBLISH=0

while (( $# > 0 )); do
    case "$1" in
        --allow-downgrade) ALLOW_DOWNGRADE=1; shift ;;
        --force)           FORCE_PUBLISH=1; shift ;;
        -h|--help)
            echo "Usage: $0 [source_dir] [--allow-downgrade] [--force]"
            exit 0
            ;;
        *)
            SRC_DIR="$1"
            shift
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH_DIR="${REPO_ROOT}/x86_64"
STAGING_DIR="$(mktemp -d -p "${TMPDIR:-/tmp}" dusky-publish.XXXXXX)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

if [[ ! -d "${SRC_DIR}" ]]; then
    echo "error: source directory does not exist: ${SRC_DIR}" >&2
    exit 1
fi

# Resolve the newest candidate .pkg.tar.zst per package via Arch `vercmp` + `builddate`,
# stage selected archives into STAGING_DIR, and emit manifest.json.
python3.15 - "${SRC_DIR}" "${REPO_ROOT}" "${STAGING_DIR}" "${ALLOW_DOWNGRADE}" "${FORCE_PUBLISH}" <<'PY'
import datetime as dt
from functools import cmp_to_key
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

src_dir = Path(sys.argv[1])
repo_root = Path(sys.argv[2])
staging_dir = Path(sys.argv[3])
allow_downgrade = sys.argv[4] == "1"
force_publish = sys.argv[5] == "1"


def vercmp(ver_a: str, ver_b: str) -> int:
    proc = subprocess.run(["vercmp", ver_a, ver_b], capture_output=True, text=True, check=True)
    return int(proc.stdout.strip())


def inspect_archive(pkg_path: Path) -> dict[str, object]:
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
        try:
            src_member = tf.extractfile(f"usr/share/{pkgname}/source.sha256")
            if src_member is not None:
                tokens = src_member.read().decode("utf-8").strip().split()
                if tokens:
                    source_sha256 = tokens[0].lower()
        except KeyError:
            pass

    return {
        "path": pkg_path,
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


def compare_candidates(a: dict[str, object], b: dict[str, object]) -> int:
    vc = vercmp(str(a["pkgver"]), str(b["pkgver"]))
    if vc != 0:
        return vc
    # Tie-breaker for same-version rebuilds: newer build_date wins
    bd_a, bd_b = int(a["build_date"]), int(b["build_date"])
    return (bd_a > bd_b) - (bd_a < bd_b)


candidates_by_name: dict[str, list[dict[str, object]]] = {}
for pkg_path in sorted(src_dir.glob("dusky_*.pkg.tar.zst")):
    info = inspect_archive(pkg_path)
    candidates_by_name.setdefault(str(info["pkgname"]), []).append(info)

if not candidates_by_name:
    raise RuntimeError(f"No dusky_*.pkg.tar.zst packages found in {src_dir}")

selected: dict[str, dict[str, object]] = {}
for pkgname in sorted(candidates_by_name):
    ranked = sorted(candidates_by_name[pkgname], key=cmp_to_key(compare_candidates))
    winner = ranked[-1]
    if len(ranked) > 1:
        skipped = ", ".join(f"{Path(str(x['path'])).name}" for x in ranked[:-1])
        print(f"[select] {pkgname}: chose {Path(str(winner['path'])).name} (ignored older: {skipped})")
    selected[pkgname] = winner

# Compare against previous manifest.json if present
prev_packages: dict[str, dict[str, object]] = {}
manifest_path = repo_root / "manifest.json"
if manifest_path.exists():
    prev_data = json.loads(manifest_path.read_text(encoding="utf-8"))
    prev_packages = prev_data.get("packages", {})

changes = 0
for pkgname, pkg in selected.items():
    old = prev_packages.get(pkgname)
    if old is None:
        print(f"  + {pkgname:<18} [added]    {pkg['pkgver']}")
        changes += 1
        continue

    vc = vercmp(str(pkg["pkgver"]), str(old["pkgver"]))
    if vc > 0:
        print(f"  ^ {pkgname:<18} [upgraded] {old['pkgver']} -> {pkg['pkgver']}")
        changes += 1
    elif vc == 0:
        if pkg["sha256"] != old.get("sha256") or pkg["source_sha256"] != old.get("source_sha256"):
            print(f"  ~ {pkgname:<18} [rebuilt]  {pkg['pkgver']} (same version, updated binary/source)")
            changes += 1
        else:
            print(f"  = {pkgname:<18} [unchanged] {pkg['pkgver']}")
    else:
        msg = f"Version regression for {pkgname}: remote {old['pkgver']} > local {pkg['pkgver']}"
        if not allow_downgrade:
            raise RuntimeError(f"{msg} (pass --allow-downgrade to override)")
        print(f"  v {pkgname:<18} [downgraded] {old['pkgver']} -> {pkg['pkgver']}")
        changes += 1

removed = set(prev_packages) - set(selected)
if removed:
    print(f"  - Removed from repo: {', '.join(sorted(removed))}")
    changes += len(removed)

if changes == 0 and not force_publish:
    print("All packages in manifest.json are already up to date; nothing to publish.")
    sys.exit(99)

packages_manifest: dict[str, dict[str, object]] = {}
for pkgname, pkg in selected.items():
    src_file = Path(str(pkg["path"]))
    shutil.copy2(src_file, staging_dir / src_file.name)
    entry = {k: v for k, v in pkg.items() if k != "path"}
    packages_manifest[pkgname] = entry

manifest = {
    "schema_version": 1,
    "repo": "dusky",
    "arch": "x86_64",
    "generated_at": dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "packages": packages_manifest,
}
(staging_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
rc=$?
if (( rc == 99 )); then
    exit 0
elif (( rc != 0 )); then
    exit "${rc}"
fi

# Atomically replace x86_64/ contents with selected latest builds
mkdir -p "${ARCH_DIR}"
rm -f "${ARCH_DIR}"/dusky_*.pkg.tar.zst "${ARCH_DIR}"/dusky.db* "${ARCH_DIR}"/dusky.files*
cp "${STAGING_DIR}"/dusky_*.pkg.tar.zst "${ARCH_DIR}/"
cp "${STAGING_DIR}/manifest.json" "${REPO_ROOT}/manifest.json"

repo-add "${ARCH_DIR}/dusky.db.tar.zst" "${ARCH_DIR}"/dusky_*.pkg.tar.zst
rm -f "${ARCH_DIR}/dusky.db" "${ARCH_DIR}/dusky.files"
cp "${ARCH_DIR}/dusky.db.tar.zst" "${ARCH_DIR}/dusky.db"
cp "${ARCH_DIR}/dusky.files.tar.zst" "${ARCH_DIR}/dusky.files"

# Final 1:1 parity gate between dusky.db.tar.zst and manifest.json
python3.15 - "${REPO_ROOT}" <<'PY'
import json
from pathlib import Path
import sys
import tarfile

repo_root = Path(sys.argv[1])
manifest_pkgs = set(json.loads((repo_root / "manifest.json").read_text(encoding="utf-8"))["packages"])

with tarfile.open(repo_root / "x86_64" / "dusky.db.tar.zst", mode="r:zst") as db_tf:
    db_pkgs = {
        Path(m.name).parent.name.rsplit("-", 2)[0]
        for m in db_tf.getmembers()
        if m.name.endswith("/desc")
    }

if db_pkgs != manifest_pkgs:
    raise RuntimeError(f"Parity check failed: db={db_pkgs}, manifest={manifest_pkgs}")
print(f"Verified 1:1 parity across {len(manifest_pkgs)} packages in dusky.db and manifest.json.")
PY

cd "${REPO_ROOT}"
git add manifest.json x86_64/
if git diff --cached --quiet; then
    echo "Git working tree clean; nothing to commit."
    exit 0
fi

git commit -m "release: sync precompiled dusky packages ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
git push origin main
