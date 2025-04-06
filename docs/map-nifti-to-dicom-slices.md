Python Module for Mapping Cluster Coordinates to DICOM Slices

Overview:
We develop a Python module that takes cluster center-of-gravity (COG) coordinates identified in a certain image space (e.g. brainstem ROI space or FLAIR MRI space) and finds the corresponding DICOM image slices across different MRI series (T1, FLAIR, DWI). The module will:
	•	Transform Coordinates to Scanner Space: Use affine transformations (from ANTs/FSL or NIfTI headers) to convert cluster coordinates from the source image space into the DICOM patient coordinate system (the scanner’s coordinate space).
	•	Load and Filter DICOM Series: Read DICOM files from a directory, group them by series, and filter to relevant modalities (e.g., T1 MPRAGE, T2 SPACE FLAIR, EPI DWI AX) via SeriesDescription metadata.
	•	Identify Slices Containing the Coordinates: For each cluster (now in scanner coordinates), determine which DICOM slice in each target series contains that point (or is closest to it) by matching the ImagePositionPatient (slice origin) and orientation. This typically involves comparing the cluster’s coordinate with the Z-position for axial slices, X for sagittal, or Y for coronal (generalized by using image orientation vectors).
	•	Convert DICOM Slices to PNG: Read the identified DICOM slices using pydicom, apply any necessary intensity scaling, and save the slice image as a PNG (using Pillow/PIL for image conversion).
	•	Output Images and Manifest: Save each slice image and record a manifest (CSV or JSON) that links each cluster ID with the modality, DICOM file path, slice index, PNG filename, and the original cluster coordinates.

This design ensures accurate spatial alignment (especially for high-resolution 3D sequences like MPRAGE or SPACE-FLAIR) and provides a clear output for integration into a brainstem lesion review pipeline. The code is organized into reusable functions and can be used via API or as a CLI script.

Coordinate Transformation to DICOM Space

Each cluster’s COG coordinate may initially be in a source image space (for example, coordinates relative to a cropped brainstem ROI or a FLAIR volume). We need to map this to the DICOM patient coordinate system used by scanner images. The DICOM patient coordinate system is a right-handed system where, for human imaging, the axes increase to the patient’s left (X), posterior (Y), and head/superior (Z) directions ￼. The DICOM tags ImagePositionPatient (IPP) and ImageOrientationPatient (IOP) define the location and orientation of each slice in this coordinate system ￼.

To transform coordinates, we use two possible inputs:
	•	The source NIfTI affine (from the image’s header) which maps voxel indices to the image’s real-world coordinates. This typically encodes the orientation and position of the image in scanner space (or a reference space). For example, a FLAIR volume’s qform/sform matrix can map voxel coordinates to patient space.
	•	An additional affine matrix from ANTs or FSL (if provided) that aligns the source image space to another space (e.g., if the clusters were identified in a brainstem-specific space or need to be mapped between FLAIR and T1). This matrix could be the output of a registration (such as FSL’s FLIRT .mat or ANTs .txt affine) and can be applied on top of the NIfTI header transform.

Using these, we compute the scanner-space coordinates as:

$$ \text{Coord}{scanner} = M{\text{transform}} ; \big( M_{\text{srcAffine}} ; [x, y, z, 1]^T \big) $$

Where $M_{\text{srcAffine}}$ is the 4×4 affine from the source NIfTI (if applicable), and $M_{\text{transform}}$ is the additional affine (if provided). If the cluster coordinates are already in the scanner’s coordinate frame, we can bypass these transforms. We also must ensure consistency of coordinate conventions (e.g., NIfTI uses RAS by default while DICOM uses LPS; our use of the NIfTI affine and registration outputs should account for any left-right axis flip if necessary).

Loading and Filtering DICOM Series

The module will scan a given directory for DICOM files and group them by series. Each series is identified by a unique Series Instance UID and contains multiple slices (for volumetric scans). For each series, we extract essential metadata:
	•	SeriesDescription and Modality (e.g., “T1 MPRAGE”, “T2 SPACE FLAIR”, “MR” etc.) to identify the scan type.
	•	ImageOrientationPatient (0020,0037) – a list of 6 values giving direction cosines of the image’s rows (first three values) and columns (next three). This, together with IPP, defines the slice’s plane orientation ￼.
	•	ImagePositionPatient (0020,0032) – a 3D coordinate (X, Y, Z in mm) of the upper-left corner of the slice in patient space ￼.
	•	PixelSpacing and SliceThickness – pixel size in mm (in-plane resolution) and slice thickness (distance between parallel slices). We will primarily rely on the actual positions (IPP differences) for slice spacing to ensure accuracy, since SliceThickness may not account for gaps or can be nominal. Using IPP is more reliable for ordering and spacing ￼.
	•	Rows, Columns – image dimensions (to check if a point lies within the slice’s field of view).

