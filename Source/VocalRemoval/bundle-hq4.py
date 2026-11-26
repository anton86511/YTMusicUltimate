"""Extract the verified Inst HQ 4 Core ML model from the previous build."""
import argparse
import hashlib
from pathlib import Path
import shutil
import zipfile

SHA256 = "889e54985f6f3c51f6dc68ae7808e37480db99db7aa4e3b4ca012d238f7a90ac"
PREFIX = "Payload/Spotify.app/InstHQ4.mlmodelc/"


def bundle(source, output):
    with source.open("rb") as asset:
        digest = hashlib.file_digest(asset, "sha256").hexdigest()
    if digest != SHA256:
        raise ValueError("Model source SHA-256 mismatch")
    with zipfile.ZipFile(source) as archive:
        files = {name.removeprefix(PREFIX): name for name in archive.namelist()
                 if name.startswith(PREFIX) and not name.endswith("/")}
        if not {"model.mil", "coremldata.bin", "weights/weight.bin"} <= files.keys():
            raise ValueError("Compiled Core ML model is incomplete")
        output.mkdir()
        for relative, name in files.items():
            out = output / relative
            if not out.resolve().is_relative_to(output.resolve()):
                raise ValueError("Unexpected model path")
            out.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(name) as data, out.open("wb") as destination:
                shutil.copyfileobj(data, destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    bundle(args.source, args.output)
