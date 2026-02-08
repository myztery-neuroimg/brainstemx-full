#!/usr/bin/env python3
"""
Script to analyze DICOM headers and identify identical fields
that might cause dcm2niix to flag files as duplicates.

Usage: python analyze_dicom_headers.py <dicom_directory>
"""

import os
import sys
import glob
from collections import defaultdict
import subprocess
import re

# Key DICOM fields that dcm2niix uses to identify duplicates
CRITICAL_FIELDS = [
    "InstanceNumber",
    "SeriesNumber",
    "AcquisitionNumber",
    "AcquisitionTime",
    "SeriesTime",
    "ContentTime",
    "TriggerTime",
    "TemporalPositionIdentifier",
    "DiffusionDirectionality",
    "SliceLocation"
]


def extract_dicom_field(dcmdump_output, field_name):
    """Extract a specific field from dcmdump output."""
    pattern = re.compile(rf"\({field_name}\).*\[(.*)\]")
    match = pattern.search(dcmdump_output)
    if match:
        return match.group(1).strip()
    return None


def _find_dicom_files(dicom_dir):
    """Find DICOM files in directory using common patterns."""
    patterns = ['*.dcm', 'IM*', 'Image*', '*.[0-9][0-9][0-9][0-9]', 'DICOM*']
    for pattern in patterns:
        files = glob.glob(os.path.join(dicom_dir, pattern))
        if files:
            print(f"Found {len(files)} files with pattern {pattern}")
            return files
    return []


def _extract_file_fields(file_path):
    """Run dcmdump on a file and extract critical DICOM fields."""
    result = subprocess.run(
        ["dcmdump", file_path],
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        print(f"Error processing {file_path}: {result.stderr}")
        return None

    file_fields = {}
    for field in CRITICAL_FIELDS:
        file_fields[field] = extract_dicom_field(result.stdout, field)
    return file_fields


def _report_field_analysis(all_fields):
    """Report which fields are identical across all sampled files."""
    print("\n=== Field Analysis ===")
    for field in CRITICAL_FIELDS:
        values = all_fields[field]
        if not values:
            print(f"{field}: No values found")
            continue

        unique_values = set(val for val in values if val is not None)

        if len(unique_values) == 1:
            print(
                f"{field}: IDENTICAL across all files"
                f" - value: {list(unique_values)[0]}"
            )
        else:
            print(
                f"{field}: {len(unique_values)} unique values"
                f" out of {len(values)} files"
            )


def _check_problematic_combinations(all_fields):
    """Check for field combinations known to cause dcm2niix issues."""
    print("\n=== Problematic Combinations ===")
    time_fields = ["SeriesTime", "AcquisitionTime"]
    if all(
        len(set(all_fields[f])) == 1
        for f in time_fields
        if all_fields[f]
    ):
        print("WARNING: All files have identical Series and Acquisition times")

    id_fields = ["InstanceNumber", "AcquisitionNumber"]
    if all(
        len(set(all_fields[f])) == 1
        for f in id_fields
        if all_fields[f]
    ):
        print("WARNING: All files have identical Instance and Acquisition numbers")


def _suggest_fix(all_fields):
    """Suggest dcm2niix flags based on identical fields found."""
    print("\n=== Recommended Fix ===")
    identical_fields = [
        f for f in CRITICAL_FIELDS
        if all_fields[f]
        and len(set(v for v in all_fields[f] if v is not None)) == 1
    ]

    if identical_fields:
        print(
            "Critical fields with identical values: "
            f"{', '.join(identical_fields)}"
        )
        print("Recommendation: Use these dcm2niix flags:")
        print("  --no-collapse --ignore-derived --exact_values 1")

        if "InstanceNumber" in identical_fields:
            print(
                "Additional flag needed for identical InstanceNumber:"
                " --split-2d"
            )
    else:
        print(
            "No critical fields with identical values found."
            " Check non-standard fields."
        )


def analyze_dicom_directory(dicom_dir):
    """Analyze all DICOM files in a directory to find identical headers."""
    dicom_files = _find_dicom_files(dicom_dir)

    if not dicom_files:
        print(f"No DICOM files found in {dicom_dir}")
        return

    sample_files = dicom_files[:min(10, len(dicom_files))]
    print(f"Analyzing {len(sample_files)} of {len(dicom_files)} files...")

    all_fields = defaultdict(list)

    for file_path in sample_files:
        print(f"Processing {os.path.basename(file_path)}...")

        try:
            file_fields = _extract_file_fields(file_path)
        except OSError as e:
            print(f"Error processing {file_path}: {e}")
            continue

        if file_fields is None:
            continue

        for field, value in file_fields.items():
            all_fields[field].append(value)

        print(f"File: {os.path.basename(file_path)}")
        for field, value in file_fields.items():
            print(f"  {field}: {value}")
        print()

    _report_field_analysis(all_fields)
    _check_problematic_combinations(all_fields)
    _suggest_fix(all_fields)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <dicom_directory>")
        sys.exit(1)

    input_dir = sys.argv[1]
    analyze_dicom_directory(input_dir)
