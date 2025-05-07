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
import json
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
    """Extract a specific field from dcmdump output"""
    pattern = re.compile(rf"\({field_name}\).*\[(.*)\]")
    match = pattern.search(dcmdump_output)
    if match:
        return match.group(1).strip()
    return None

def analyze_dicom_directory(dicom_dir):
    """Analyze all DICOM files in a directory to find identical headers"""
    # Find DICOM files
    dicom_patterns = ['*.dcm', 'IM*', 'Image*', '*.[0-9][0-9][0-9][0-9]', 'DICOM*']
    dicom_files = []
    
    for pattern in dicom_patterns:
        files = glob.glob(os.path.join(dicom_dir, pattern))
        if files:
            dicom_files.extend(files)
            print(f"Found {len(files)} files with pattern {pattern}")
            break
    
    if not dicom_files:
        print(f"No DICOM files found in {dicom_dir}")
        return
    
    # Limit to 10 files for analysis to avoid excessive processing
    sample_files = dicom_files[:min(10, len(dicom_files))]
    print(f"Analyzing {len(sample_files)} of {len(dicom_files)} files...")
    
    # Extract fields from each file
    all_fields = defaultdict(list)
    
    for file_path in sample_files:
        print(f"Processing {os.path.basename(file_path)}...")
        
        try:
            # Use dcmdump to extract header info
            result = subprocess.run(
                ["dcmdump", file_path], 
                capture_output=True, 
                text=True
            )
            
            if result.returncode != 0:
                print(f"Error processing {file_path}: {result.stderr}")
                continue
                
            output = result.stdout
            
            # Extract key fields
            file_fields = {}
            for field in CRITICAL_FIELDS:
                value = extract_dicom_field(output, field)
                file_fields[field] = value
                all_fields[field].append(value)
            
            print(f"File: {os.path.basename(file_path)}")
            for field, value in file_fields.items():
                print(f"  {field}: {value}")
            print()
            
        except Exception as e:
            print(f"Error processing {file_path}: {str(e)}")
    
    # Analyze which fields are identical across all files
    print("\n=== Field Analysis ===")
    for field in CRITICAL_FIELDS:
        values = all_fields[field]
        if not values:
            print(f"{field}: No values found")
            continue
            
        unique_values = set(val for val in values if val is not None)
        
        if len(unique_values) == 1:
            print(f"{field}: IDENTICAL across all files - value: {list(unique_values)[0]}")
        else:
            print(f"{field}: {len(unique_values)} unique values out of {len(values)} files")
            
    # Check for problematic combinations
    print("\n=== Problematic Combinations ===")
    if all(len(set(all_fields[f])) == 1 for f in ["SeriesTime", "AcquisitionTime"] if all_fields[f]):
        print("WARNING: All files have identical Series and Acquisition times")
        
    if all(len(set(all_fields[f])) == 1 for f in ["InstanceNumber", "AcquisitionNumber"] if all_fields[f]):
        print("WARNING: All files have identical Instance and Acquisition numbers")
    
    # Suggest solution
    print("\n=== Recommended Fix ===")
    identical_fields = [f for f in CRITICAL_FIELDS if len(set(v for v in all_fields[f] if v is not None)) == 1 and all_fields[f]]
    
    if identical_fields:
        print(f"Critical fields with identical values: {', '.join(identical_fields)}")
        print("Recommendation: Use these dcm2niix flags:")
        print("  --no-collapse --ignore-derived --exact_values 1")
        
        if "InstanceNumber" in identical_fields:
            print("Additional flag needed for identical InstanceNumber: --split-2d")
    else:
        print("No critical fields with identical values found. Check non-standard fields.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <dicom_directory>")
        sys.exit(1)
        
    dicom_dir = sys.argv[1]
    analyze_dicom_directory(dicom_dir)