All DICOM files belonging to the same series are aggregated. We then filter the series to only those of interest by matching keywords in the SeriesDescription. For example, we might use filters: “MPRAGE” for T1, “FLAIR” or “SPACE” for FLAIR, and “DWI” for diffusion, etc. (case-insensitive). This would catch series named like “T1 MPRAGE”, “T2 SPACE FLAIR”, or “EPI DWI AX”. The filtering can be easily adjusted or expanded as needed. Series not matching these keywords (such as localizer images or other sequences) will be ignored.

Identifying the Corresponding Slice

For each filtered series and each cluster (in scanner coordinates), we determine which slice in that series corresponds to the cluster’s location. The approach is:
	1.	Compute the Slice Normal: Using the series’ orientation vectors for the row ($\vec{r}$) and column ($\vec{c}$) directions, compute the slice’s normal vector $\vec{n} = \vec{r} \times \vec{c}$. This normal (when normalized) points perpendicular to the image plane. For axial series, $\vec{n}$ is typically along ±Z; for sagittal, along ±X; for coronal, along ±Y (depending on acquisition).
	2.	Sort Slices by Position: Ensure the slices are ordered along the normal direction. We can sort by the dot product of each slice’s IPP with the normal vector. This gives the sequence of slices in increasing order along the patient’s anatomy. (Alternatively, if InstanceNumber tags are consistent, those can be used to sort slices in their acquisition order.)
	3.	Project the Cluster onto the Normal: We take the first slice’s position as a reference and compute $\text{t} = \vec{n} \cdot (\text{coord}_{scanner} - \text{IPP}_{first})$. This projects the cluster point onto the normal axis (distance from the first slice along the normal).
	4.	Find the Nearest Slice: Using the slice spacing (distance between adjacent slices along $\vec{n}$, computed from consecutive IPPs), we estimate the index $i \approx t / \text{spacing}$ and choose the nearest integer slice index. This yields the slice whose plane is closest to the cluster coordinate. We also clamp this index to the valid range [first, last slice]. If the cluster lies exactly on a slice plane, it will pick that slice; if it lies between two slices, it will pick the closer one. (If the distance from the cluster to the nearest slice plane is more than half the slice gap, one could consider it “not found in any slice”, but in practice we still select the nearest slice for visualization.)
	5.	Verify In-Plane Position: Once the candidate slice is chosen, we verify that the cluster’s projection falls within the bounds of that slice’s image. We compute the coordinates of the cluster relative to the slice’s origin in the plane: by projecting the vector from ImagePositionPatient to the cluster point onto the row and column direction vectors. This gives an (X, Y) offset in the slice’s plane. We check that $0 \leq X \leq (\text{Columns}-1) \times \text{PixelSpacing}_x$ and $0 \leq Y \leq (\text{Rows}-1) \times \text{PixelSpacing}_y$. If the point lies outside these ranges, it means the cluster is outside the field-of-view of that series (which could happen if, say, a cluster is in a region not covered by a particular sequence). In such cases, we would skip that series for the cluster. Typically, with whole-brain MRI sequences, the cluster should be within the FOV for all relevant series.

Using this method ensures we correctly handle different orientations and slice spacings. For 3D volumetric sequences (like MPRAGE or SPACE-FLAIR), the slices are usually contiguous with equal spacing (often isotropic resolution ~1 mm), and our normal-projection method will accurately identify the exact slice. For 2D multi-slice sequences (like axial DWI, which might have thicker slices, e.g., 5 mm), this method still works by using the actual IPP positions (accounting for any gaps). It’s more general and robust than relying on slice index or SliceLocation alone, as recommended by DICOM experts ￼.

(In a future expansion, to handle multi-planar 2D series where each slice might have a different orientation (e.g., separate sagittal, coronal, axial localizer images in one series), one would treat each slice individually or group slices by orientation. Our current approach assumes each series has a consistent orientation, which is true for standard MRI acquisitions.)

Converting DICOM Slices to PNG

