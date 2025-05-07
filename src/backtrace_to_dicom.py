import os
import csv
import numpy as np
import pydicom
from pydicom import dcmread
from PIL import Image

try:
    import nibabel as nib  # for NIfTI loading if needed
except ImportError:
    nib = None

def load_affines(matrix_paths):
    affines = []
    for path in matrix_paths:
        A = np.loadtxt(path)
        if A.shape == (3, 4):
            A = np.vstack([A, [0, 0, 0, 1]])
        affines.append(np.linalg.inv(A))  # invert here for reverse mapping
    return affines

def transform_coord(coord, affine_chain):
    coord = np.array(list(coord) + [1.0])
    for A in reversed(affine_chain):
        coord = A @ coord
    return coord[:3]

def find_matching_slice(ds, target_coord, tolerance=1.5):
    ipp = np.array(ds.ImagePositionPatient, dtype=float)
    iop = np.array(ds.ImageOrientationPatient, dtype=float)
    row, col = iop[:3], iop[3:]
    normal = np.cross(row, col)
    diff = target_coord - ipp
    dist = abs(np.dot(diff, normal))
    return dist <= tolerance

def pixel_coords(ds, target_coord):
    ipp = np.array(ds.ImagePositionPatient, dtype=float)
    iop = np.array(ds.ImageOrientationPatient, dtype=float)
    row, col = iop[:3], iop[3:]
    spacing = [float(s) for s in ds.PixelSpacing]
    vec = target_coord - ipp
    col_px = int(np.dot(vec, row) / spacing[1])
    row_px = int(np.dot(vec, col) / spacing[0])
    return row_px, col_px

def draw_crosshair(img, row, col, color=(255, 0, 0)):
    draw = ImageDraw.Draw(img)
    draw.line([(0, row), (img.width - 1, row)], fill=color)
    draw.line([(col, 0), (col, img.height - 1)], fill=color)

def process_clusters(clusters, affines, dicom_dir, output_dir):
    os.makedirs(output_dir, exist_ok=True)
    output_json = []

    dcm_paths = [
        os.path.join(dp, f) for dp, _, files in os.walk(dicom_dir)
        for f in files if f.lower().endswith('.dcm')
    ]

    for cid, x, y, z in clusters:
        native = transform_coord((x, y, z), affines)

        for dcm_file in sorted(dcm_paths):
            try:
                ds = dcmread(dcm_file)
                if find_matching_slice(ds, native):
                    row, col = pixel_coords(ds, native)
                    pix = ds.pixel_array.astype(np.float32)
                    pmin, pmax = pix.min(), pix.max()
                    norm = ((pix - pmin) / (pmax - pmin) * 255).clip(0, 255).astype(np.uint8)
                    img = Image.fromarray(norm).convert("RGB")
                    draw_crosshair(img, row, col)
                    outname = f"{cid}_{os.path.basename(dcm_file)}.png"
                    outpath = os.path.join(output_dir, outname)
                    img.save(outpath)

                    output_json.append({
                        "cluster_id": cid,
                        "orig_coord_mm": [x, y, z],
                        "native_coord_mm": native.tolist(),
                        "dicom_file": dcm_file,
                        "png": outpath,
                        "pixel_xy": [int(col), int(row)]
                    })
                    break
            except Exception as e:
                continue

    with open(os.path.join(output_dir, "cluster_dicom_trace.json"), "w") as jf:
        json.dump(output_json, jf, indent=2)

def transform_to_scanner(coord, source_affine=None, transform_affine=None):
    """
    Transform a coordinate from source image space to scanner (patient) space.
    coord: tuple or list of (x, y, z) coordinates in source space (voxel indices if source_affine given, or mm).
    source_affine: 4x4 affine matrix from source image (e.g. NIfTI) voxels to patient/world coords.
    transform_affine: additional 4x4 affine matrix to apply after source_affine (e.g. from registration).
    Returns: numpy array of (X, Y, Z) in scanner space (mm).
    """
    coord_h = np.array(list(coord) + [1.0])  # homogeneous coordinate (x,y,z,1)
    if source_affine is not None:
        coord_h = source_affine.dot(coord_h)  # apply source image affine
    if transform_affine is not None:
        coord_h = transform_affine.dot(coord_h)  # apply additional transform
    return coord_h[:3]  # return (x,y,z)

