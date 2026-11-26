"""Converts the face models to Core ML and checks them against the originals.

Run from anywhere (see Tools/models/README.md):
    python -I Tools/models/convert.py <download-dir> <out-dir>

<download-dir> holds the files fetched by fetch.sh. It must be outside the repo,
because MiniFASNet.py is imported from it.
"""
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert

src, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(src))
from MiniFASNet import MiniFASNetV1SE, MiniFASNetV2  # noqa: E402  (read before use: plain nn.Module definitions)


def to_coreml(module, size, layout, name, precision):
    """Traces `module`, converts it with an image input, and returns (mlmodel, max abs error on random input)."""
    module.eval()
    example = torch.rand(1, 3, size, size) * 255
    traced = torch.jit.trace(module, example)
    model = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), color_layout=layout, scale=1.0)],
        outputs=[ct.TensorType(name="output")],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )
    model.short_description = name
    # Check on a real image-shaped input: Core ML takes a PIL image, torch takes the same pixels as CHW floats.
    from PIL import Image
    pixels = (np.random.rand(size, size, 3) * 255).astype(np.uint8)
    channels = pixels if layout == ct.colorlayout.RGB else pixels[:, :, ::-1]
    with torch.no_grad():
        want = module(torch.from_numpy(channels.transpose(2, 0, 1).copy()).float()[None]).numpy().ravel()
    got = np.asarray(model.predict({"image": Image.fromarray(pixels)})["output"]).ravel()
    return model, want, got


# SFace (OpenCV Zoo, Apache-2.0): aligned 112x112 RGB face, 0...255, 128-d embedding.
sface = convert(onnx.load(src / "face_recognition_sface_2021dec.onnx"))
model, want, got = to_coreml(sface, 112, ct.colorlayout.RGB, "SFace face embedding (OpenCV Zoo, Apache-2.0)", ct.precision.FLOAT16)
cos = float(np.dot(want, got) / np.linalg.norm(want) / np.linalg.norm(got))
print(f"SFace: {got.size}-d, cosine(torch, coreml fp16) = {cos:.5f}")
assert got.size == 128 and cos > 0.999, "SFace conversion drifted"
model.save(out / "SFace.mlpackage")


# MiniFASNet (Minivision Silent-Face-Anti-Spoofing, Apache-2.0): 80x80 BGR crop, 0...255, logits for 3 classes (1 = real).
def minifasnet(factory, file):
    net = factory(conv6_kernel=(5, 5))  # get_kernel(80, 80) in the original code
    state = torch.load(src / file, map_location="cpu", weights_only=True)
    net.load_state_dict({k.removeprefix("module."): v for k, v in state.items()})
    return net


for factory, file, name in [(MiniFASNetV2, "2.7_80x80_MiniFASNetV2.pth", "MiniFASNetV2"),
                            (MiniFASNetV1SE, "4_0_0_80x80_MiniFASNetV1SE.pth", "MiniFASNetV1SE")]:
    model, want, got = to_coreml(minifasnet(factory, file), 80, ct.colorlayout.BGR, f"{name} anti-spoofing (Minivision, Apache-2.0)", ct.precision.FLOAT32)
    soft = lambda x: np.exp(x - x.max()) / np.exp(x - x.max()).sum()
    err = float(np.abs(soft(want) - soft(got)).max())
    print(f"{name}: max softmax error = {err:.5f}")
    assert got.size == 3 and err < 0.01, f"{name} conversion drifted"
    model.save(out / f"{name}.mlpackage")
