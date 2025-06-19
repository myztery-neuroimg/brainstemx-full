#!/usr/bin/env python3
"""
Morphological Geodesic Active Contour Implementation
==================================================

This implements a proper morphological geodesic active contour for brain tissue
segmentation refinement, based on:
- Level set evolution
- Distance transform-based speed functions
- Edge-based stopping criteria
- Morphological operations for numerical stability

Author: BrainStemX Pipeline
"""

import numpy as np
import nibabel as nib
import scipy.ndimage as ndi
from scipy.ndimage import distance_transform_edt, gaussian_filter, binary_erosion, binary_dilation
from skimage.morphology import ball
from skimage.filters import gaussian
import argparse
import sys
import os


def compute_brainstem_edge_function(image, tissue_maps=None, atlas_region=None, sigma=1.0, k=1.0):
    """
    Compute edge function specifically optimized for brainstem tissue boundaries
    """
    # Base edge detection from image gradients
    smoothed = gaussian_filter(image.astype(np.float64), sigma=sigma)
    grad_x, grad_y, grad_z = np.gradient(smoothed)
    grad_magnitude = np.sqrt(grad_x**2 + grad_y**2 + grad_z**2)
    
    # Basic edge indicator function
    g_image = 1.0 / (1.0 + k * grad_magnitude**2)
    
    # If tissue maps available, enhance with tissue boundary information
    if tissue_maps is not None:
        # Create tissue boundary edges (important for brainstem structure)
        tissue_gradient = np.gradient(tissue_maps)
        tissue_mag = np.sqrt(sum(grad**2 for grad in tissue_gradient))
        g_tissue = 1.0 / (1.0 + 0.5 * tissue_mag**2)
        
        # Combine image and tissue edges
        g = 0.7 * g_image + 0.3 * g_tissue
    else:
        g = g_image
    
    # Enhance edges at atlas boundaries to prevent excessive expansion
    if atlas_region is not None:
        atlas_boundary = binary_dilation(atlas_region > 0) ^ (atlas_region > 0)
        edge_enhancement = np.where(atlas_boundary, 0.5, 1.0)  # Stronger edges at atlas boundary
        g = g * edge_enhancement
    
    # Ensure minimum edge strength to prevent runaway evolution
    return np.clip(g, 0.1, 1.0)


def compute_atlas_guided_speed_function(phi, g, atlas_constraint=None, tissue_region=None, 
                                       image_intensities=None, alpha=1.0, beta=1.0):
    """
    Compute atlas-guided speed function for brainstem segmentation:
    F = g(α + β*κ) * tissue_affinity * distance_regulation
    """
    # Approximate mean curvature using morphological operations
    # This is a simplified but computationally efficient approach
    
    # Get gradient of level set function
    grad_x, grad_y, grad_z = np.gradient(phi)
    grad_magnitude = np.sqrt(grad_x**2 + grad_y**2 + grad_z**2 + 1e-8)
    
    # Normalized gradient
    nx = grad_x / grad_magnitude
    ny = grad_y / grad_magnitude  
    nz = grad_z / grad_magnitude
    
    # Approximate curvature as divergence of normalized gradient
    curvature = np.gradient(nx)[0] + np.gradient(ny)[1] + np.gradient(nz)[2]
    
    # Base speed function
    base_speed = g * (alpha + beta * curvature)
    
    # Atlas-guided modifications
    if atlas_constraint is not None and tissue_region is not None:
        # Distance-based regulation - slower speed farther from atlas
        distance_from_atlas = distance_transform_edt(~(atlas_constraint > 0))
        distance_regulation = np.exp(-distance_from_atlas / 3.0)  # 3mm decay
        
        # Tissue preference (encourage growth in tissue vs background)
        tissue_preference = np.where(tissue_region > 0, 1.0, 0.1)
        
        # Intensity consistency if available
        if image_intensities is not None:
            current_mask = phi > 0
            if np.sum(current_mask) > 10:  # Ensure sufficient sample
                region_intensities = image_intensities[current_mask]
                mean_intensity = np.mean(region_intensities)
                std_intensity = np.std(region_intensities) + 1e-6
                
                # Favor regions with similar intensities
                intensity_similarity = np.exp(-0.5 * ((image_intensities - mean_intensity) / std_intensity)**2)
            else:
                intensity_similarity = 1.0
        else:
            intensity_similarity = 1.0
        
        # Combined speed function with all constraints
        speed = base_speed * distance_regulation * tissue_preference * intensity_similarity
    else:
        speed = base_speed
    
    return speed


