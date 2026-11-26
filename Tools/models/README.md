# Face models

`Resources/Models/*.mlmodelc` are built from these originals. Rebuild them only to change a model.

| Model | Job | Source | License |
| --- | --- | --- | --- |
| `SFace` | 128-d face identity embedding, aligned 112×112 RGB | [OpenCV Zoo](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) `face_recognition_sface_2021dec.onnx` | Apache-2.0 |
| `MiniFASNetV2`, `MiniFASNetV1SE` | real face vs photo/screen, 80×80 BGR | [Silent-Face-Anti-Spoofing](https://github.com/minivision-ai/Silent-Face-Anti-Spoofing) | Apache-2.0 |

## Rebuild

```bash
python3 -m venv ~/.cache/notchfaceid/venv
~/.cache/notchfaceid/venv/bin/pip install "coremltools>=8" torch onnx onnx2torch numpy pillow
Tools/models/fetch.sh ~/.cache/notchfaceid/download        # checks SHA-256
~/.cache/notchfaceid/venv/bin/python -I Tools/models/convert.py ~/.cache/notchfaceid/download ~/.cache/notchfaceid/out
for m in SFace MiniFASNetV2 MiniFASNetV1SE; do
  xcrun coremlcompiler compile ~/.cache/notchfaceid/out/$m.mlpackage Resources/Models
done
```

`coremlcompiler` needs Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
`convert.py` fails if a converted model drifts from the original on a random input.
