#!/usr/bin/env python3
"""GLB → 스프라이트 PNG 오프라인 렌더러.

카메라가 고정된 2.5D 화면이라, 3D 모델을 런타임에 돌릴 이유가 없다. 필요한
각도로 한 번 구워 PNG 로 두면 Flame 이 스프라이트로 그대로 쓴다. 95만 삼각형은
여기서만 쓰이고 앱에는 안 들어간다.

Blender 없이 numpy Z버퍼 래스터라이저로 처리한다:
  퍼스펙티브 투영 → 백페이스 컬링 → 타일 단위 Z버퍼 → UV 보간 텍스처 샘플링
  → Lambert 음영 → 알파 트림 → PNG

usage:
  python3 glb_render.py <in.glb> <out.png> [--size 512] [--yaw 20] [--pitch 12]
                        [--bend 0.0] [--hinge 0.0] [--tint R,G,B]
"""
import argparse, json, math, struct, sys
import numpy as np
from PIL import Image

# ── GLB 파싱 ──────────────────────────────────────────────────────────
COMP = {5120: 'i1', 5121: 'u1', 5122: 'i2', 5123: 'u2', 5125: 'u4', 5126: 'f4'}
NCOMP = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def load_glb(path):
    d = open(path, 'rb').read()
    _, _, total = struct.unpack('<III', d[:12])
    off, js, bins = 12, None, b''
    while off < total:
        ln, ty = struct.unpack('<II', d[off:off + 8])
        chunk = d[off + 8: off + 8 + ln]
        if ty == 0x4E4F534A:
            js = json.loads(chunk)
        elif ty == 0x004E4942:
            bins = chunk
        off += 8 + ln + ((4 - ln % 4) % 4 if ln % 4 else 0)
    return js, bins


def accessor(js, bins, idx):
    a = js['accessors'][idx]
    bv = js['bufferViews'][a['bufferView']]
    base = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    n = NCOMP[a['type']]
    dt = np.dtype('<' + COMP[a['componentType']])
    stride = bv.get('byteStride')
    if stride and stride != n * dt.itemsize:
        raw = np.frombuffer(bins, dtype=np.uint8,
                            count=stride * a['count'], offset=base)
        raw = raw.reshape(a['count'], stride)[:, :n * dt.itemsize]
        return np.ascontiguousarray(raw).view(dt).reshape(a['count'], n)
    arr = np.frombuffer(bins, dtype=dt, count=a['count'] * n, offset=base)
    return arr.reshape(a['count'], n)


def node_matrix(node):
    if 'matrix' in node:
        return np.array(node['matrix'], dtype=np.float64).reshape(4, 4).T
    m = np.eye(4)
    if 'scale' in node:
        m = np.diag(list(node['scale']) + [1.0]) @ m
    if 'rotation' in node:
        x, y, z, w = node['rotation']
        r = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0],
            [0, 0, 0, 1]])
        m = r @ m
    if 'translation' in node:
        t = np.eye(4); t[:3, 3] = node['translation']
        m = t @ m
    return m


def gather(js, bins):
    """씬의 모든 메시를 월드 좌표로 모은다."""
    P, N, UV, F = [], [], [], []
    base = 0
    scene = js['scenes'][js.get('scene', 0)]

    def walk(ni, parent):
        nonlocal base
        node = js['nodes'][ni]
        world = parent @ node_matrix(node)
        if 'mesh' in node:
            for prim in js['meshes'][node['mesh']]['primitives']:
                at = prim['attributes']
                p = accessor(js, bins, at['POSITION']).astype(np.float64)
                p = (world @ np.c_[p, np.ones(len(p))].T).T[:, :3]
                P.append(p)
                if 'NORMAL' in at:
                    nn = accessor(js, bins, at['NORMAL']).astype(np.float64)
                    nn = (world[:3, :3] @ nn.T).T
                else:
                    nn = np.zeros_like(p)
                N.append(nn)
                UV.append(accessor(js, bins, at['TEXCOORD_0']).astype(np.float64)
                          if 'TEXCOORD_0' in at else np.zeros((len(p), 2)))
                idx = accessor(js, bins, prim['indices']).ravel().astype(np.int64)
                F.append(idx.reshape(-1, 3) + base)
                base += len(p)
        for c in node.get('children', []):
            walk(c, world)

    for ni in scene['nodes']:
        walk(ni, np.eye(4))
    return (np.vstack(P), np.vstack(N), np.vstack(UV), np.vstack(F))


def load_texture(js, bins):
    if not js.get('images'):
        return None
    img = js['images'][0]
    bv = js['bufferViews'][img['bufferView']]
    o = bv.get('byteOffset', 0)
    import io
    im = Image.open(io.BytesIO(bins[o:o + bv['byteLength']])).convert('RGB')
    return np.asarray(im, dtype=np.float32) / 255.0


