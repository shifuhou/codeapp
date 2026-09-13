#!/usr/bin/env python3
"""Convert an XWD dump (ZPixmap, 24/32 bpp) to PNG. No ImageMagick needed."""
import struct, sys, zlib

data = open(sys.argv[1], 'rb').read()
h = struct.unpack('>25I', data[:100])
header_size, width, height = h[0], h[4], h[5]
byte_order, bpp, bpl = h[7], h[11], h[12]
rmask, gmask, bmask, ncolors = h[14], h[15], h[16], h[19]
off = header_size + ncolors * 12
step = bpp // 8
# Byte index of each channel inside a pixel.
def idx(mask):
    shift = (mask.bit_length() - 8)
    return shift // 8 if byte_order == 0 else step - 1 - shift // 8
ri, gi, bi = idx(rmask), idx(gmask), idx(bmask)
rows = []
for y in range(height):
    row = data[off + y * bpl: off + y * bpl + width * step]
    out = bytearray(width * 3)
    out[0::3] = row[ri::step][:width]
    out[1::3] = row[gi::step][:width]
    out[2::3] = row[bi::step][:width]
    rows.append(b'\x00' + bytes(out))
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(b''.join(rows), 6))
       + chunk(b'IEND', b''))
open(sys.argv[2], 'wb').write(png)
print(f'{sys.argv[2]} {width}x{height}')
