"""Re-serialise a PDF/A file with object streams and a cross-reference stream.

No tool on this machine writes PDF 1.5+ cross-reference streams — Ghostscript's
pdfwrite emits a classic table, and pypdf's writer likewise — so the fixture that
exercises that path has to be built here.

It is not trusted on its own: `mix facturx.harness` runs veraPDF over the result
before using it, so a base that is not itself PDF/A proves nothing about what we
write from it.

    .venv-dev/bin/python dev/tools/xref_stream_base.py in.pdf out.pdf
"""

import sys
import zlib

from pypdf import PdfReader, PdfWriter
from pypdf.generic import StreamObject


def serialise(obj):
    from io import BytesIO

    buf = BytesIO()
    obj.write_to_stream(buf)
    return buf.getvalue()


def build(src, dst):
    writer = PdfWriter(clone_from=PdfReader(src))
    objects = writer._objects  # 1-based: object N is objects[N - 1]
    size = len(objects) + 2  # + the object stream and the xref stream

    # A stream cannot live inside an object stream (PDF 32000-1, 7.5.7), so the
    # split is not a choice: streams stay top level, everything else is packed.
    top_level, packed = [], []
    for number, obj in enumerate(objects, start=1):
        (top_level if isinstance(obj, StreamObject) else packed).append((number, obj))

    objstm_num = len(objects) + 1
    xref_num = objstm_num + 1

    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}

    for number, obj in top_level:
        offsets[number] = len(out)
        out += b"%d 0 obj\n" % number + serialise(obj) + b"\nendobj\n"

    # The object stream: a header of "number offset" pairs, then the objects.
    bodies, header = [], []
    cursor = 0
    for index, (number, obj) in enumerate(packed):
        body = serialise(obj)
        header.append(b"%d %d" % (number, cursor))
        bodies.append(body)
        cursor += len(body) + 1

    head = b" ".join(header) + b"\n"
    data = head + b"\n".join(bodies) + b"\n"
    compressed = zlib.compress(data)

    offsets[objstm_num] = len(out)
    out += b"%d 0 obj\n<< /Type /ObjStm /N %d /First %d /Filter /FlateDecode /Length %d >>\nstream\n" % (
        objstm_num,
        len(packed),
        len(head),
        len(compressed),
    )
    out += compressed + b"\nendstream\nendobj\n"

    # The cross-reference stream. W [1 4 2]: one byte of type, four of offset or
    # object-stream number, two of generation or index. No predictor.
    positions = {number: index for index, (number, _) in enumerate(packed)}
    entries = bytearray()
    entries += b"\x00" + (0).to_bytes(4, "big") + (65535).to_bytes(2, "big")  # object 0, free

    for number in range(1, size):
        if number in offsets:
            entries += b"\x01" + offsets[number].to_bytes(4, "big") + (0).to_bytes(2, "big")
        elif number in positions:
            entries += b"\x02" + objstm_num.to_bytes(4, "big") + positions[number].to_bytes(2, "big")
        else:
            entries += b"\x00" + (0).to_bytes(4, "big") + (65535).to_bytes(2, "big")

    xref_offset = len(out)
    entries += b"\x01" + xref_offset.to_bytes(4, "big") + (0).to_bytes(2, "big")

    trailer = writer._root_object.indirect_reference
    root = b"%d 0 R" % trailer.idnum
    info = b""
    if writer._info is not None and writer._info.indirect_reference is not None:
        info = b" /Info %d 0 R" % writer._info.indirect_reference.idnum

    doc_id = b"<0123456789ABCDEF0123456789ABCDEF>"
    xref_data = zlib.compress(bytes(entries))

    out += b"%d 0 obj\n<< /Type /XRef /Size %d /W [1 4 2] /Root %s%s /ID [%s %s] /Filter /FlateDecode /Length %d >>\nstream\n" % (
        xref_num,
        size + 1,
        root,
        info,
        doc_id,
        doc_id,
        len(xref_data),
    )
    out += xref_data + b"\nendstream\nendobj\n"
    out += b"startxref\n%d\n%%%%EOF\n" % xref_offset

    with open(dst, "wb") as fh:
        fh.write(bytes(out))

    print(
        "%s: %d objects, %d packed into one object stream, cross-reference stream at %d"
        % (dst, size, len(packed), xref_offset)
    )


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2])
