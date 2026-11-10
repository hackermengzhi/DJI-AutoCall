#!/usr/bin/env python3
"""Fetch pinned Pocket TTS assets into a local, ignored runtime directory."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import tarfile
import tempfile
import time
import subprocess

ROOT = Path(__file__).resolve().parent.parent
RELEASE = "https://github.com/kyutai-labs/pocket-tts/releases/download/v4.0.1/"
MODEL_BASE = "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/"
ASSETS = [
    ("model.safetensors", MODEL_BASE + "a7056f505a4a8ca72d8b5fb1440071d6f1a35739/languages/english_2026-10/model.safetensors",
     "4c56cbd171c63e8a26ea61f5d48b8a0cd8f3c51f4652c0ab9a19bfcced8c931d"),
    ("alba.safetensors", MODEL_BASE + "main/languages/english/embeddings/alba.safetensors",
     "5850f417028fb2bf6de31e5e395e56ee7a21ac0e52ef31aebd4a6a2847d72e9c"),
    ("tokenizer.json", MODEL_BASE + "00eac05ed3d16bdc3f6b5d598874019c34a89214/languages/english_2026-09/tokenizer.json",
     "f498428e1eafee50492f7be13dc9bfafcfc12e508cd0eb1b01c92ecd5d8c6687"),
]
ARCHIVES = {
    "arm64": ("pocket-tts-3.3.0-aarch64-apple-darwin.tar.gz",
              "ee9ca6c7c000ee72c5846e3a8ba01d08f56636d94a614d2259c3f12b8fd69afa"),
    "x86_64": ("pocket-tts-3.3.0-x86_64-apple-darwin.tar.gz",
               "f04baa94d4fc47a689cc9f11ca2b0ba869dc002f9e78e15d387c6ecaeb1d654b"),
}


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def download(url, destination, expected):
    if destination.is_file() and digest(destination) == expected:
        print("Verified cached", destination.name)
        return
    last_error = None
    for attempt in range(3):
        temporary = destination.with_suffix(destination.suffix + ".part")
        try:
            print("Downloading", destination.name, flush=True)
            # Use the system downloader and its macOS certificate trust store.
            subprocess.run([
                "/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                "--connect-timeout", "15", "--max-time", "300",
                "--output", str(temporary), url,
            ], check=True)
            if digest(temporary) != expected:
                raise ValueError("SHA-256 verification failed for " + destination.name)
            temporary.replace(destination)
            return
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            temporary.unlink(missing_ok=True)
            last_error = error
            time.sleep(attempt + 1)
    raise RuntimeError("Could not download " + destination.name) from last_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=ROOT / ".local" / "pocket-tts")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() not in ARCHIVES:
        parser.error("This installer supports macOS arm64 and x86_64 only")
    destination = args.destination.expanduser().resolve()
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    archive_name, checksum = ARCHIVES[platform.machine()]
    with tempfile.TemporaryDirectory(prefix="djiautocall-tts-") as temporary:
        archive = Path(temporary) / archive_name
        download(RELEASE + archive_name, archive, checksum)
        with tarfile.open(archive) as package:
            # Extract only expected files, never arbitrary archive paths/symlinks.
            for filename in ["pocket-tts", "LICENSE"]:
                member = next(item for item in package.getmembers()
                              if item.isfile() and Path(item.name).name == filename)
                stream = package.extractfile(member)
                with stream, (destination / filename).open("wb") as target:
                    shutil.copyfileobj(stream, target)
        (destination / "pocket-tts").chmod(0o755)
    for name, url, expected in ASSETS:
        download(url, destination / name, expected)
    shutil.copy2(ROOT / "packaging/pocket-tts/english.yaml", destination / "english.yaml")
    (destination / "asset-manifest.json").write_text(json.dumps(
        {"release": "v4.0.1", "assets": [{"name": name, "sha256": checksum}
                                          for name, _, checksum in ASSETS]}, indent=2) + "\n")
    print("Pocket TTS ready at", destination)


if __name__ == "__main__":
    main()
