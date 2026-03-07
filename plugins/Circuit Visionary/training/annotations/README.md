# Annotation Files

This directory holds YOLO-format training annotations, organized by style.

## Expected Structure

```
annotations/
├── handdrawn/
│   ├── images/        # .jpg/.png schematic photos
│   └── labels/        # .txt YOLO labels (one per image, same stem name)
├── textbook/
│   ├── images/
│   └── labels/
└── datasheet/
    ├── images/
    └── labels/
```

## Label Format

Each line in a `.txt` label file:
```
<class_id> <x_center> <y_center> <width> <height>
```

Coordinates normalized to [0, 1]. Class IDs from `../component_classes.yaml`.

## How to Populate

1. Download datasets listed in `../component_classes.yaml` → `training_sources`
2. Convert annotations to YOLO format (scripts TBD)
3. Place images and labels in the appropriate style subdirectory

Images and labels are gitignored (too large). Only the directory structure
and metadata are committed.
