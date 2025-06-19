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


def compute_edge_indicator_function(image, sigma=1.0, k=1.0):
    """
    Compute edge indicator function g(x) = 1/(1 + k*|∇G_σ * I|²)
    where G_σ is Gaussian kernel with standard deviation σ
    """
    # Smooth image with Gaussian
    smoothed = gaussian_filter(image.astype(np.float64), sigma=sigma)
    
    # Compute gradient magnitude
    grad_x, grad_y, grad_z = np.gradient(smoothed)
    grad_magnitude = np.sqrt(grad_x**2 + grad_y**2 + grad_z**2)
    
    # Edge indicator function
    g = 1.0 / (1.0 + k * grad_magnitude**2)
    
    return g


def compute_speed_function(phi, g, alpha=1.0, beta=1.0):
    """
    Compute speed function for geodesic active contour:
    F = g(α + β*κ) where κ is mean curvature
    
    For morphological implementation, we approximate curvature
    using the divergence of the normalized gradient
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
    
    # Speed function
    speed = g * (alpha + beta * curvature)
    
    return speed


def morphological_geodesic_active_contour(image, initial_mask, tissue_region, 
                                        num_iterations=10, sigma=1.0, k=1.0, 
                                        alpha=0.1, beta=0, dt=0.1):
    """
    Morphological implementation of geodesic active contour
    
    Parameters:
    -----------
    image : ndarray
        Input image (e.g., T1 or tissue probability map)
    initial_mask : ndarray
        Initial binary mask
    tissue_region : ndarray
        Constraint region (e.g., tissue segmentation)
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
    print("Starting morphological geodesic active contour evolution...")
    print(f"Parameters: sigma={sigma}, k={k}, alpha={alpha}, beta={beta}, dt={dt}")
    
    # Initialize level set function as signed distance transform
    phi = np.where(initial_mask > 0, 1, -1).astype(np.float64)
    phi = distance_transform_edt(phi < 0) - distance_transform_edt(phi >= 0)
    
    # Compute edge indicator function
    print(f"Computing edge indicator function...")
    g = compute_edge_indicator_function(image, sigma=sigma, k=k)
    
    # Evolution iterations
    for iteration in range(num_iterations):
        print(f"Iteration {iteration + 1}/{num_iterations}")
        
        # Compute speed function
        speed = compute_speed_function(phi, g, alpha=alpha, beta=beta)
        
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
        
        # Constrain to tissue region (geodesic constraint)
        current_mask = phi_new > 0
        constrained_mask = current_mask & (tissue_region > 0)
        
        # Update phi based on constraint
        phi = np.where(constrained_mask, 
                      np.abs(phi_new), 
                      -np.abs(phi_new))
        
        # Reinitialize as signed distance function every few iterations
        if (iteration + 1) % 3 == 0:
            phi = distance_transform_edt(phi < 0) - distance_transform_edt(phi >= 0)
        
        # Compute current mask volume
        current_volume = np.sum(phi > 0)
        print(f"  Current volume: {current_volume} voxels")
        
        # Check for convergence (optional)
        if iteration > 0 and abs(current_volume - previous_volume) < 10:
            print(f"  Converged at iteration {iteration + 1}")
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
    parser = argparse.ArgumentParser(description='Morphological Geodesic Active Contour')
    parser.add_argument('input_image', help='Input image (T1, probability map, etc.)')
    parser.add_argument('initial_mask', help='Initial binary mask')
    parser.add_argument('tissue_region', help='Tissue constraint region')
    parser.add_argument('output_mask', help='Output refined mask')
    parser.add_argument('--iterations', type=int, default=10, help='Number of iterations')
    parser.add_argument('--sigma', type=float, default=2.0, help='Edge detection smoothing')
    parser.add_argument('--k', type=float, default=1.0, help='Edge sensitivity')
    parser.add_argument('--alpha', type=float, default=0.1, help='Constant speed weight')
    parser.add_argument('--beta', type=float, default=0.1, help='Curvature weight')
    parser.add_argument('--dt', type=float, default=0.5, help='Time step')
    
    args = parser.parse_args()
    
    try:
        # Load input files
        print(f"Loading input files...")
        image_nii = nib.load(args.input_image)
        initial_mask_nii = nib.load(args.initial_mask)
        tissue_region_nii = nib.load(args.tissue_region)
        
        # Get data arrays
        image = image_nii.get_fdata()
        #initial_mask = initial_mask_nii.get_fdata()
        tissue_region = tissue_region_nii.get_fdata()
        initial_mask = initial_mask_nii.get_fdata()
        # Validate inputs
        validate_inputs(image, initial_mask, tissue_region)
        
        # Run morphological geodesic active contour
        refined_mask = morphological_geodesic_active_contour(
            image=image,
            initial_mask=initial_mask,
            tissue_region=tissue_region,
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
        
        print(f"Morphological geodesic active contour completed successfully!")
        
    except Exception as e:
        print(f"ERROR: {str(e)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()