"""Independent float64 CPU oracle for the settled tiled product image.

No app invocation or recorded GPU output participates in reference generation.
Pixel centres, palette sampling, colour filtering and optional box mipmaps are
expressed here independently of the Swift/Metal implementation.
"""
from functools import lru_cache
import math
import struct
import zlib


def write_png(path, width, height, pixels):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + pixels[y*width*4:(y+1)*width*4] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def read_png(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset, compressed = 8, b''
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset+4])[0]
        kind, payload = data[offset+4:offset+8], data[offset+8:offset+8+length]
        if kind == b'IHDR':
            width, height, depth, colour, _, _, interlace = struct.unpack('>IIBBBBB', payload)
            assert depth == 8 and colour in (2, 6) and interlace == 0
            channels = 4 if colour == 6 else 3
        if kind == b'IDAT':
            compressed += payload
        offset += length + 12
    raw = zlib.decompress(compressed)
    stride = width * channels
    previous = bytearray(stride)
    result = bytearray()
    for y in range(height):
        start = y * (stride + 1)
        mode, row = raw[start], bytearray(raw[start+1:start+1+stride])
        for x in range(stride):
            a = row[x-channels] if x >= channels else 0
            b = previous[x]
            c = previous[x-channels] if x >= channels else 0
            if mode == 0:
                predictor = 0
            elif mode == 1:
                predictor = a
            elif mode == 2:
                predictor = b
            elif mode == 3:
                predictor = (a+b)//2
            else:
                assert mode == 4
                p = a+b-c
                predictor = min((a,b,c), key=lambda v: abs(p-v))
            row[x] = (row[x] + predictor) & 255
        if channels == 4:
            result.extend(row)
        else:
            for x in range(0, stride, 3):
                result.extend(row[x:x+3]); result.append(255)
        previous = row
    return width, height, bytes(result)


def reference(fixture):
    width, height, scale = fixture['width'], fixture['height'], fixture['scale']
    cx, cy = fixture['center']
    limit = fixture['iterations']
    span = 3/scale
    lod = max(-2, math.log2(scale*width/256))
    fine, base = math.ceil(lod), math.floor(lod)
    # Define the requested tile set geometrically, not via the app's grid code.
    tile_span = 3 / 2**fine
    x0, x1 = math.floor((cx-span/2+0.5)/tile_span), math.ceil((cx+span/2+0.5)/tile_span)
    y0, y1 = math.floor((-cy-span*height/width/2)/tile_span), math.ceil((-cy+span*height/width/2)/tile_span)
    needed = set()
    for y in range(y0, y1):
        for x in range(x0, x1):
            for level in range(max(-2, fine-2), fine+1):
                needed.add((level, x // 2**(fine-level), y // 2**(fine-level)))
    stops = [(8,12,21), (83,97,113), (255,255,255), (83,97,113), (8,12,21)]
    lut = []
    for i in range(1024):
        position = i/1024*4
        index, t = int(position), position % 1
        lut.append(tuple(int(a*(1-t)+b*t) for a,b in zip(stops[index], stops[index+1])))

    @lru_cache(None)
    def sample(level, ix, iy):
        step = 3 / 2**level / 256
        cr, ci = -0.5+(ix+0.5)*step, -(iy+0.5)*step
        zr = zi = 0.0
        n = 0
        while n < limit and zr*zr+zi*zi <= 65536:
            zr, zi = zr*zr-zi*zi+cr, 2*zr*zi+ci
            n += 1
        if n == limit:
            return (1,2,4)
        smooth = max(0, n+1-math.log2(math.log2(math.hypot(zr,zi))))
        position = smooth/64*1024-0.5
        left, t = math.floor(position), position % 1
        return tuple(round(a*(1-t)+b*t) for a,b in zip(lut[left%1024],lut[(left+1)%1024]))

    @lru_cache(None)
    def texel(level, tx, ty, x, y):
        gx, gy = tx*256+x, ty*256+y
        children = [(level+1,tx*2+dx,ty*2+dy) for dy in (0,1) for dx in (0,1)]
        if 0 <= x < 256 and 0 <= y < 256 and all(child in needed for child in children):
            colours = [texel(level+1, (gx*2+dx)//256, (gy*2+dy)//256,
                            (gx*2+dx)%256, (gy*2+dy)%256) for dy in (0,1) for dx in (0,1)]
            return tuple(round(sum(c[channel] for c in colours)/4) for channel in range(3))
        return sample(level, gx, gy)

    def filtered(level, cr, ci):
        step = 3 / 2**level / 256
        gx, gy = (cr+0.5)/step, -ci/step
        tx, ty = math.floor(gx/256), math.floor(gy/256)
        sx, sy = gx-tx*256-0.5, gy-ty*256-0.5
        x, y = math.floor(sx), math.floor(sy)
        fx, fy = sx-x, sy-y
        colours = [texel(level, tx, ty, x+dx, y+dy) for dy in (0,1) for dx in (0,1)]
        return tuple((colours[0][i]*(1-fx)+colours[1][i]*fx)*(1-fy)
                     +(colours[2][i]*(1-fx)+colours[3][i]*fx)*fy for i in range(3))

    pixels = bytearray()
    for y in range(height):
        ci = cy+(height/2-y-0.5)*span/width
        for x in range(width):
            cr = cx+(x+0.5-width/2)*span/width
            a, b = filtered(base, cr, ci), filtered(fine, cr, ci)
            pixels.extend(round(v*(1-(lod-base))+w*(lod-base)) for v,w in zip(a,b))
            pixels.append(255)
    return bytes(pixels)