def atlas_guided_morphological_geodesic_active_contour(image, initial_mask, tissue_region, 
                                                      atlas_constraint=None, num_iterations=10, 
                                                      sigma=1.0, k=1.0, alpha=0.1, beta=0, dt=0.1):
    """
    Atlas-guided morphological implementation of geodesic active contour
    
    Parameters:
    -----------
    image : ndarray
        Input image (e.g., T1 or tissue probability map)
    initial_mask : ndarray
        Initial binary mask (seed region)
    tissue_region : ndarray
        Tissue constraint region
    atlas_constraint : ndarray
        Original atlas mask for boundary constraints
    num_iterations : int
        Number of evolution iterations
    sigma : float
        Gaussian smoothing parameter for edge detection
    k : float
        Edge sensitivity parameter
    alpha : float
        Constant speed term weight
    beta : float
        Curvature term weight
    dt : float
        Time step for evolution
    
    Returns:
    --------
    final_mask : ndarray
        Evolved binary mask
    """
    print("Starting atlas-guided morphological geodesic active contour evolution...")
    print(f"Parameters: sigma={sigma}, k={k}, alpha={alpha}, beta={beta}, dt={dt}")
    
    # Validate atlas constraint
    if atlas_constraint is not None:
        atlas_volume = np.sum(atlas_constraint > 0)
        print(f"Atlas constraint: {atlas_volume} voxels")
    else:
        print("No atlas constraint provided")
    
    # Initialize level set function as signed distance transform
    phi = np.where(initial_mask > 0, 1, -1).astype(np.float64)
    phi = distance_transform_edt(phi < 0) - distance_transform_edt(phi >= 0)
    
    # Compute brainstem-specific edge function
    print(f"Computing brainstem-optimized edge function...")
    g = compute_brainstem_edge_function(image, tissue_maps=tissue_region, 
                                      atlas_region=atlas_constraint, sigma=sigma, k=k)
    
    # Evolution iterations
    for iteration in range(num_iterations):
        print(f"Iteration {iteration + 1}/{num_iterations}")
        
        # Compute atlas-guided speed function
        speed = compute_atlas_guided_speed_function(phi, g, atlas_constraint=atlas_constraint, 
                                                   tissue_region=tissue_region, 
                                                   image_intensities=image, 
                                                   alpha=alpha, beta=beta)
        
        # Morphological evolution step
        # Forward differences for upwind scheme approximation
        phi_x_plus = np.roll(phi, -1, axis=0) - phi
        phi_x_minus = phi - np.roll(phi, 1, axis=0)
        phi_y_plus = np.roll(phi, -1, axis=1) - phi
        phi_y_minus = phi - np.roll(phi, 1, axis=1)
        phi_z_plus = np.roll(phi, -1, axis=2) - phi
        phi_z_minus = phi - np.roll(phi, 1, axis=2)
        
        # Upwind scheme for gradient magnitude
        grad_mag_plus = np.sqrt(
            np.maximum(phi_x_minus, 0)**2 + np.minimum(phi_x_plus, 0)**2 +
            np.maximum(phi_y_minus, 0)**2 + np.minimum(phi_y_plus, 0)**2 +
            np.maximum(phi_z_minus, 0)**2 + np.minimum(phi_z_plus, 0)**2
        )
        
        grad_mag_minus = np.sqrt(
            np.minimum(phi_x_minus, 0)**2 + np.maximum(phi_x_plus, 0)**2 +
            np.minimum(phi_y_minus, 0)**2 + np.maximum(phi_y_plus, 0)**2 +
            np.minimum(phi_z_minus, 0)**2 + np.maximum(phi_z_plus, 0)**2
        )
        
        # Evolution equation: ∂φ/∂t = g*|∇φ|*(α + β*κ)
        evolution = np.where(speed > 0, 
                           speed * grad_mag_plus,
                           speed * grad_mag_minus)
        
        # Update level set function
        phi_new = phi + dt * evolution
        
        # Apply multiple levels of constraints
        current_mask = phi_new > 0
        
        # Level 1: Tissue constraint (soft)
        tissue_constrained = current_mask & (tissue_region > 0)
        
        # Level 2: Atlas constraint (hard boundary - never expand beyond 2mm from atlas)
        if atlas_constraint is not None:
            atlas_dilated = binary_dilation(atlas_constraint > 0, ball(2))  # 2mm expansion limit
            atlas_constrained = tissue_constrained & atlas_dilated
        else:
            atlas_constrained = tissue_constrained
        
        # Update phi based on hierarchical constraints
        phi = np.where(atlas_constrained, 
                      np.abs(phi_new), 
                      -np.abs(phi_new))
        
        # Reinitialize as signed distance function every few iterations
        if (iteration + 1) % 3 == 0:
            phi = distance_transform_edt(phi < 0) - distance_transform_edt(phi >= 0)
        
        # Compute current mask volume
        current_volume = np.sum(phi > 0)
        print(f"  Current volume: {current_volume} voxels")
        
        # Check for convergence and quality
        if iteration > 0:
            volume_change = abs(current_volume - previous_volume)
            if volume_change < 5:  # Tighter convergence for stability
                print(f"  Converged at iteration {iteration + 1} (volume change: {volume_change})")
                break
            
            # Safety check: prevent excessive growth
            if atlas_constraint is not None:
                atlas_volume = np.sum(atlas_constraint > 0)
                if current_volume > 2 * atlas_volume:  # Never grow more than 2x atlas size
                    print(f"  Stopping evolution: excessive growth detected")
                    break
        
        previous_volume = current_volume
    
    # Final binary mask
    final_mask = (phi > 0).astype(np.uint8)
    
    print(f"Evolution complete. Final volume: {np.sum(final_mask)} voxels")
    
    return final_mask


