"""Source classification: paths, bytes-likes, binary readers, names."""

from __future__ import annotations

import io
from pathlib import Path

import pytest
from support import FakeBridge, success_payload

import zenfmt


def last_request(bridge: FakeBridge) -> dict:
    return bridge.requests[-1]


def test_str_is_always_a_path(fake_bridge: FakeBridge, tmp_path: Path) -> None:
    fake_bridge.queue(success_payload())
    target = tmp_path / "note.md"
    target.write_bytes(b"# T\n")
    zenfmt.convert(str(target))
    request = last_request(fake_bridge)
    assert request["options"]["input"]["kind"] == "path"
    assert request["input_path"] is not None
    assert request["input_bytes"] is None


def test_pathlike_is_a_path(fake_bridge: FakeBridge, tmp_path: Path) -> None:
    fake_bridge.queue(success_payload())
    zenfmt.convert(tmp_path / "note.md")
    assert last_request(fake_bridge)["options"]["input"]["kind"] == "path"


def test_broken_path_protocol_is_an_elm_style_argument_error(
    fake_bridge: FakeBridge,
) -> None:
    class BrokenPath:
        def __fspath__(self) -> str:
            raise OSError("path provider failed")

    with pytest.raises(TypeError, match="PATH-LIKE VALUE") as info:
        zenfmt.convert(BrokenPath())
    assert isinstance(info.value.__cause__, OSError)
    assert "What you can do:" in str(info.value)
    assert fake_bridge.requests == []


@pytest.mark.parametrize(
    "source",
    [b"# T\n", bytearray(b"# T\n"), memoryview(b"# T\n")],
    ids=["bytes", "bytearray", "memoryview"],
)
def test_bytes_likes_pass_as_memory(fake_bridge: FakeBridge, source: object) -> None:
    fake_bridge.queue(success_payload())
    zenfmt.convert(source, name="note.md")
    request = last_request(fake_bridge)
    assert request["options"]["input"] == {"kind": "bytes", "name": "note.md"}
    assert request["input_bytes"] == b"# T\n"


def test_bytes_without_name_use_memory_placeholder(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    zenfmt.convert(b"# T\n")
    assert last_request(fake_bridge)["options"]["input"]["name"] == "<memory>"


def test_reader_is_consumed_without_seek_or_close(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    reader = io.BytesIO(b"# T\n\nbody\n")
    reader.seek(2)
    zenfmt.convert(reader, name="note.md")
    assert last_request(fake_bridge)["input_bytes"] == b"T\n\nbody\n"
    assert not reader.closed


def test_reader_name_attribute_is_sanitized_not_opened(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())

    class Named(io.BytesIO):
        name = "/private/uploads/deck.pptx"

    zenfmt.convert(Named(b"data"))
    assert last_request(fake_bridge)["options"]["input"]["name"] == "deck.pptx"


def test_reader_without_usable_name_is_stream(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())

    class Numbered(io.BytesIO):
        name = 7  # file descriptor: never used

    zenfmt.convert(Numbered(b"data"))
    assert last_request(fake_bridge)["options"]["input"]["name"] == "<stream>"


def test_reader_name_property_failure_is_ignored(fake_bridge: FakeBridge) -> None:
    fake_bridge.queue(success_payload())

    class Reader:
        @property
        def name(self) -> str:
            raise OSError("display name unavailable")

        def read(self, size: int) -> bytes:
            return b""

    zenfmt.convert(Reader())
    assert last_request(fake_bridge)["options"]["input"]["name"] == "<stream>"


def test_reader_is_capped_one_byte_past_the_limit(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    limits = zenfmt.Limits(max_input_bytes=8)
    reader = io.BytesIO(b"0123456789abcdef")
    zenfmt.convert(reader, name="big.md", limits=limits)
    # Exactly cap + 1 bytes were consumed and submitted; the engine owns
    # the canonical limit report.
    assert last_request(fake_bridge)["input_bytes"] == b"012345678"
    assert reader.tell() == 9


def test_reader_at_exact_boundary_is_not_overflow(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    limits = zenfmt.Limits(max_input_bytes=8)
    zenfmt.convert(io.BytesIO(b"01234567"), name="ok.md", limits=limits)
    assert last_request(fake_bridge)["input_bytes"] == b"01234567"


def test_reader_exception_becomes_input_read_error(
    fake_bridge: FakeBridge,
) -> None:
    class Broken:
        def read(self, size: int) -> bytes:
            raise OSError("disk gone")

    with pytest.raises(zenfmt.InputReadError) as info:
        zenfmt.convert(Broken())
    assert isinstance(info.value.__cause__, OSError)
    assert info.value.code == "python.reader-failed"


def test_text_mode_reader_is_rejected(fake_bridge: FakeBridge) -> None:
    with pytest.raises(zenfmt.InputReadError, match="NON-BYTES"):
        zenfmt.convert(io.StringIO("text"))


@pytest.mark.parametrize("source", [7, 1.5, None, ["a"]])
def test_invalid_source_types_fail_before_native_work(
    fake_bridge: FakeBridge, source: object
) -> None:
    with pytest.raises(TypeError, match="INVALID SOURCE TYPE"):
        zenfmt.convert(source)
    assert fake_bridge.requests == []


def test_name_with_path_source_is_rejected(fake_bridge: FakeBridge) -> None:
    with pytest.raises(ValueError, match="NAME IS ONLY FOR IN-MEMORY"):
        zenfmt.convert("note.md", name="other.md")


@pytest.mark.parametrize(
    "name",
    ["", "a/b.md", "a\\b.md", "a\x00b", "a\nb"],
    ids=["empty", "slash", "backslash", "nul", "newline"],
)
def test_invalid_display_names_are_rejected(fake_bridge: FakeBridge, name: str) -> None:
    with pytest.raises(ValueError, match="INVALID DISPLAY NAME"):
        zenfmt.convert(b"data", name=name)
    assert fake_bridge.requests == []
