"""Draws changemylocation's pixel-art icon on a 32x32 grid and writes it at any size."""
import sys
from PIL import Image

N = 32
GRASS, GRASS2 = (64, 160, 92), (74, 172, 102)
ROAD, DASH = (238, 236, 226), (250, 204, 72)
WATER, WATER2 = (66, 153, 225), (96, 175, 240)
TREE, TRUNK = (36, 112, 62), (30, 86, 50)
SHADOW = (30, 70, 45)
PIN = {"O": (120, 18, 14), "R": (240, 64, 52), "H": (255, 140, 120), "D": (196, 36, 28), "W": (255, 255, 255)}

PIN_ART = """
....OOOOO....
..OORRRRROO..
.ORRHHRRRRRO.
.ORHRRRRRRDO.
ORHRRWWWRRRDO
ORHRWWWWWRRDO
ORRRWWWWWRRDO
ORRRWWWWWRRDO
ORRRRWWWRRRDO
.ORRRRRRRRDO.
.ORRRRRRRRDO.
..ORRRRRRDO..
..ORRRRRRDO..
...ORRRRDO...
....ORRDO....
....ORRDO....
.....ORO.....
......O......
""".strip().splitlines()

def draw():
    im = Image.new("RGBA", (N, N))
    px = im.load()
    for y in range(N):
        for x in range(N):
            px[x, y] = GRASS2 if (x // 4 + y // 4) % 2 == 0 else GRASS
    # a river in the bottom-left corner
    for y in range(N):
        for x in range(N):
            if (x - 1) ** 2 + (y - 31) ** 2 < 80:
                px[x, y] = WATER2 if (x + y) % 5 == 0 else WATER
    # two streets crossing under the pin, with dashed centre lines
    for x in range(N):
        for y in (21, 22, 23):
            px[x, y] = ROAD
        if x % 4 < 2:
            px[x, 22] = DASH
    for y in range(N):
        for x in (22, 23, 24):
            if px[x, y] != DASH:
                px[x, y] = ROAD
        if y % 4 < 2 and not 21 <= y <= 23:
            px[23, y] = DASH
    # a few trees
    for tx, ty in [(4, 4), (27, 5), (28, 14), (5, 13), (13, 28), (28, 28)]:
        for dx, dy in [(0, 0), (1, 0), (0, 1), (1, 1), (-1, 0), (0, -1), (1, -1), (2, 0)]:
            if 0 <= tx + dx < N and 0 <= ty + dy < N:
                px[tx + dx, ty + dy] = TREE
        px[tx, ty + 2] = TRUNK
    # the pin's shadow, then the pin, its tip on the crossing
    for x in range(13, 21):
        px[x, 24] = SHADOW
    for x in range(14, 20):
        px[x, 25] = SHADOW
    ox, oy = 10, 6
    for y, row in enumerate(PIN_ART):
        for x, c in enumerate(row):
            if c in PIN:
                px[ox + x, oy + y] = PIN[c]
    # stepped rounded corners
    cut = [5, 3, 2, 1, 1]
    for y, n in enumerate(cut):
        for x in range(n):
            for cx, cy in [(x, y), (N - 1 - x, y), (x, N - 1 - y), (N - 1 - x, N - 1 - y)]:
                px[cx, cy] = (0, 0, 0, 0)
    return im

def render(size, margin=0.094):
    """The icon on a transparent canvas of `size`, inset like Apple's app icon grid."""
    art = draw()
    body = round(size * (1 - 2 * margin))
    cell = max(1, body // N)
    big = art.resize((cell * N, cell * N), Image.NEAREST)
    if cell * N != body:
        big = big.resize((body, body), Image.LANCZOS if body < N else Image.NEAREST)
    canvas = Image.new("RGBA", (size, size))
    off = (size - big.width) // 2
    canvas.paste(big, (off, off), big)
    return canvas

if __name__ == "__main__":
    render(int(sys.argv[2]) if len(sys.argv) > 2 else 1024).save(sys.argv[1])