# ── 포즈 변형 ─────────────────────────────────────────────────────────
def close_clamshell(V, amount):
    """글러브를 조개처럼 닫는다. **뷰 공간**에서 접는다.

    모델 공간에서 접으면 모델마다 축 방향이 달라 화면상 엉뚱하게 뭉개진다
    (실제로 그렇게 나왔다). 카메라를 이미 적용한 뒤에 접으면 "화면에서 좌우가
    모인다" 가 그대로 성립한다.

    엄지쪽(x<0)과 손가락쪽(x>0)이 주머니 접힘선(x=0)을 축으로 서로를 향해
    돈다. 접힘선에서 멀수록 많이 도므로 가운데는 제자리에 남는다.
    """
    if amount == 0:
        return V
    out = V.copy()
    xr = np.abs(V[:, 0]).max()
    if xr < 1e-9:
        return out
    w = np.clip(np.abs(V[:, 0]) / xr, 0, 1) ** 1.1
    ang = amount * w * np.sign(V[:, 0])       # 좌우가 서로를 향해
    cos, sin = np.cos(ang), np.sin(ang)
    x, z = V[:, 0], V[:, 2]
    out[:, 0] = x * cos + z * sin
    out[:, 2] = -x * sin + z * cos
    return out


# ── 렌더 ──────────────────────────────────────────────────────────────
def render(P, N, UV, F, tex, size, yaw, pitch, tint, close=0.0, margin=0.06):
    # 모델을 원점에 정규화
    c = (P.max(0) + P.min(0)) / 2
    P = P - c
    P /= np.abs(P).max()

    cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    R = Rx @ Ry
    V = P @ R.T
    V = close_clamshell(V, close)
    Nn = N @ R.T
    nrm = np.linalg.norm(Nn, axis=1, keepdims=True)
    Nn = Nn / np.where(nrm == 0, 1, nrm)

    dist = 3.2
    Vz = V[:, 2] + dist
    f = size * (1 - margin * 2) * 0.5 * dist / 1.15
    sx = V[:, 0] * f / Vz + size / 2
    sy_ = -V[:, 1] * f / Vz + size / 2

    tri = F
    a, b, cc = tri[:, 0], tri[:, 1], tri[:, 2]
    x0, y0, x1, y1, x2, y2 = sx[a], sy_[a], sx[b], sy_[b], sx[cc], sy_[cc]
    area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    keep = area < -1e-9                       # 백페이스 컬링 (CCW 앞면)
    tri, area = tri[keep], area[keep]
    a, b, cc = tri[:, 0], tri[:, 1], tri[:, 2]
    x0, y0, x1, y1, x2, y2 = sx[a], sy_[a], sx[b], sy_[b], sx[cc], sy_[cc]
    z = (Vz[a] + Vz[b] + Vz[cc]) / 3

    # 광원: 카메라 왼쪽 위
    L = np.array([-0.45, 0.75, 0.55]); L /= np.linalg.norm(L)
    lam = np.clip(Nn @ L, 0, 1)
    shade = 0.32 + 0.68 * lam                 # 앰비언트 + 램버트

    if tex is not None:
        th, tw = tex.shape[:2]
        u = np.clip(UV[:, 0], 0, 1) * (tw - 1)
        v = np.clip(UV[:, 1], 0, 1) * (th - 1)
        col = tex[v.astype(np.int32), u.astype(np.int32)]
    else:
        col = np.ones((len(P), 3), dtype=np.float32)
    col = col * np.asarray(tint, dtype=np.float32)
    vcol = col * shade[:, None]

    buf = np.zeros((size, size, 3), dtype=np.float32)
    zbuf = np.full((size, size), np.inf, dtype=np.float32)
    alpha = np.zeros((size, size), dtype=bool)

    # 먼 것부터 그린다(페인터) + Z버퍼로 관통 방지.
    order = np.argsort(-z)
    step = 40000
    for s in range(0, len(order), step):
        chunk = order[s:s + step]
        _raster(chunk, tri, x0, y0, x1, y1, x2, y2, area, z,
                vcol, buf, zbuf, alpha, size)
    return buf, alpha


