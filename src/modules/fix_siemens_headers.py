#!/usr/bin/env python3
"""
Script to fix Siemens DICOM headers by adding missing fields
that are critical for proper slice identification during conversion.

This addresses the specific issue where dcm2niix marks all images as duplicates
due to missing Series Instance UID (0020,000E) and Stack ID (0020,9056) fields.

Usage: python fix_siemens_headers.py <dicom_directory>
"""

import os
import sys
import glob
import random
import subprocess
import tempfile
from pathlib import Path
import uuid

# DICOM fields to fix and their descriptions
CRITICAL_FIELDS = {
    #"0020,000E": "Series Instance UID",
    #"0020,9056": "Stack ID",
    "0020,0013": "Instance Number",
    "0008,0021": "Series Date",
    "0008,0031": "Series Time"
    "0008,1160": "ReferencedFrameNumber"
}

def run_dcmdump(filename, tag):
    """Run dcmdump to extract a tag value from a DICOM file"""
    try:
        cmd = ["dcmdump", "+P", tag, filename]
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode != 0:
            return None
            
        for line in result.stdout.splitlines():
            if tag in line:
                # Extract value from format like: (0020,000e) UI [2.25....]
                start = line.find('[')
                end = line.find(']')
                if start > 0 and end > start:
                    return line[start+1:end].strip()
        return None
    except Exception as e:
        print(f"Error running dcmdump: {e}")
        return None

def fix_dicom_headers(dicom_dir):
    """Fix missing DICOM headers in all files in a directory"""
    # Check if dcmodify is available
    try:
        subprocess.run(["which", "dcmodify"], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        print("Error: dcmodify not found. Please install DCMTK.")
        print("On macOS: brew install dcmtk")
        print("On Linux: apt-get install dcmtk or similar")
        return 1
    
    # Find all DICOM files
    patterns = ['*.dcm', 'IM*', 'Image*', '*.[0-9][0-9][0-9][0-9]', 'DICOM*']
    dicom_files = []
    
    for pattern in patterns:
        files = glob.glob(os.path.join(dicom_dir, pattern))
        if files:
            dicom_files.extend(files)
            print(f"Found {len(files)} files with pattern {pattern}")
            break
    
    if not dicom_files:
        print(f"No DICOM files found in {dicom_dir}")
        return 1
    
    print(f"Processing {len(dicom_files)} DICOM files...")
    
    # Identify unique series
    series_info = {}
    
    # Sample the first file to check if it has a SIEMENS manufacturer
    is_siemens = False
    if dicom_files:
        manufacturer = run_dcmdump(dicom_files[0], "0008,0070")
        if manufacturer and "SIEMENS" in manufacturer.upper():
            is_siemens = True
            print("Confirmed Siemens DICOM files")
        else:
            print(f"Warning: Files may not be Siemens DICOM (Manufacturer: {manufacturer})")
    
    # Group files by series
    for file in dicom_files:
        # Extract series number
        series_num = run_dcmdump(file, "0020,0011")
        if not series_num:
            series_num = "UNKNOWN"
        
        if series_num not in series_info:
            series_info[series_num] = {
                "files": [],
                "series_uid": str(uuid.uuid4()),  # Generate a unique Series Instance UID
                "needs_fix": False
            }
        
        series_info[series_num]["files"].append(file)
        
        # Check if this file needs fixing
        for tag in ["0020,000E", "0020,9056"]:
            value = run_dcmdump(file, tag)
            if not value:
                series_info[series_num]["needs_fix"] = True
                break
    
    # Fix each series
    modified_count = 0
    for series_num, info in series_info.items():
        if not info["needs_fix"]:
            print(f"Series {series_num} doesn't need fixing (has all required fields)")
            continue
        
        print(f"Fixing series {series_num} with {len(info['files'])} files...")
        
        # Generate a unique Series Instance UID if needed
        series_uid = info["series_uid"]
        
        # Process each file in the series
        for i, file in enumerate(info["files"]):
            # Create a temporary script file for dcmodify - this avoids command line parsing issues
            with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as script:
                script_path = script.name
                
                # Add the needed tags to the script file
                if not run_dcmdump(file, "0020,000E"):
                    script.write(f"(0020,000E) UI [{series_uid}]\n")
                    
                if not run_dcmdump(file, "0020,9056"):
                    script.write(f"(0020,9056) LO [{series_num}]\n")
                    
                instance_num = run_dcmdump(file, "0020,0013")
                if not instance_num or (instance_num == "1" and i > 0):
                    script.write(f"(0020,0013) IS [{i+1}]\n")
            
            # Run dcmodify with the script file
            try:
                cmd = ["dcmodify", "--insert-from-file", script_path, file]
                cmd_str = " ".join(cmd)
                
                print(f"Running: {cmd_str}")
                result = subprocess.run(cmd, capture_output=True, text=True)
                
                # Clean up the temp file regardless of success/failure
                try:
                    os.remove(script_path)
                except:
                    pass
                
                if result.returncode != 0:
                    print(f"Error modifying {file}: {result.stderr}")
                    print("Trying alternative dcmodify syntax...")
                    
                    # Try alternative direct approach
                    try:
                        # DCMTK 3.6.x syntax
                        alt_cmd = ["dcmodify"]
                        if not run_dcmdump(file, "0020,000E"):
                            alt_cmd.extend(["-m", f"(0020,000E)={series_uid}"])
                        if not run_dcmdump(file, "0020,9056"):
                            alt_cmd.extend(["-m", f"(0020,9056)={series_num}"])
                        if not instance_num or (instance_num == "1" and i > 0):
                            alt_cmd.extend(["-m", f"(0020,0013)={i+1}"])
                        alt_cmd.append(file)
                        
                        print(f"Trying: {' '.join(alt_cmd)}")
                        alt_result = subprocess.run(alt_cmd, capture_output=True, text=True)
                        
                        if alt_result.returncode != 0:
                            print(f"Alternative approach also failed: {alt_result.stderr}")
                        else:
                            modified_count += 1
                            print(f"Successfully modified {file} with alternative syntax")
                    except Exception as e:
                        print(f"Error with alternative approach: {e}")
                else:
                    modified_count += 1
                    print(f"Successfully modified {file}")
            except Exception as e:
                print(f"Exception modifying {file}: {e}")
    
    print(f"Modified {modified_count} files")
    
    # If dcmodify failed but we need the fix, try a different approach - modify dcm2niix flags instead
    if modified_count == 0:
        print("\nCouldn't modify DICOM headers. Recommend using these dcm2niix flags instead:")
        print("  dcm2niix -z y -f \"%p_%s\" --no-collapse --ignore-derived --exact_values 1 -m y -i y -o <output_dir> <input_dir>")
    
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <dicom_directory>")
        sys.exit(1)
    
    dicom_dir = sys.argv[1]
    if not os.path.isdir(dicom_dir):
        print(f"Error: {dicom_dir} is not a directory")
        sys.exit(1)
    
    sys.exit(fix_dicom_headers(dicom_dir))
