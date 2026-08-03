# 게임 에셋

Flame 은 2D 엔진이라 GLB 를 직접 못 읽는다. 대신 **3D 모델을 오프라인에서 한 번
렌더해 PNG 로 굽는다** — 카메라가 고정된 2.5D 화면이라 각도 하나면 충분하고,
95만 삼각형은 여기서만 쓰이고 앱에는 안 들어간다.

| 파일 | 출처 | 쓰는 곳 |
|---|---|---|
| `background.png` 852×1846 | 직접 제작 | `Stadium` — 비율 1:2.17 로 세로 폰(1:2.16)에 맞음 |
| `glove_open.png` 512×512 | GLB 렌더 | `Glove` 펴짐 |
| `glove_closed.png` 512×512 | GLB 렌더 | `Glove` 쥠 (조개접기 0.62rad) |
| `ball.png` 206×209 | GLB 렌더 | `Ball` |

**에셋이 없어도 게임은 돌아간다.** 각 컴포넌트가 같은 구도로 코드 드로잉 폴백을
갖고 있다. 파일을 넣으면 자동으로 교체된다.

## 다시 굽기

`tools/glb_render.py` (numpy + Pillow, Blender 불필요):

```bash
R=tools/glb_render.py            # emgfes-data 의 .venv 파이썬으로 실행
G="~/Desktop/baseball glove 3d model.glb.glb"
python3 $R "$G" assets/game/glove_open.png   --size 512 --yaw -90 --pitch 10 --close 0    --no-trim
python3 $R "$G" assets/game/glove_closed.png --size 512 --yaw -90 --pitch 10 --close 0.62 --no-trim
python3 $R "~/Desktop/baseball 3d model.glb" assets/game/ball.png --size 256 --yaw 15 --pitch 8
```

- `--no-trim` 은 글러브 두 포즈에 **필수**다. 크롭하면 포즈마다 크기가 달라져
  전환할 때 튄다.
- 노출은 자동이다. 이 모델들의 텍스처가 어둡다(평균 0.13) — 그대로 쓰면 화면에서
  검게 뭉개진다.

## 아직 없는 것

- **투수 스프라이트**: `pitcherAnimation` 필드는 있으나 로더가 없다. 지금은 항상
  코드 드로잉이다.
- **야수·관중**: 배경 그림에 들어 있고 별도 스프라이트는 없다.
