# Accuracy evaluation

Measures the face matcher on [LFW](https://vis-www.cs.umass.edu/lfw/) with the same code the app runs
(alignment, SFace, cosine), and the old generic feature print as a baseline.

```bash
mkdir -p ~/.cache/notchfaceid/lfw && cd ~/.cache/notchfaceid/lfw
curl -fsSL -o pairs.txt https://ndownloader.figshare.com/files/5976006
curl -fsSL https://ndownloader.figshare.com/files/5976018 | tar -xz      # lfw/, 173 MB
cd - && ./build.sh
build/NotchFaceID.app/Contents/MacOS/NotchFaceID --eval ~/.cache/notchfaceid/lfw/lfw ~/.cache/notchfaceid/lfw/pairs.txt
```

Takes about 3 minutes. FAR is measured on the 3,000 official impostor pairs plus 300,000 random pairs of different people.

## Results (2026-11-27, M-series Mac, macOS 26.6)

| Matcher | Accuracy | TAR @ FAR 1% | TAR @ FAR 0.1% | TAR @ FAR 0.01% |
| --- | --- | --- | --- | --- |
| Old: feature print of the face box | 0.7715 | 0.2320 | 0.0763 | 0.0213 |
| New: aligned SFace, cosine | **0.9948** | **0.9953** | **0.9890** | **0.9790** |

The app's threshold is the FAR 0.01% point (cosine 0.431, stored as distance 1 − 0.431 = 0.57).

## What this does not show

- LFW is press photos, not this Mac's camera. Same-camera frames usually match more closely, but lighting and angle vary.
- Liveness (photo or screen replay) is not measured here; that needs captures from this camera.
- It is a per-image rate. A scan needs 3 matching live frames, which are from the same moment and so are not independent tries.
