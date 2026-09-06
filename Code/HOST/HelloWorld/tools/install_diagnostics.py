#!/usr/bin/env python3
"""Install the maintained diagnostic COM files into the CP/M disk image."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


# Build filename -> CP/M filename.  Keep legacy aliases explicit here.
DIAGNOSTICS = (
    ("ioc_ping.com", "ping.com"),
    ("ioc_reset.com", "reset.com"),
    ("ioc_rts_probe.com", "rtsprobe.com"),
    ("ioc_sd_read.com", "sdread.com"),
    ("ioc_bulk.com", "bulk.com"),
    ("ioc_sdblk.com", "sdblk.com"),
    ("ioc_sdwrite.com", "sdwrite.com"),
    ("ioc_sdsoak.com", "sdsoak.com"),
    ("ioc_sdrec.com", "sdrec.com"),
    ("ioc_sdfmt.com", "sdfmt.com"),
    ("ioc_sdbench.com", "sdbench.com"),
    ("hidkey.com", "hidkey.com"),
    ("padstat.com", "padstat.com"),
    ("sndtest.com", "sndtest.com"),
)


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as error:
        raise SystemExit(f"required command not found: {command[0]}") from error
    except subprocess.CalledProcessError as error:
        if error.stdout:
            sys.stderr.write(error.stdout)
        if error.stderr:
            sys.stderr.write(error.stderr)
        raise SystemExit(
            f"command failed with status {error.returncode}: {' '.join(command)}"
        ) from error


def image_directory(image: Path, disk_format: str, user: int) -> set[str]:
    result = run(
        ["cpmls", "-f", disk_format, "-l", str(image), f"{user}:*.*"]
    )
    names: set[str] = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields and fields[0].startswith("-"):
            names.add(fields[-1].lower())
    return names


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--staging-dir", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--format", dest="disk_format", required=True)
    parser.add_argument("--user", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.user <= 15:
        parser.error("--user must be between 0 and 15")
    return args


def main() -> int:
    args = parse_args()
    build_dir = args.build_dir.resolve()
    staging_dir = args.staging_dir.resolve()
    image = args.image.resolve()

    if not image.is_file():
        raise SystemExit(f"CP/M image not found: {image}")

    missing = [str(build_dir / source) for source, _ in DIAGNOSTICS
               if not (build_dir / source).is_file()]
    if missing:
        raise SystemExit("missing diagnostic build output:\n  " + "\n  ".join(missing))

    staging_dir.mkdir(parents=True, exist_ok=True)
    for source, destination in DIAGNOSTICS:
        shutil.copy2(build_dir / source, staging_dir / destination)

    temporary_file = tempfile.NamedTemporaryFile(
        prefix=f".{image.name}.", suffix=".tmp", dir=image.parent, delete=False
    )
    temporary_image = Path(temporary_file.name)
    temporary_file.close()
    shutil.copy2(image, temporary_image)

    destinations = [destination for _, destination in DIAGNOSTICS]
    try:
        existing = image_directory(temporary_image, args.disk_format, args.user)
        replacements = [
            f"{args.user}:{destination}"
            for destination in destinations
            if destination.lower() in existing
        ]
        if replacements:
            run(
                ["cpmrm", "-f", args.disk_format, str(temporary_image)]
                + replacements
            )

        run(
            ["cpmcp", "-f", args.disk_format, str(temporary_image)]
            + [str(staging_dir / destination) for destination in destinations]
            + [f"{args.user}:"]
        )

        with tempfile.TemporaryDirectory(prefix="ioc-diag-verify-") as directory:
            verification_dir = Path(directory)
            run(
                ["cpmcp", "-f", args.disk_format, str(temporary_image)]
                + [f"{args.user}:{destination}" for destination in destinations]
                + [str(verification_dir)]
            )
            for destination in destinations:
                staged = staging_dir / destination
                extracted = verification_dir / destination.lower()
                if not extracted.is_file() or staged.read_bytes() != extracted.read_bytes():
                    raise SystemExit(f"image verification failed for {destination}")

        os.replace(temporary_image, image)
    finally:
        temporary_image.unlink(missing_ok=True)

    print(
        f"installed and verified {len(destinations)} diagnostic files "
        f"in {image} (user {args.user})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
