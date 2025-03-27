#!/usr/bin/env python3
"""
Extract metadata from DICOM files, particularly optimized for Siemens MAGNETOM Sola scanner.
This script extracts key parameters needed for optimizing MRI processing pipelines.

Usage:
    python extract_dicom_metadata.py <input_dicom_file> <output_json_file>
"""

import sys
import json
import os
try:
    import pydicom
except ImportError as e:
    print(f"ImportError: {str(e)}")
    # pydicom not available
    with open(output_path, 'w') as f:
        json.dump({
            "manufacturer": "Unknown",
            "fieldStrength": 3,
            "modelName": "Unknown",
            "error": "pydicom module not installed"
        }, f, indent=2)
    print("extract_dicom_metadata.py: FATAL: PYDICOM_NOT_FOUND")
    exit(1)

def extract_metadata(dicom_path, output_path):
    """Extract metadata from a DICOM file and save it as JSON."""
    try:
        # Read the DICOM file
        print(f"Reading DICOM file: {dicom_path}")
        dcm = pydicom.dcmread(dicom_path)
        print("Successfully read DICOM file")
        
        # Create metadata dictionary
        metadata = {}
        
        # Helper function to handle non-serializable values
        def safe_value(value):
            # Handle MultiValue types by converting to list
            if hasattr(value, '__iter__') and not isinstance(value, (str, bytes, dict)):
                return [safe_value(x) for x in value]
            # Handle binary data
            if isinstance(value, bytes):
                return str(value)
            # Try to convert to float or string
            try:
                return float(value)
            except (ValueError, TypeError):
                return str(value)
            
        # Basic scanner information
        if hasattr(dcm, 'Manufacturer'):
            metadata['manufacturer'] = safe_value(dcm.Manufacturer)
        if hasattr(dcm, 'ManufacturerModelName'):
            metadata['modelName'] = safe_value(dcm.ManufacturerModelName)
        if hasattr(dcm, 'MagneticFieldStrength'):
            try:
                metadata['fieldStrength'] = float(dcm.MagneticFieldStrength)
            except:
                metadata['fieldStrength'] = 3.0
            
        # Sequence information
        if hasattr(dcm, 'ProtocolName'):
            metadata['protocolName'] = safe_value(dcm.ProtocolName)
        if hasattr(dcm, 'SeriesDescription'):
            metadata['seriesDescription'] = safe_value(dcm.SeriesDescription)
        if hasattr(dcm, 'SequenceName'):
            metadata['sequenceName'] = safe_value(dcm.SequenceName)
        if hasattr(dcm, 'ScanningSequence'):
            metadata['scanningSequence'] = safe_value(dcm.ScanningSequence)
        if hasattr(dcm, 'SequenceVariant'):
            metadata['sequenceVariant'] = safe_value(dcm.SequenceVariant)
            
        # Acquisition parameters
        if hasattr(dcm, 'SliceThickness'):
            try:
                metadata['sliceThickness'] = float(dcm.SliceThickness)
            except:
                pass
        if hasattr(dcm, 'RepetitionTime'):
            try:
                metadata['TR'] = float(dcm.RepetitionTime)
            except:
                pass
        if hasattr(dcm, 'EchoTime'):
            try:
                metadata['TE'] = float(dcm.EchoTime)
            except:
                pass
        if hasattr(dcm, 'FlipAngle'):
            try:
                metadata['flipAngle'] = float(dcm.FlipAngle)
            except:
                pass
        if hasattr(dcm, 'SpacingBetweenSlices'):
            try:
                metadata['spacingBetweenSlices'] = float(dcm.SpacingBetweenSlices)
            except:
                pass
        
        # Pixel dimensions
        if hasattr(dcm, 'PixelSpacing'):
            try:
                metadata['pixelSpacing'] = [float(x) for x in dcm.PixelSpacing]
            except:
                pass
        
        # Special case for Siemens MAGNETOM Sola
        if hasattr(dcm, 'ManufacturerModelName') and 'MAGNETOM Sola' in str(dcm.ManufacturerModelName):
            metadata['isMagnetomSola'] = True
            
        # Write to JSON file
        print(f"Writing metadata to: {output_path}")
        with open(output_path, 'w') as f:
            json.dump(metadata, f, indent=2)
            
        print("SUCCESS")
        return 0
                
    except Exception as e:
        print(f"Error: {str(e)}")
        # Handle other errors
        with open(output_path, 'w') as f:
            json.dump({
                "manufacturer": "Unknown", 
                "fieldStrength": 3,
                "modelName": "Unknown",
                "error": str(e)
            }, f, indent=2)
        print(f"ERROR: {str(e)}")
        return 2

if __name__ == "__main__":
    # Check command line arguments
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input_dicom_file> <output_json_file>")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2] #Write to JSON file with the scanner metadata
    
    # Verify input file exists
    if not os.path.isfile(input_file):
        print(f"ERROR: Input file '{input_file}' does not exist")
        sys.exit(1)
        
    # Extract metadata
    sys.exit(extract_metadata(input_file, output_file))