def load_dicom_series_info(dicom_dir):
    """
    Load all DICOM files in a directory (recursively), group by series, and collect orientation/position info.
    Returns a list of series dictionaries with keys:
      SeriesInstanceUID, SeriesDescription, Modality, orientation, pixel_spacing, slice_thickness, image_shape, slices.
    """
    series_map = {}
    for root, _, files in os.walk(dicom_dir):
        for fname in files:
            fpath = os.path.join(root, fname)
            # Attempt to read DICOM header (skip pixel data for speed)
            try:
                ds = dcmread(fpath, stop_before_pixels=True)
            except Exception:
                continue  # skip files that are not DICOM
            uid = getattr(ds, "SeriesInstanceUID", None)
            if uid is None:
                continue
            # Initialize series entry if new
            if uid not in series_map:
                series_map[uid] = {
                    "SeriesInstanceUID": uid,
                    "SeriesDescription": getattr(ds, "SeriesDescription", "Unknown"),
                    "Modality": getattr(ds, "Modality", ""),
                    "orientation": None,
                    "pixel_spacing": None,
                    "slice_thickness": None,
                    "image_shape": None,
                    "slices": []
                }
            series = series_map[uid]
            # Set orientation (row and column direction unit vectors)
            if series["orientation"] is None:
                iop = np.array(getattr(ds, "ImageOrientationPatient", [1,0,0, 0,1,0]), dtype=float)
                row_dir = iop[0:3]
                col_dir = iop[3:6]
                series["orientation"] = (row_dir, col_dir)
            # Set pixel spacing and image shape
            if series["pixel_spacing"] is None:
                spacing = getattr(ds, "PixelSpacing", None)
                if spacing is not None:
                    # PixelSpacing is [row_spacing, col_spacing]
                    series["pixel_spacing"] = (float(spacing[0]), float(spacing[1]))
            if series["image_shape"] is None:
                rows = getattr(ds, "Rows", None)
                cols = getattr(ds, "Columns", None)
                if rows is not None and cols is not None:
                    series["image_shape"] = (int(rows), int(cols))
            # Set slice thickness if available (note: may be omitted or not exact for spacing)
            if series["slice_thickness"] is None:
                st = getattr(ds, "SliceThickness", None)
                if st is not None:
                    try:
                        series["slice_thickness"] = float(st)
                    except:
                        series["slice_thickness"] = None
            # Add slice info (position and instance number)
            pos = np.array(getattr(ds, "ImagePositionPatient", [0,0,0]), dtype=float)
            inst_num = getattr(ds, "InstanceNumber", None)
            inst_num = int(inst_num) if inst_num is not None else None
            series["slices"].append({
                "filepath": fpath,
                "position": pos,
                "instance_number": inst_num
            })
    # Convert map to list and sort slices within each series
    series_list = []
    for uid, series in series_map.items():
        slices = series["slices"]
        if not slices:
            continue
        # Sort slices by acquisition order: use InstanceNumber if available, otherwise use position along normal
        if all(s["instance_number"] is not None for s in slices):
            slices.sort(key=lambda s: s["instance_number"])
        else:
            row_dir, col_dir = series["orientation"]
            normal = np.cross(row_dir, col_dir)
            # Ensure normal points consistently from first to last slice
            if len(slices) >= 2:
                if np.dot(normal, slices[-1]["position"] - slices[0]["position"]) < 0:
                    normal = -normal
            slices.sort(key=lambda s: np.dot(normal, s["position"]))
        # Compute slice spacing if not provided, using first two slices
        if series["slice_thickness"] is None and len(slices) > 1:
            row_dir, col_dir = series["orientation"]
            normal = np.cross(row_dir, col_dir)
            d = np.dot(normal, slices[1]["position"] - slices[0]["position"])
            series["slice_thickness"] = abs(d)
        series["slices"] = slices
        series_list.append(series)
    return series_list

