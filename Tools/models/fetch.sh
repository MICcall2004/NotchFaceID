#!/bin/bash
# Downloads the original face models into <dir> (outside the repo) and checks them against known hashes.
set -euo pipefail
dir=${1:?usage: fetch.sh <download-dir>}
mkdir -p "$dir" && cd "$dir"
zoo=https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface
fas=https://raw.githubusercontent.com/minivision-ai/Silent-Face-Anti-Spoofing/master
curl -fsSL -o face_recognition_sface_2021dec.onnx "$zoo/face_recognition_sface_2021dec.onnx"
curl -fsSL -o 2.7_80x80_MiniFASNetV2.pth "$fas/resources/anti_spoof_models/2.7_80x80_MiniFASNetV2.pth"
curl -fsSL -o 4_0_0_80x80_MiniFASNetV1SE.pth "$fas/resources/anti_spoof_models/4_0_0_80x80_MiniFASNetV1SE.pth"
curl -fsSL -o MiniFASNet.py "$fas/src/model_lib/MiniFASNet.py"
shasum -a 256 -c <<'SUMS'
0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79  face_recognition_sface_2021dec.onnx
a5eb02e1843f19b5386b953cc4c9f011c3f985d0ee2bb9819eea9a142099bec0  2.7_80x80_MiniFASNetV2.pth
84ee1d37d96894d5e82de5a57df044ef80a58be2b218b5ed7cdfd875ec2f5990  4_0_0_80x80_MiniFASNetV1SE.pth
e498c4ec5e1ddfaba62b941a126c19d65aa564999f3309661fe43ee8bf38acd7  MiniFASNet.py
SUMS
