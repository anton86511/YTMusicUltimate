"""Route the app's callback registration through the injected playback effect."""
import argparse
from pathlib import Path
import struct


def bind(executable, check_only=False):
    data = bytearray(executable.read_bytes())
    magic, cpu, _, _, commands, size = struct.unpack_from("<6I", data)
    if (magic, cpu) != (0xFEEDFACF, 0x100000C):
        raise ValueError("Expected a thin arm64 executable")
    ordinal_names = []
    cursor = 32
    fixups = None
    for _ in range(commands):
        command, length = struct.unpack_from("<II", data, cursor)
        if length < 8 or cursor + length > 32 + size:
            raise ValueError("Invalid Mach-O load command")
        if command in (0xC, 0x18, 0x20, 0x80000018, 0x8000001F, 0x80000023):
            rel = struct.unpack_from("<I", data, cursor + 8)[0]
            ordinal_names.append(data[cursor + rel:cursor + length].split(b"\0")[0])
        elif command == 0x80000034:
            fixups = struct.unpack_from("<II", data, cursor + 8)
        elif command == 0x2C and struct.unpack_from("<I", data, cursor + 16)[0]:
            raise ValueError("The executable supplied is still encrypted")
        cursor += length

    if not fixups:
        raise ValueError("The executable has no chained imports")
    base, size = fixups
    end = base + size
    version, _, imports, names, count, kind, encoding = struct.unpack_from("<7I", data, base)
    if version or encoding or kind not in (1, 2, 3):
        raise ValueError("Unsupported chained import format")
    layout, stride, shift, mask = {1: ("<I", 4, 9, 255), 2: ("<I", 8, 9, 255),
                                   3: ("<Q", 16, 32, 65535)}[kind]
    if base + imports + stride * count > base + names or end > len(data):
        raise ValueError("Invalid chained import offsets")
    targets = [i for i, name in enumerate(ordinal_names, 1) if name.endswith(b"/YTMusicUltimate.dylib")]
    if not check_only and (len(targets) != 1 or targets[0] > mask - 15):
        raise ValueError("The app must have exactly one addressable YTMusicUltimate dependency")
    bound = 0
    for index in range(count):
        position = base + imports + index * stride
        record, = struct.unpack_from(layout, data, position)
        name_start = base + names + (record >> shift)
        if data[name_start:data.index(0, name_start, end)] != b"_AudioUnitSetProperty":
            continue
        old = record & mask
        if not 0 < old <= len(ordinal_names) or b"AudioToolbox" not in ordinal_names[old - 1]:
            raise ValueError("Unexpected provider of AudioUnitSetProperty")
        if not check_only:
            struct.pack_into(layout, data, position, (record & ~mask) | targets[0])
        bound += 1
    if not bound:
        raise ValueError("AudioUnitSetProperty import not found")
    if not check_only:
        executable.write_bytes(data)
    print(f"Verified {bound} AudioUnitSetProperty import(s)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("--check-only", action="store_true")
    arguments = parser.parse_args()
    bind(arguments.executable, arguments.check_only)