def filter_series(series_list, description_keywords):
    """
    Filter series_list to only include series whose SeriesDescription contains any of the given keywords.
    description_keywords: dict mapping modality label -> list of substrings.
    Adds 'ModalityLabel' to each series dict that matches.
    """
    filtered = []
    for series in series_list:
        desc_lower = series["SeriesDescription"].lower()
        for label, keywords in description_keywords.items():
            if any(kw.lower() in desc_lower for kw in keywords):
                series_copy = series.copy()
                series_copy["ModalityLabel"] = label
                filtered.append(series_copy)
                break
    return filtered

def find_slice_for_coord(series, coord):
    """
    Find the slice in the series that contains (or is nearest to) the given 3D coordinate.
    series: a dict with orientation and sorted 'slices'.
    coord: numpy array (3,) of [X, Y, Z] in patient space.
    Returns: (slice_info, index) of the best matching slice, or (None, None) if not found.
    """
    slices = series.get("slices", [])
    if len(slices) == 0:
        return None, None
    # Get orientation vectors and normal
    row_dir, col_dir = series["orientation"]
    normal = np.cross(row_dir, col_dir)
    # Align normal to series order (from first to last)
    if np.dot(normal, slices[-1]["position"] - slices[0]["position"]) < 0:
        normal = -normal
    # Project the coordinate onto the normal axis
    first_pos = slices[0]["position"]
    t = np.dot(normal, coord - first_pos)
    spacing = np.abs(np.dot(normal, slices[1]["position"] - first_pos)) if len(slices) > 1 else 1e-6
    # Nearest slice index
    index = int(round(t / spacing))
    index = max(0, min(index, len(slices) - 1))
    slice_info = slices[index]
    # Verify the point is within the slice boundaries in-plane
    pos = slice_info["position"]
    rel = coord - pos  # vector from top-left corner to the point
    x_offset = np.dot(rel, row_dir)  # distance along row direction
    y_offset = np.dot(rel, col_dir)  # distance along column direction
    px_spacing = series.get("pixel_spacing", (None, None))
    img_shape = series.get("image_shape", (None, None))
    if px_spacing[0] and px_spacing[1] and img_shape[0] and img_shape[1]:
        width_mm = px_spacing[1] * (img_shape[1] - 1)  # total width in mm
        height_mm = px_spacing[0] * (img_shape[0] - 1) # total height in mm
        if x_offset < 0 or x_offset > width_mm or y_offset < 0 or y_offset > height_mm:
            return None, None  # point lies outside the slice area
    # (Optional: check distance to plane if needed)
    return slice_info, index

def save_slice_as_png(dicom_path, output_path):
    """
    Read a DICOM file and save its image as a PNG.
    """
    ds = dcmread(dicom_path)
    # Get image data as float32 for processing
    pixel_array = ds.pixel_array.astype(np.float32)
    # Apply rescale if present (e.g., for CT; for MR typically slope=1)
    slope = float(getattr(ds, "RescaleSlope", 1))
    intercept = float(getattr(ds, "RescaleIntercept", 0))
    pixel_array = pixel_array * slope + intercept
    # Normalize intensity to 0-255
    pixel_array -= pixel_array.min()
    if pixel_array.max() > 0:
        pixel_array = (pixel_array / pixel_array.max()) * 255.0
    img = Image.fromarray(pixel_array.astype(np.uint8))
    img.save(output_path)