def validate_inputs(image, initial_mask, tissue_region):
    """Validate input arrays have compatible shapes and data types"""
    if image.shape != initial_mask.shape or image.shape != tissue_region.shape:
        raise ValueError(f"Shape mismatch: image {image.shape}, mask {initial_mask.shape}, tissue {tissue_region.shape}")
    
    if not np.any(initial_mask > 0):
        raise ValueError("Initial mask is empty")
    
    if not np.any(tissue_region > 0):
        raise ValueError("Tissue region is empty")
    
    if np.sum(initial_mask > 0) < 10:
        raise ValueError(f"Initial mask too small: {np.sum(initial_mask > 0)} voxels")
        
    print(f"Input validation passed:")
    print(f"  Image shape: {image.shape}")
    print(f"  Image range: [{np.min(image):.2f}, {np.max(image):.2f}]")
    print(f"  Initial mask: {np.sum(initial_mask > 0)} voxels")
    print(f"  Tissue region: {np.sum(tissue_region > 0)} voxels")


def main():
    parser = argparse.ArgumentParser(description='Atlas-Guided Morphological Geodesic Active Contour')
    parser.add_argument('input_image', help='Input image (T1, probability map, etc.)')
    parser.add_argument('initial_mask', help='Initial binary mask (seed region)')
    parser.add_argument('tissue_region', help='Tissue constraint region')
    parser.add_argument('output_mask', help='Output refined mask')
    parser.add_argument('--atlas_constraint', help='Original atlas mask for boundary constraints')
    parser.add_argument('--iterations', type=int, default=10, help='Number of iterations')
    parser.add_argument('--sigma', type=float, default=1.5, help='Edge detection smoothing')
    parser.add_argument('--k', type=float, default=2.0, help='Edge sensitivity')
    parser.add_argument('--alpha', type=float, default=0.02, help='Constant speed weight')
    parser.add_argument('--beta', type=float, default=0.1, help='Curvature weight')
    parser.add_argument('--dt', type=float, default=0.05, help='Time step')
    
    args = parser.parse_args()
    
    try:
        # Load input files
        print(f"Loading input files...")
        image_nii = nib.load(args.input_image)
        initial_mask_nii = nib.load(args.initial_mask)
        tissue_region_nii = nib.load(args.tissue_region)
        
        # Get data arrays
        image = image_nii.get_fdata()
        initial_mask = initial_mask_nii.get_fdata()
        tissue_region = tissue_region_nii.get_fdata()
        
        # Load atlas constraint if provided
        atlas_constraint = None
        if args.atlas_constraint:
            atlas_constraint_nii = nib.load(args.atlas_constraint)
            atlas_constraint = atlas_constraint_nii.get_fdata()
            print(f"Loaded atlas constraint: {args.atlas_constraint}")
        
        # Validate inputs
        validate_inputs(image, initial_mask, tissue_region)
        if atlas_constraint is not None:
            if atlas_constraint.shape != image.shape:
                raise ValueError(f"Atlas constraint shape mismatch: {atlas_constraint.shape} vs {image.shape}")
        
        # Run atlas-guided morphological geodesic active contour
        refined_mask = atlas_guided_morphological_geodesic_active_contour(
            image=image,
            initial_mask=initial_mask,
            tissue_region=tissue_region,
            atlas_constraint=atlas_constraint,
            num_iterations=args.iterations,
            sigma=args.sigma,
            k=args.k,
            alpha=args.alpha,
            beta=args.beta,
            dt=args.dt
        )
        
        # Save output
        print(f"Saving refined mask to: {args.output_mask}")
        output_nii = nib.Nifti1Image(refined_mask, image_nii.affine, image_nii.header)
        nib.save(output_nii, args.output_mask)
        
        # Report final statistics
        initial_volume = np.sum(initial_mask > 0)
        refined_volume = np.sum(refined_mask > 0)
        overlap = np.sum((initial_mask > 0) & (refined_mask > 0))
        
        print(f"\nFinal Results:")
        print(f"  Initial volume: {initial_volume} voxels")
        print(f"  Refined volume: {refined_volume} voxels")
        print(f"  Volume change: {refined_volume - initial_volume} voxels ({100*(refined_volume - initial_volume)/initial_volume:.1f}%)")
        print(f"  Overlap: {overlap} voxels")
        print(f"  Dice coefficient: {2*overlap/(initial_volume + refined_volume):.3f}")
        
        # Validate output quality
        if atlas_constraint is not None:
            initial_atlas_volume = np.sum(atlas_constraint > 0)
            refined_volume = np.sum(refined_mask > 0)
            overlap_with_atlas = np.sum((refined_mask > 0) & (atlas_constraint > 0))
            
            # Quality checks
            if refined_volume > 2 * initial_atlas_volume:
                print(f"WARNING: Refined mask is unusually large ({refined_volume} vs {initial_atlas_volume} atlas voxels)")
            
            if overlap_with_atlas < 0.5 * initial_atlas_volume:
                print(f"WARNING: Poor overlap with original atlas ({overlap_with_atlas} / {initial_atlas_volume})")
        
        print(f"Atlas-guided morphological geodesic active contour completed successfully!")
        
    except Exception as e:
        print(f"ERROR: {str(e)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()