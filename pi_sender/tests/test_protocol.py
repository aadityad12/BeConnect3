from beconnect_pi.protocol import (
    chunk,
    decode_chunk_index,
    decode_payload,
    decode_total_chunks,
    encode_chunk,
    reassemble,
)


def test_roundtrip_small_payload() -> None:
    original = b"Hello, BeConnect!"
    parts = chunk(original, 5)
    assert reassemble(parts) == original


def test_roundtrip_large_payload() -> None:
    original = bytes([i % 256 for i in range(1500)])
    parts = chunk(original, 17)
    assert reassemble(parts) == original


def test_encode_decode_frame() -> None:
    payload = b"test"
    frame = encode_chunk(3, 10, payload)
    assert decode_chunk_index(frame) == 3
    assert decode_total_chunks(frame) == 10
    assert decode_payload(frame) == payload


def test_chunk_count() -> None:
    data = bytes(50)
    parts = chunk(data, 17)
    assert len(parts) == 3