def process_clusters(dicom_dir, clusters, output_dir, source_nifti=None, transform_matrix=None, output_manifest="manifest.csv"):
    """
    Main processing function to map cluster coordinates to DICOM slices and save outputs.
    - dicom_dir: path to DICOM files directory (scans of one subject).
    - clusters: list of (cluster_id, x, y, z) coordinates (source space).
    - output_dir: folder to save PNG images and manifest.
    - source_nifti: path to NIfTI file defining source space (for affine).
    - transform_matrix: path to a 4x4 affine matrix file for additional transform.
    - output_manifest: filename for output manifest ('.csv' or '.json').
    """
    os.makedirs(output_dir, exist_ok=True)
    # Prepare transforms
    src_affine = None
    if source_nifti:
        if nib is None:
            raise ImportError("Nibabel is required for using source_nifti.")
        src_affine = nib.load(source_nifti).affine  # affine matrix from NIfTI
    xform_affine = None
    if transform_matrix:
        xform_affine = np.loadtxt(transform_matrix)
        if xform_affine.shape != (4,4):
            raise ValueError("Transform matrix must be 4x4.")
    # Load and filter series
    series_list = load_dicom_series_info(dicom_dir)
    filters = {
        "T1": ["mprage"],        # T1-weighted MPRAGE
        "FLAIR": ["flair", "space"],  # T2-FLAIR (SPACE sequence often contains 'SPACE' or 'FLAIR')
        "DWI": ["dwi"]           # Diffusion-weighted 
    }
    target_series = filter_series(series_list, filters)
    # Process each cluster
    manifest = []
    for cluster_id, x, y, z in clusters:
        orig_coord = (x, y, z)
        # Transform to scanner coordinates
        coord = np.array([x, y, z], dtype=float)
        if src_affine is not None or xform_affine is not None:
            scanner_coord = transform_to_scanner(coord, source_affine=src_affine, transform_affine=xform_affine)
        else:
            scanner_coord = coord  # already in scanner space
        # Find and save slice in each target modality
        for series in target_series:
            label = series.get("ModalityLabel", series.get("Modality", ""))
            slice_info, idx = find_slice_for_coord(series, scanner_coord)
            if slice_info is None:
                continue  # no slice found (point outside FOV or series not covering that area)
            dicom_path = slice_info["filepath"]
            # Create output filename
            modality_label = label if label else "Series"
            png_filename = f"cluster{cluster_id}_{modality_label}.png"
            png_path = os.path.join(output_dir, png_filename)
            # Convert and save the DICOM slice as PNG
            save_slice_as_png(dicom_path, png_path)
            # Determine slice index (use InstanceNumber if available)
            slice_index = slice_info["instance_number"] if slice_info["instance_number"] is not None else idx
            manifest.append({
                "cluster_id": cluster_id,
                "modality": modality_label,
                "dicom_path": os.path.abspath(dicom_path),
                "slice_index": slice_index,
                "png_path": os.path.abspath(png_path),
                "orig_x": orig_coord[0],
                "orig_y": orig_coord[1],
                "orig_z": orig_coord[2]
            })
    # Save manifest to CSV or JSON
    manifest_path = os.path.join(output_dir, output_manifest)
    if output_manifest.lower().endswith(".json"):
        import json
        with open(manifest_path, 'w') as jf:
            json.dump(manifest, jf, indent=2)
    else:
        # CSV output
        fieldnames = ["cluster_id", "modality", "dicom_path", "slice_index", "png_path", "orig_x", "orig_y", "orig_z"]
        with open(manifest_path, 'w', newline='') as cf:
            writer = csv.DictWriter(cf, fieldnames=fieldnames)
            writer.writeheader()
            for entry in manifest:
                writer.writerow(entry)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Map cluster coordinates to DICOM slices")
    ap.add_argument("--dicom_dir", required=True, help="Path to DICOM directory")
    ap.add_argument("--clusters_csv", required=True, help="Path to CSV file with cluster_id,x,y,z")
    ap.add_argument("--source_nifti", help="NIfTI file for source space (if coordinates need transform)")
    ap.add_argument("--affine_matrix", help="Affine matrix file for additional transform")
    ap.add_argument("--output_dir", required=True, help="Directory to save output images and manifest")
    ap.add_argument("--output_manifest", default="manifest.csv", help="Output manifest filename (csv or json)")
    args = ap.parse_args()
    # Load clusters from CSV
    clusters = []
    import csv
    with open(args.clusters_csv) as cf:
        reader = csv.reader(cf)
        # Assuming header: cluster_id,x,y,z
        headers = next(reader, None)
        for row in reader:
            if not row: 
                continue
            cid = row[0]
            x, y, z = map(float, row[1:4])
            clusters.append((cid, x, y, z))
    process_clusters(args.dicom_dir, clusters, args.output_dir, 
                     source_nifti=args.source_nifti, transform_matrix=args.affine_matrix,
                     output_manifest=args.output_manifest)
