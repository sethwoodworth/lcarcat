"""Transmitting curve PNGs to kitty and handing back placeholder coordinates.

Images are sent once per image with a fixed id and a *virtual* placement
(``U=1``), sized in cells. The dashboard then writes placeholder cells into the
canvas addressing that cell grid, so the curve is part of the text stream rather
than pinned to a screen position -- the same mechanism the zsh prompt uses, and
the reason a resize does not leave elbows stranded in scrollback.

Bytes are sent inline (``t=d``) rather than as a file path (``t=f``). Inline is
synchronous: kitty has the whole image in one read and registers it before the
placeholder cells arrive in the next write. A path is opened on kitty's own
schedule, which can miss the first draw, and leaves kitty holding a mapping of a
file the asset cache may rewrite underneath it.
"""
from __future__ import annotations

import base64
import hashlib
import sys
from pathlib import Path
from typing import Dict, List, Optional, TextIO, Tuple

from .assets import Asset

# kitty caps one graphics escape at 4096 bytes of base64 payload; anything larger
# is split across continuation escapes carrying only the chunk marker.
CHUNK = 4096

# The image id travels in the cell's 256-color foreground, so ids must stay below
# 256. Starting at 16 leaves the low ids to the zsh prompt (1-4) and a little room
# under them, so a dashboard running in a pane beside a prompt cannot collide.
FIRST_IMAGE_ID = 16
LAST_IMAGE_ID = 255


class ImageTransmitter:
    """Assigns image ids and emits the transmission escapes for a render.

    One transmitter per dashboard process. Assets already sent are not resent, so
    a redraw loop pays the base64 cost once per distinct curve.
    """

    def __init__(self, stream: Optional[TextIO] = None) -> None:
        self.stream = stream if stream is not None else sys.stdout
        self._ids: Dict[Path, int] = {}
        self._sent: set = set()
        self._dynamic_ids: Dict[str, int] = {}
        self._dynamic_digests: Dict[str, bytes] = {}
        self._next_id = FIRST_IMAGE_ID

    def image_id(self, asset: Asset) -> int:
        """The id for an asset, allocating one on first sight."""
        existing = self._ids.get(asset.path)
        if existing is not None:
            return existing
        if self._next_id > LAST_IMAGE_ID:
            raise RuntimeError(
                "ran out of kitty image ids (%d..%d); a layout is asking for more "
                "distinct curves than the 256-color foreground channel can address"
                % (FIRST_IMAGE_ID, LAST_IMAGE_ID)
            )
        allocated = self._next_id
        self._next_id += 1
        self._ids[asset.path] = allocated
        return allocated

    def transmission(self, asset: Asset) -> str:
        """Escapes registering ``asset`` with kitty. Empty if already sent."""
        image_id = self.image_id(asset)
        if asset.path in self._sent:
            return ""
        payload = base64.b64encode(asset.path.read_bytes()).decode("ascii")
        if not payload:
            return ""
        self._sent.add(asset.path)
        # Control data rides the first escape only; m=1 means more follows.
        return self._escapes(image_id, payload, asset.columns, asset.rows)

    def dynamic_transmission(
        self,
        key: str,
        png_bytes: bytes,
        columns: int,
        rows: int,
    ) -> Tuple[str, int]:
        """Transmit in-memory PNG bytes under a stable id. Returns ``(escapes, id)``.

        The counterpart to :meth:`transmission`, which is for assets cached on disk
        under a filename that fully describes them. A plot changes whenever its data
        does, so it has no such filename -- it is keyed by a caller-chosen name and
        re-sent only when the bytes actually differ. Retransmitting under the same id
        replaces the image in kitty, so the placeholder cells already on screen pick
        up the new picture without being rewritten.

        Digesting the bytes rather than trusting the caller to say "this changed"
        means a widget that recomputes an identical plot costs nothing.
        """
        image_id = self._dynamic_ids.get(key)
        if image_id is None:
            if self._next_id > LAST_IMAGE_ID:
                raise RuntimeError(
                    "ran out of kitty image ids (%d..%d)"
                    % (FIRST_IMAGE_ID, LAST_IMAGE_ID))
            image_id = self._next_id
            self._next_id += 1
            self._dynamic_ids[key] = image_id

        digest = hashlib.sha256(png_bytes).digest()
        if self._dynamic_digests.get(key) == digest:
            return ("", image_id)
        self._dynamic_digests[key] = digest

        payload = base64.b64encode(png_bytes).decode("ascii")
        if not payload:
            return ("", image_id)
        return (self._escapes(image_id, payload, columns, rows), image_id)

    def _escapes(self, image_id: int, payload: str, columns: int, rows: int) -> str:
        if len(payload) <= CHUNK:
            return "\x1b_Ga=T,U=1,i=%d,f=100,t=d,c=%d,r=%d,q=2;%s\x1b\\" % (
                image_id, columns, rows, payload)
        parts: List[str] = [
            "\x1b_Ga=T,U=1,i=%d,f=100,t=d,c=%d,r=%d,q=2,m=1;%s\x1b\\" % (
                image_id, columns, rows, payload[:CHUNK])
        ]
        offset = CHUNK
        while len(payload) - offset > CHUNK:
            parts.append("\x1b_Gm=1;%s\x1b\\" % payload[offset:offset + CHUNK])
            offset += CHUNK
        parts.append("\x1b_Gm=0;%s\x1b\\" % payload[offset:])
        return "".join(parts)

    def forget(self) -> None:
        """Drop the sent-set so the next render retransmits.

        Called when the cell size changes: kitty still has the image cached under
        its id, but a PNG built for the old metrics will aspect-fit into the new
        cell box and inset by a pixel or two.
        """
        self._sent.clear()

    def delete_all(self) -> str:
        """Escape clearing every image this process placed, for a clean exit."""
        return "\x1b_Ga=d,d=A,q=2;\x1b\\"
