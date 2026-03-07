# CircuitVision Training Data

## Directory Layout

```
training/
├── component_classes.yaml     # Component taxonomy + YOLO class indices
├── annotations/               # YOLO-format annotation files
│   ├── README.md
│   ├── handdrawn/             # Hand-drawn style training data
│   │   ├── images/
│   │   └── labels/            # YOLO .txt label files
│   ├── textbook/
│   │   ├── images/
│   │   └── labels/
│   └── datasheet/
│       ├── images/
│       └── labels/
└── README.md                  # This file
```

## Annotation Format

We use YOLO format for component detection labels. Each `.txt` file in `labels/`
corresponds to an image in `images/` with the same stem name.

Each line: `<class_id> <x_center> <y_center> <width> <height>`

All coordinates are **normalized** to [0, 1] relative to image dimensions.

Example (`circuit_001.txt`):
```
0 0.45 0.30 0.05 0.08
1 0.60 0.55 0.04 0.06
8 0.35 0.45 0.06 0.10
15 0.50 0.90 0.03 0.04
```

Class IDs are defined in `component_classes.yaml`.

## Collecting Training Data

### From Existing Datasets

1. **JUHCCR-v1** (hand-drawn): Clone from
   `github.com/AyushRoy2001/Circuit-Component-Analysis`, convert annotations
   to YOLO format, place in `annotations/handdrawn/`.

2. **Masala-CHAI** (textbook): Clone from
   `github.com/jitendra-bhandari/Masala-CHAI`, extract images and convert
   their annotation format to YOLO, place in `annotations/textbook/`.

3. **Image2Net** (mixed): Use the 4 datasets from arXiv:2508.13157. The device
   identification dataset (2,914 images, 84,195 annotations) provides the bulk
   of cross-style training data.

### Manual Annotation

For new images, use [Label Studio](https://labelstud.io/) or
[CVAT](https://www.cvat.ai/) with the class list from `component_classes.yaml`.
Export in YOLO format.

### Data Augmentation

For hand-drawn data, apply aggressive augmentation:
- Random rotation (±10°)
- Random scale (0.8–1.2×)
- Gaussian noise (σ=5–15)
- Random stroke distortion
- Brightness/contrast jitter
- Random crop with padding

For textbook/datasheet data, apply mild augmentation:
- Random contrast (±10%)
- Random crop with margin
- Resolution scaling (simulating different DPI scans)

## Training

See the top-level README for training instructions. In brief:

```bash
# Base model (all styles)
yolo detect train data=training/all.yaml model=yolov11n.pt epochs=100

# Fine-tune per style
yolo detect train data=training/handdrawn.yaml model=runs/base/weights/best.pt epochs=50
yolo detect train data=training/textbook.yaml model=runs/base/weights/best.pt epochs=50
yolo detect train data=training/datasheet.yaml model=runs/base/weights/best.pt epochs=50
```

## Evaluation

Use the Image2Net NED (Netlist Edit Distance) metric as the primary evaluation
alongside SINA's accuracy percentage. The 104 ground-truth pairs from Image2Net
serve as the test set.

```bash
python -m pytest tests/test_pipeline_integration.py -v
```
