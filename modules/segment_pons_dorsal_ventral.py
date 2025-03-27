import numpy as np
from sklearn.decomposition import PCA


def structure_only_pons_division(pons_mask):
    """
    Divides pons into dorsal and ventral regions using only structural coordinates,
    with no dependency on intensity values that could be affected by pathology.
    """
    # 1. Extract pons coordinates in 3D space
    coords = np.array(np.where(pons_mask > 0)).T
    
    # 2. Apply PCA to determine principal anatomical axes
    pca = PCA(n_components=3)
    pca.fit(coords)
    principal_axes = pca.components_
    
    # 3. Calculate centroid of pons
    centroid = np.mean(coords, axis=0)
    
    # 4. Create reference coordinate system aligned with pons orientation
    # Using exclusively the shape, not intensity properties
    ap_axis = principal_axes[0]  # Anterior-posterior (typically longest axis)
    si_axis = principal_axes[1]  # Superior-inferior
    ml_axis = principal_axes[2]  # Medial-lateral
    
    # 5. Project all coordinates onto the superior-inferior axis
    # This gives us the relative position along the dorsal-ventral dimension
    si_projections = np.dot(coords - centroid, si_axis)
    
    # 6. Use a fixed proportional division at 45% from the ventral end
    # This ratio can be justified based on neuroanatomical literature
    # rather than derived from the specific scan
    threshold_value = np.percentile(si_projections, 45)
    
    # 7. Create masks based on this fixed proportional division
    dorsal_mask = np.zeros_like(pons_mask)
    ventral_mask = np.zeros_like(pons_mask)
    
    for i, point in enumerate(coords):
        if si_projections[i] < threshold_value:
            ventral_mask[tuple(point)] = 1
        else:
            dorsal_mask[tuple(point)] = 1
    
    return dorsal_mask, ventral_mask, principal_axes, centroid

if __name__ == "__main__":
    # 8. Apply the function to a sample pons mask
    pons_mask = np.zeros((10, 10, 10))
    pons_mask[3:7, 3:7, 3:7] = 1
    dorsal_mask, ventral_mask, principal_axes, centroid = structure_only_pons_division(pons_mask)
