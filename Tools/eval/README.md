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

## Tuning on this Mac (`frames.csv`)

The LFW numbers above are press photos. To tune for this camera, turn on the menu's
`판정 기록 (CSV)`, then scan a few times with your own face (`me`), a phone photo
(`photo`), and a phone video (`video`). Each scan is one `run`. The app does not show the
run number, but it counts up by one per scan, so label them in the order you scanned or
read the `run` column from the CSV.

```bash
python3 Tools/eval/frames.py 1-3=me 4-6=photo 7-9=video
python3 Tools/eval/frames.py /path/to/frames.csv 1-3=me 4-6=photo
```

The script prints per-label distance / centroid / live percentiles, the
`distance <= t and live >= l` rule that keeps `me` at or under 5% FRR while accepting the
fewest photo/video frames, a min-template vs centroid comparison, and frame interval plus
eye-openness jitter. It reads numbers only; images and embeddings are never written.

Caveats: the FRR is per frame, but a scan needs three good frames in a row, so the scan-level
FRR is higher. A small number of runs gives a rough guide, not a calibrated rate. `live` is
the average of MiniFASNetV2 and V1SE; the CSV keeps both columns (`v2Live`, `v1seLive`) so
they can be compared separately.

## What this does not show

- LFW is press photos, not this Mac's camera. Same-camera frames usually match more closely, but lighting and angle vary.
- Liveness (photo or screen replay) is not measured here; that needs captures from this camera.
- It is a per-image rate. A scan needs 3 matching live frames, which are from the same moment and so are not independent tries.
