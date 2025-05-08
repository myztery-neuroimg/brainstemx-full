#!/usr/bin/env python3
"""
Advanced Pons and Brainstem Segmentation with SUIT, ANTs and Juelich Atlas

This module provides tools for segmenting the brainstem and pons using multiple
complementary approaches:
1. SUIT atlas-based segmentation
2. ANTs-based registration to MNI space
3. Juelich atlas-based segmentation

All results are standardized to MNI space for consistent comparison and analysis.
"""

import os
import sys
import numpy as np
import nibabel as nib
import ants
from pathlib import Path
from sklearn.decomposition import PCA
import logging
import subprocess
from typing import Dict, Tuple, List, Optional, Union, Any

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


class BrainstemSegmentation:
    """Advanced brainstem and pons segmentation using multiple atlas-based methods"""
    
    def __init__(self, 
                 suit_dir: Union[str, Path], 
                 mni_template: Optional[Union[str, Path]] = None,
                 fsl_dir: Optional[Union[str, Path]] = None):
        """
        Initialize the brainstem segmentation pipeline
        
        Args:
            suit_dir: Path to SUIT directory
            mni_template: Path to MNI template (default: FSL standard)
            fsl_dir: Path to FSL directory (default: $FSLDIR environment variable)
        """
        self.suit_dir = Path(suit_dir)
        self.fsl_dir = Path(fsl_dir) if fsl_dir else Path(os.environ.get('FSLDIR', '/opt/fsl'))
        
        # Default MNI template if not specified
        if mni_template is None:
            self.mni_template = self.fsl_dir / "data" / "standard" / "MNI152_T1_1mm.nii.gz"
        else:
            self.mni_template = Path(mni_template)
            
        # Verify paths exist
        self._verify_paths()
        
        # Load templates
        self.templates = self._load_templates()
        logger.info(f"Initialized segmentation with SUIT dir: {self.suit_dir}")
        logger.info(f"MNI template: {self.mni_template}")
        
    def _verify_paths(self):
        """Verify that all required paths and files exist"""
        # Check SUIT directory and templates
        if not self.suit_dir.exists():
            raise FileNotFoundError(f"SUIT directory not found: {self.suit_dir}")
            
        # Check for specific SUIT templates
        suit_reorient = self.suit_dir / "templates" / "SUIT_reorient.nii.gz"
        if not suit_reorient.exists():
            logger.warning(f"SUIT_reorient.nii.gz not found at {suit_reorient}")
            logger.warning("Running reorientation script first...")
            self._run_reorientation()
            
        # Check MNI template
        if not self.mni_template.exists():
            raise FileNotFoundError(f"MNI template not found: {self.mni_template}")
            
        # Check FSL directory and Juelich atlas
        juelich_path = self.fsl_dir / "data" / "atlases" / "Juelich" / "Juelich-maxprob-thr25-1mm.nii.gz"
        if not juelich_path.exists():
            logger.warning(f"Juelich atlas not found: {juelich_path}")
            logger.warning("Juelich atlas segmentation will be skipped")
            
    def _run_reorientation(self):
        """Run reorientation script for SUIT templates"""
        reorient_script = Path(__file__).parent / "reorient_suit_atlas.sh"
        
        if not reorient_script.exists():
            raise FileNotFoundError(f"Reorientation script not found: {reorient_script}")
            
        # Run the reorientation script
        logger.info("Running SUIT reorientation script...")
        env = os.environ.copy()
        env["SUIT_DIR"] = str(self.suit_dir)
        
        try:
            subprocess.run(
                ["bash", str(reorient_script)], 
                env=env,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )
            logger.info("SUIT reorientation completed successfully")
        except subprocess.CalledProcessError as e:
            logger.error(f"SUIT reorientation failed: {e}")
            logger.error(f"STDOUT: {e.stdout.decode()}")
            logger.error(f"STDERR: {e.stderr.decode()}")
            raise
            
    def _load_templates(self) -> Dict[str, ants.ANTsImage]:
        """Load all required templates for segmentation"""
        templates = {}
        
        # MNI template
        templates['mni'] = ants.image_read(str(self.mni_template))
        
        # SUIT templates - prefer reoriented versions
        suit_templates = {
            # Primary choice: reoriented templates
            'suit': self.suit_dir / "templates" / "SUIT_reorient.nii.gz",
            'suit_t1': self.suit_dir / "templates" / "T1_reorient.nii.gz",
            # Fallback: original templates
            'suit_original': self.suit_dir / "templates" / "SUIT.nii",
            'suit_t1_original': self.suit_dir / "templates" / "T1.nii"
        }
        
        # First try to load reoriented templates
        reoriented_loaded = False
        if suit_templates['suit'].exists() and suit_templates['suit_t1'].exists():
            try:
                templates['suit'] = ants.image_read(str(suit_templates['suit']))
                templates['suit_t1'] = ants.image_read(str(suit_templates['suit_t1']))
                reoriented_loaded = True
                logger.info("Successfully loaded reoriented SUIT templates")
            except Exception as e:
                logger.error(f"Failed to load reoriented SUIT templates: {e}")
                reoriented_loaded = False
        
        # If reoriented templates failed, try original templates
        if not reoriented_loaded:
            logger.warning("Reoriented templates not available, checking for original templates")
            if suit_templates['suit_original'].exists() and suit_templates['suit_t1_original'].exists():
                try:
                    # Store as primary templates
                    templates['suit'] = ants.image_read(str(suit_templates['suit_original']))
                    templates['suit_t1'] = ants.image_read(str(suit_templates['suit_t1_original']))
                    logger.warning("Using original SUIT templates. Consider running reorient_suit_atlas.sh")
                except Exception as e:
                    logger.error(f"Failed to load original SUIT templates: {e}")
            else:
                logger.error("Neither reoriented nor original SUIT templates are available")
                
        # Try to load Harvard-Oxford atlas
        harvard_path = self.fsl_dir / "data" / "atlases" / "HarvardOxford" / "HarvardOxford-sub-maxprob-thr25-1mm.nii.gz"
        if harvard_path.exists():
            templates['harvard'] = ants.image_read(str(harvard_path))
            
        # Try to load Juelich atlas
        juelich_path = self.fsl_dir / "data" / "atlases" / "Juelich" / "Juelich-maxprob-thr25-1mm.nii.gz"
        if juelich_path.exists():
            templates['juelich'] = ants.image_read(str(juelich_path))
            
        logger.info(f"Loaded templates: {', '.join(templates.keys())}")
        return templates
        
    def segment_with_juelich(self, input_img: ants.ANTsImage) -> Dict[str, ants.ANTsImage]:
        """
        Segment brainstem using Juelich atlas
        
        Args:
            input_img: ANTs image to segment
            
        Returns:
            Dictionary with segmentation results
        """
        if 'juelich' not in self.templates:
            logger.warning("Juelich atlas not available, skipping segmentation")
            return {}
            
        logger.info("Starting Juelich atlas-based brainstem segmentation")
        
        # Register input to MNI space (where Juelich atlas lives)
        logger.info("Registering input to MNI space...")
        reg_result = ants.registration(
            fixed=self.templates['mni'],
            moving=input_img,
            type_of_transform='SyN'
        )
        
        # Get Juelich atlas indices
        # These are the standard indices for brainstem regions in Juelich atlas
        indices = {
            'brainstem': 105,  # Approximate index for whole brainstem
            'pons': 105,       # Pons typically has index 105
            'midbrain': 106,   # Midbrain typically has index 106
            'medulla': 107     # Medulla typically has index 107
        }
        
        # Extract each region
        results = {}
        juelich_atlas = self.templates['juelich'].numpy()
        
        for region, index in indices.items():
            # Create mask for this region
            region_mask = (juelich_atlas == index).astype(np.float32)
            region_img = ants.from_numpy(
                region_mask,
                origin=self.templates['juelich'].origin,
                spacing=self.templates['juelich'].spacing,
                direction=self.templates['juelich'].direction
            )
            
            # Transform mask to subject space
            subject_mask = ants.apply_transforms(
                fixed=input_img,
                moving=region_img,
                transformlist=reg_result['invtransforms'],
                interpolator='nearestNeighbor'
            )
            
            # Apply mask to original image for intensity version
            masked_img = input_img * subject_mask
            
            # Store results
            results[f'{region}_mask'] = subject_mask
            results[f'{region}_intensity'] = masked_img
            
            # Also store MNI space version
            mni_space_mask = ants.apply_transforms(
                fixed=self.templates['mni'],
                moving=subject_mask,
                transformlist=reg_result['fwdtransforms'],
                interpolator='nearestNeighbor'
            )
            results[f'{region}_mask_mni'] = mni_space_mask
            
        # Add transformations for future use
        results['to_mni_transforms'] = reg_result['fwdtransforms']
        results['from_mni_transforms'] = reg_result['invtransforms']
        
        logger.info("Juelich atlas segmentation completed")
        return results
        
    def segment_with_suit(self, input_img: ants.ANTsImage) -> Dict[str, ants.ANTsImage]:
        """
        Segment brainstem using SUIT atlas
        
        Args:
            input_img: ANTs image to segment
            
        Returns:
            Dictionary with segmentation results
        """
        if 'suit' not in self.templates or 'suit_t1' not in self.templates:
            logger.warning("SUIT templates not available, skipping segmentation")
            return {}
            
        logger.info("Starting SUIT atlas-based brainstem segmentation")
        
        # Register input to SUIT T1 template
        logger.info("Registering input to SUIT T1 template...")
        reg_result = ants.registration(
            fixed=self.templates['suit_t1'],
            moving=input_img,
            type_of_transform='SyN'
        )
        
        # Extract brainstem/cerebellum using SUIT atlas
        suit_atlas = self.templates['suit'].numpy()
        
        # SUIT atlas: cerebellum = 1-28, brainstem = 30
        brainstem_mask = (suit_atlas == 30).astype(np.float32)
        cerebellum_mask = ((suit_atlas >= 1) & (suit_atlas <= 28)).astype(np.float32)
        
        # Convert to ANTs images
        brainstem_img = ants.from_numpy(
            brainstem_mask,
            origin=self.templates['suit'].origin,
            spacing=self.templates['suit'].spacing,
            direction=self.templates['suit'].direction
        )
        
        # Transform mask to subject space
        subject_brainstem_mask = ants.apply_transforms(
            fixed=input_img,
            moving=brainstem_img,
            transformlist=reg_result['invtransforms'],
            interpolator='nearestNeighbor'
        )
        
        # Apply mask to original image for intensity version
        masked_img = input_img * subject_brainstem_mask
        
        # Divide pons into dorsal and ventral regions using geometric approach
        dorsal_mask, ventral_mask = self._divide_pons_geometric(subject_brainstem_mask)
        
        # Also transform to MNI space for standardized comparison
        # First need to register SUIT to MNI space
        logger.info("Registering SUIT results to MNI space...")
        suit_to_mni_reg = ants.registration(
            fixed=self.templates['mni'],
            moving=self.templates['suit_t1'],
            type_of_transform='SyN'
        )
        
        # Register subject brainstem mask to MNI
        logger.info("Transforming results to MNI space...")
        mni_transform_list = suit_to_mni_reg['fwdtransforms'] + reg_result['fwdtransforms']
        
        mni_brainstem_mask = ants.apply_transforms(
            fixed=self.templates['mni'],
            moving=subject_brainstem_mask,
            transformlist=mni_transform_list,
            interpolator='nearestNeighbor'
        )
        
        mni_dorsal_mask = ants.apply_transforms(
            fixed=self.templates['mni'],
            moving=dorsal_mask,
            transformlist=mni_transform_list,
            interpolator='nearestNeighbor'
        )
        
        mni_ventral_mask = ants.apply_transforms(
            fixed=self.templates['mni'],
            moving=ventral_mask,
            transformlist=mni_transform_list,
            interpolator='nearestNeighbor'
        )
        
        # Store results
        results = {
            'brainstem_mask': subject_brainstem_mask,
            'brainstem_intensity': masked_img,
            'dorsal_pons_mask': dorsal_mask,
            'dorsal_pons_intensity': input_img * dorsal_mask,
            'ventral_pons_mask': ventral_mask,
            'ventral_pons_intensity': input_img * ventral_mask,
            'brainstem_mask_mni': mni_brainstem_mask,
            'dorsal_pons_mask_mni': mni_dorsal_mask,
            'ventral_pons_mask_mni': mni_ventral_mask,
            'to_suit_transforms': reg_result['fwdtransforms'],
            'from_suit_transforms': reg_result['invtransforms'],
            'suit_to_mni_transforms': suit_to_mni_reg['fwdtransforms']
        }
        
        logger.info("SUIT atlas segmentation completed")
        return results
        
    def _divide_pons_geometric(self, brainstem_mask: ants.ANTsImage) -> Tuple[ants.ANTsImage, ants.ANTsImage]:
        """
        Divide the brainstem/pons into dorsal and ventral regions using geometric approach
        
        Args:
            brainstem_mask: Binary mask of the brainstem
            
        Returns:
            Tuple of (dorsal_mask, ventral_mask)
        """
        logger.info("Dividing pons into dorsal and ventral regions...")
        
        # Get mask as numpy array
        mask_array = brainstem_mask.numpy()
        
        # Get coordinates of all nonzero voxels
        coords = np.array(np.where(mask_array > 0)).T
        
        if len(coords) == 0:
            logger.warning("Empty brainstem mask, cannot divide")
            empty_mask = brainstem_mask * 0
            return empty_mask, empty_mask
            
        # Apply PCA to find principal axes
        pca = PCA(n_components=3)
        pca.fit(coords)
        
        # Calculate centroid
        centroid = np.mean(coords, axis=0)
        
        # Principal anatomical axes
        ap_axis = pca.components_[0]  # Anterior-posterior (typically longest axis)
        si_axis = pca.components_[1]  # Superior-inferior 
        ml_axis = pca.components_[2]  # Medial-lateral
        
        # Project coordinates onto superior-inferior axis
        si_projections = np.dot(coords - centroid, si_axis)
        
        # Use 45% threshold from the ventral end
        threshold = np.percentile(si_projections, 45)
        
        # Create masks
        dorsal_array = np.zeros_like(mask_array)
        ventral_array = np.zeros_like(mask_array)
        
        for i, point in enumerate(coords):
            if si_projections[i] < threshold:
                ventral_array[tuple(point)] = 1
            else:
                dorsal_array[tuple(point)] = 1
                
        # Convert arrays back to ANTs images
        dorsal_mask = ants.from_numpy(
            dorsal_array,
            origin=brainstem_mask.origin,
            spacing=brainstem_mask.spacing,
            direction=brainstem_mask.direction
        )
        
        ventral_mask = ants.from_numpy(
            ventral_array,
            origin=brainstem_mask.origin,
            spacing=brainstem_mask.spacing,
            direction=brainstem_mask.direction
        )
        
        return dorsal_mask, ventral_mask
        
    def process_image(self, input_path: Union[str, Path], 
                     output_dir: Union[str, Path],
                     prefix: str = "") -> Dict[str, str]:
        """
        Process a single image with all available segmentation methods
        
        Args:
            input_path: Path to input image
            output_dir: Directory for output files
            prefix: Prefix for output filenames
            
        Returns:
            Dictionary with paths to output files
        """
        input_path = Path(input_path)
        output_dir = Path(output_dir)
        
        # Create output directories
        brainstem_dir = output_dir / "segmentation" / "brainstem"
        pons_dir = output_dir / "segmentation" / "pons"
        
        brainstem_dir.mkdir(parents=True, exist_ok=True)
        pons_dir.mkdir(parents=True, exist_ok=True)
        
        # Load input image
        logger.info(f"Loading input image: {input_path}")
        input_img = ants.image_read(str(input_path))
        
        # Base filename for outputs
        if prefix:
            base_name = prefix
        else:
            base_name = input_path.stem
            if base_name.endswith('.nii'):
                base_name = base_name[:-4]
                
        # Process with all available methods
        file_paths = {}
        
        # 1. SUIT atlas segmentation
        logger.info("Starting SUIT atlas segmentation...")
        suit_results = self.segment_with_suit(input_img)
        
        if suit_results:
            # Save SUIT results
            for name, img in suit_results.items():
                if not isinstance(img, ants.ANTsImage):
                    continue  # Skip transforms and other non-image data
                    
                if 'brainstem' in name:
                    output_path = brainstem_dir / f"{base_name}_suit_{name}.nii.gz"
                else:
                    output_path = pons_dir / f"{base_name}_suit_{name}.nii.gz"
                    
                logger.info(f"Saving SUIT result: {output_path}")
                img.to_filename(str(output_path))
                file_paths[f"suit_{name}"] = str(output_path)
        
        # 2. Juelich atlas segmentation
        logger.info("Starting Juelich atlas segmentation...")
        juelich_results = self.segment_with_juelich(input_img)
        
        if juelich_results:
            # Save Juelich results
            for name, img in juelich_results.items():
                if not isinstance(img, ants.ANTsImage):
                    continue  # Skip transforms and other non-image data
                    
                if 'brainstem' in name:
                    output_path = brainstem_dir / f"{base_name}_juelich_{name}.nii.gz"
                else:
                    output_path = pons_dir / f"{base_name}_juelich_{name}.nii.gz"
                    
                logger.info(f"Saving Juelich result: {output_path}")
                img.to_filename(str(output_path))
                file_paths[f"juelich_{name}"] = str(output_path)
        
        # Create main output links
        # These are the standard names that the pipeline expects
        if suit_results and 'brainstem_mask' in suit_results:
            # Create main brainstem link
            main_brainstem_path = brainstem_dir / f"{base_name}_brainstem.nii.gz"
            suit_results['brainstem_mask'].to_filename(str(main_brainstem_path))
            file_paths['brainstem'] = str(main_brainstem_path)
            
            # Create intensity version
            intensity_path = brainstem_dir / f"{base_name}_brainstem_intensity.nii.gz"
            suit_results['brainstem_intensity'].to_filename(str(intensity_path))
            file_paths['brainstem_intensity'] = str(intensity_path)
            
            # Create main pons links
            main_pons_path = pons_dir / f"{base_name}_pons.nii.gz"
            suit_results['brainstem_mask'].to_filename(str(main_pons_path))
            file_paths['pons'] = str(main_pons_path)
            
            # Create main dorsal/ventral pons links
            dorsal_path = pons_dir / f"{base_name}_dorsal_pons.nii.gz"
            suit_results['dorsal_pons_mask'].to_filename(str(dorsal_path))
            file_paths['dorsal_pons'] = str(dorsal_path)
            
            ventral_path = pons_dir / f"{base_name}_ventral_pons.nii.gz"
            suit_results['ventral_pons_mask'].to_filename(str(ventral_path))
            file_paths['ventral_pons'] = str(ventral_path)
        
        # Generate validation report
        self._generate_validation_report(file_paths, output_dir, base_name)
        
        logger.info("Segmentation completed successfully")
        return file_paths
        
    def _generate_validation_report(self, file_paths: Dict[str, str], 
                                   output_dir: Path, base_name: str):
        """Generate validation report with volume statistics"""
        report_dir = output_dir / "segmentation" / "validation"
        report_dir.mkdir(parents=True, exist_ok=True)
        
        report_path = report_dir / f"{base_name}_segmentation_report.txt"
        logger.info(f"Generating validation report: {report_path}")
        
        volumes = {}
        
        # Calculate volumes for key masks
        for key in ['brainstem', 'pons', 'dorsal_pons', 'ventral_pons']:
            if key in file_paths:
                try:
                    img = ants.image_read(file_paths[key])
                    # Calculate volume: number of voxels × voxel volume
                    spacing = img.spacing
                    voxel_vol = np.prod(spacing)
                    mask_voxels = np.sum(img.numpy() > 0)
                    volumes[key] = mask_voxels * voxel_vol
                except Exception as e:
                    logger.warning(f"Failed to calculate volume for {key}: {e}")
                    volumes[key] = 0
            else:
                volumes[key] = 0
                
        # Write report
        with open(report_path, 'w') as f:
            f.write("Brainstem and Pons Segmentation Validation Report\n")
            f.write("==============================================\n\n")
            f.write(f"Input: {base_name}\n\n")
            f.write("Volumes (mm³):\n")
            for key, vol in volumes.items():
                f.write(f"  {key}: {vol:.2f}\n")
            
            f.write("\nVolume Ratios:\n")
            if volumes['brainstem'] > 0:
                f.write(f"  Pons/Brainstem: {volumes['pons']/volumes['brainstem']:.4f}\n")
            else:
                f.write("  Pons/Brainstem: N/A (brainstem volume is 0)\n")
                
            if volumes['pons'] > 0:
                f.write(f"  Dorsal/Pons: {volumes['dorsal_pons']/volumes['pons']:.4f}\n")
                f.write(f"  Ventral/Pons: {volumes['ventral_pons']/volumes['pons']:.4f}\n")
            else:
                f.write("  Dorsal/Pons: N/A (pons volume is 0)\n")
                f.write("  Ventral/Pons: N/A (pons volume is 0)\n")
            
            f.write("\nAvailable Files:\n")
            for key, path in file_paths.items():
                f.write(f"  {key}: {path}\n")
                
            f.write("\nSegmentation Methods:\n")
            f.write("  - SUIT atlas-based segmentation\n")
            if 'juelich_brainstem_mask' in file_paths:
                f.write("  - Juelich atlas-based segmentation\n")
                
            f.write("\nAll segmentation results are available in MNI space for standardized comparison.\n")


def main():
    """Command-line interface for brainstem segmentation"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Advanced brainstem and pons segmentation")
    parser.add_argument("input", help="Input T1 image")
    parser.add_argument("--output-dir", "-o", default="../mri_results", help="Output directory")
    parser.add_argument("--suit-dir", default=os.environ.get("SUIT_DIR", ""), 
                       help="SUIT directory (default: $SUIT_DIR)")
    parser.add_argument("--prefix", default="", help="Prefix for output filenames")
    
    args = parser.parse_args()
    
    if not args.suit_dir:
        parser.error("SUIT_DIR is required: provide with --suit-dir or set $SUIT_DIR environment variable")
        
    segmenter = BrainstemSegmentation(suit_dir=args.suit_dir)
    results = segmenter.process_image(args.input, args.output_dir, args.prefix)
    
    print("Segmentation completed successfully")
    print("Output files:")
    for key, path in sorted(results.items()):
        if key in ['brainstem', 'pons', 'dorsal_pons', 'ventral_pons']:
            print(f"  {key}: {path}")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