After identifying the slice file for a given cluster and modality, we use pydicom to load that DICOM file and extract the pixel data. The steps for conversion and saving are:
	•	Load Pixel Data: Read the DICOM file with pydicom.dcmread. Access the .pixel_array attribute to get the image as a NumPy array. For MRI, this is typically a 16-bit grayscale image. We also handle any DICOM rescaling: if RescaleSlope and RescaleIntercept tags are present (these are common in CT or some parametric maps), we apply them to convert the raw pixel values to true intensity units. In MRI, often slope=1 and intercept=0, but we include this for completeness.
	•	Intensity Normalization: To ensure the PNG image is viewable with good contrast, we normalize the pixel intensities to the 0–255 range (8-bit). A simple approach is to subtract the minimum and scale by the maximum, so that the darkest pixel becomes 0 and the brightest becomes 255 ￼. This is effectively auto-windowing the image contrast for each slice. (If needed, one could apply specific window/level settings, but in absence of predefined values, this normalization yields a reasonable visualization ￼.)
	•	Save as PNG: Use PIL (Pillow) to create an image from the NumPy array and save it as a PNG file. The output filename can incorporate the cluster ID and modality for clarity (e.g., cluster3_T1.png for cluster 3 on the T1 MRI).

Each PNG image represents the original DICOM slice (same resolution and orientation as acquired) where the cluster is located. If needed for verification, one could even draw a marker at the exact coordinate on the image, but the prompt does not require adding annotations – it only requires saving the raw slice.

Output Manifest (CSV/JSON)

The module will produce a manifest that tabulates the results. Each entry (row in CSV or object in JSON) will include:
	•	Cluster ID: An identifier for the cluster (as provided in input).
	•	Modality: The scan type or series label (e.g., “T1”, “FLAIR”, “DWI”). We derive this from the SeriesDescription (using keywords).
	•	DICOM File Path: The full path to the DICOM file for the slice image. This allows traceability back to the original data.
	•	Slice Index: The slice number within that series. We use the DICOM InstanceNumber if available (since that typically corresponds to the slice order as labeled by the scanner). For example, if InstanceNumber is 37, it was the 37th slice in that series. If InstanceNumber is missing, we use the index in our sorted order (0-based or 1-based as appropriate).
	•	PNG Filename: The name of the saved PNG image file for that slice. (The path can be derived by combining the output directory with this name, or we can store the full path as well.)
	•	Original Coordinates: The original (X, Y, Z) coordinates of the cluster as given in the input (in the source space, e.g., brainstem or FLAIR space). This is useful for reference, so one knows the cluster’s location in the analysis space. (All coordinates are in millimeters, typically.)

The manifest makes it easy to review results: one can see for each cluster which modalities yielded an image and where. For example, a CSV row might look like:


This indicates cluster 3 is visualized on the T1 MPRAGE series, slice 37 (with that DICOM file), and was originally at coordinates (12.4, -8.3, -20.5) in the source space.

The module supports output in CSV (default) or JSON (if the output filename ends with .json). JSON output would be an array of entries, each with those fields, which might be convenient for programmatic use.

Python Module Implementation

Below is the Python module code with clear separation of functions for each core task: loading DICOM series, filtering by modality, transforming coordinates, finding slices, converting to PNG, and generating the manifest. The code can be used as a library or run as a script (with an appropriate if __name__ == "__main__": block to parse command-line arguments, which can be added for CLI usage). Comments and docstrings are included for clarity.

This would allow running the module from the command line with appropriate arguments.

	•	Dependencies: This module uses pydicom, numpy, and Pillow. If coordinate transforms are needed from NIfTI space, nibabel is also required. Ensure these are installed in your environment.
	•	Verification: The approach prioritizes accuracy by using the actual spatial metadata from DICOM. For 3D sequences (T1, FLAIR), the alignment should be precise – we use the affines to get true coordinates and find the exact slice. For each cluster, you might visually verify that the PNG indeed shows the intended lesion or ROI. The manifest helps cross-check indices and coordinate mappings. If minor discrepancies are observed (e.g., off by one slice due to a cluster falling between slices), you could adjust the logic or consider interpolating between slices, but typically choosing the nearest slice suffices for review purposes.

By integrating this module into your pipeline, you can automatically generate aligned slice images across modalities for each lesion cluster, greatly streamlining the review process. Each image can be quickly inspected side-by-side (since they correspond to the same physical location in the patient) to compare how the lesion appears on T1, FLAIR, and DWI sequences. The manifest provides an audit trail linking back to the original DICOM data for any further analysis.