def _raster(sel, tri, x0, y0, x1, y1, x2, y2, area, z, vcol,
            buf, zbuf, alpha, size):
    for i in sel:
        ax, ay, bx, by, cx_, cy_ = x0[i], y0[i], x1[i], y1[i], x2[i], y2[i]
        lo_x = max(int(min(ax, bx, cx_)), 0)
        hi_x = min(int(max(ax, bx, cx_)) + 1, size - 1)
        lo_y = max(int(min(ay, by, cy_)), 0)
        hi_y = min(int(max(ay, by, cy_)) + 1, size - 1)
        if lo_x > hi_x or lo_y > hi_y:
            continue
        zi = z[i]
        ys, xs = np.mgrid[lo_y:hi_y + 1, lo_x:hi_x + 1]
        px, py = xs + 0.5, ys + 0.5
        ar = area[i]
        w0 = ((bx - ax) * (py - ay) - (by - ay) * (px - ax)) / ar
        w1 = ((cx_ - bx) * (py - by) - (cy_ - by) * (px - bx)) / ar
        w2 = 1.0 - w0 - w1
        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not inside.any():
            continue
        closer = inside & (zi < zbuf[lo_y:hi_y + 1, lo_x:hi_x + 1])
        if not closer.any():
            continue
        ia, ib, ic = tri[i]
        # 무게중심 보간(퍼스펙티브 보정 없음 — 삼각형이 픽셀 단위라 무시 가능)
        c = (w1[..., None] * vcol[ia] + w2[..., None] * vcol[ib]
             + w0[..., None] * vcol[ic])
        sub = buf[lo_y:hi_y + 1, lo_x:hi_x + 1]
        sub[closer] = c[closer]
        zb = zbuf[lo_y:hi_y + 1, lo_x:hi_x + 1]
        zb[closer] = zi
        al = alpha[lo_y:hi_y + 1, lo_x:hi_x + 1]
        al[closer] = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src'); ap.add_argument('dst')
    ap.add_argument('--size', type=int, default=512)
    ap.add_argument('--yaw', type=float, default=20)
    ap.add_argument('--pitch', type=float, default=12)
    ap.add_argument('--close', type=float, default=0.0,
                    help='글러브 닫기(라디안, 뷰 공간 조개접기)')
    ap.add_argument('--tint', default='1,1,1')
    ap.add_argument('--max-tri', type=int, default=0,
                    help='0 이면 전량 렌더. 솎으면 구멍이 뚫린다')
    ap.add_argument('--exposure', type=float, default=0.0,
                    help='0 이면 자동 — 밝은 쪽 95%%가 목표 밝기에 오도록 맞춘다')
    ap.add_argument('--target', type=float, default=0.82)
    ap.add_argument('--no-trim', action='store_true',
                    help='알파 크롭을 끈다. 같은 대상의 여러 포즈를 구울 때 필수 — '
                         '크롭하면 포즈마다 크기가 달라져 전환 시 튄다')
    a = ap.parse_args()

    js, bins = load_glb(a.src)
    P, N, UV, F = gather(js, bins)
    tex = load_texture(js, bins)
    print(f'  삼각형 {len(F):,}  텍스처 {"O" if tex is not None else "X"}')

    if a.max_tri and len(F) > a.max_tri:
        # 인덱스 균등 솎기는 면을 흩뿌려 구멍을 만든다. 미리보기 전용.
        keep = np.linspace(0, len(F) - 1, a.max_tri).astype(np.int64)
        F = F[keep]
        print(f'  → {len(F):,} 로 솎음 (미리보기)')

    tint = tuple(float(x) for x in a.tint.split(','))
    buf, alpha = render(P, N, UV, F, tex, a.size, a.yaw, a.pitch, tint,
                        close=a.close)

    # 자동 노출 — 이 모델들의 텍스처가 어둡다(평균 0.13). 그대로 쓰면 화면에서
    # 검게 뭉개진다. 밝은 쪽 95%가 목표에 오도록 게인을 잡는다.
    if alpha.any():
        lum = buf[alpha].max(axis=1)
        p95 = float(np.percentile(lum, 95))
        gain = a.exposure if a.exposure > 0 else (
            a.target / p95 if p95 > 1e-4 else 1.0)
        buf = buf * gain
        print(f'  노출 게인 {gain:.2f} (p95 {p95:.3f} → {min(p95*gain,1):.2f})')

    rgba = np.zeros((a.size, a.size, 4), dtype=np.uint8)
    rgba[..., :3] = np.clip(buf * 255, 0, 255).astype(np.uint8)
    rgba[..., 3] = alpha.astype(np.uint8) * 255
    im = Image.fromarray(rgba, 'RGBA')
    if not a.no_trim:
        bbox = im.getbbox()
        if bbox:
            im = im.crop(bbox)
    im.save(a.dst)
    print(f'  → {a.dst}  {im.size[0]}x{im.size[1]}  '
          f'채움 {alpha.mean()*100:.1f}%')


if __name__ == '__main__':
    main()
