#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 0

/*******************************************************************
* GBUFFER_RENDER 0 for gbufferToPBO to render intersects as color
* GBUFFER_RENDER 1 for gbufferToPBO to render positions as color
* GBUFFER_RENDER 2 for gbufferToPBO to render normals as color
*******************************************************************/
#define GBUFFER_RENDER 0

/*******************************************************************
* BLOCK_LENGTH  is 1D lenght of blocks per grid
*******************************************************************/
#define BLOCK_LENGTH  8
// TODO: update this to be variable length given FILTER_LENGTH
const float gaussian[25] = {
    0.003765, 0.015019, 0.023792, 0.015019, 0.003765,
    0.015019, 0.059912, 0.094907, 0.059912, 0.015019,
    0.023792, 0.094907, 0.150342, 0.094907, 0.023792,
    0.015019, 0.059912, 0.094907, 0.059912, 0.015019,
    0.003765, 0.015019, 0.023792, 0.015019, 0.003765 };

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution, int iter, glm::vec3* image) 
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

__global__ void gbufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);

#if   GBUFFER_RENDER == 0
        // Intersect 
        float timeToIntersect = gBuffer[index].t * 255.f;
        pbo[index].w = 0;
        pbo[index].x = timeToIntersect;
        pbo[index].y = timeToIntersect;
        pbo[index].z = timeToIntersect;
#elif GBUFFER_RENDER == 1
        glm::vec4 posToColor = glm::vec4(glm::normalize(glm::abs(gBuffer[index].pos)) * 255.f, 0.f);
        pbo[index].w = posToColor.w;
        pbo[index].x = posToColor.x;
        pbo[index].y = posToColor.y;
        pbo[index].z = posToColor.z;
#elif GBUFFER_RENDER == 2
        glm::vec4 norToColor = glm::vec4(glm::normalize(glm::abs(gBuffer[index].nor)) * 255.f, 0.f);
        pbo[index].w = norToColor.w;
        pbo[index].x = norToColor.x;
        pbo[index].y = norToColor.y;
        pbo[index].z = norToColor.z;
#endif // GBUFFER_RENDER 
    }
}

static Scene* hst_scene = NULL;
static glm::vec3* dev_image = NULL;
static glm::vec3* dev_imageDenoise = NULL; 
static glm::vec3* dev_imageDenoiseDup = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;
static GBufferPixel* dev_gBuffer = NULL;
static float* dev_gaussian = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...

void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

    cudaMalloc(&dev_imageDenoise, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_imageDenoise, 0, pixelcount * sizeof(glm::vec3));

    cudaMalloc(&dev_imageDenoiseDup, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_imageDenoiseDup, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

  	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
  	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));

    cudaMalloc(&dev_gaussian, 25 * sizeof(float));
    cudaMemcpy(dev_gaussian, gaussian, 25 * sizeof(float), cudaMemcpyHostToDevice);

    // TODO: initialize any extra device memeory you need

    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
    cudaFree(dev_imageDenoise);
    cudaFree(dev_imageDenoiseDup);
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
    cudaFree(dev_gBuffer);
    cudaFree(dev_gaussian);
    // TODO: clean up any extra device memory you created

    checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

        thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
        thrust::uniform_real_distribution<float> uhh(-0.5f, 0.5f);

		segment.ray.origin = cam.position;
        segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

        segment.ray.direction = glm::normalize(
            cam.view -
            cam.right * cam.pixelLength.x * ((float)x + uhh(rng) - (float)cam.resolution.x * 0.5f) -
            cam.up * cam.pixelLength.y * ((float)y + uhh(rng) - (float)cam.resolution.y * 0.5f));

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

__global__ void computeIntersections(
	int depth, 
    int num_paths, 
    PathSegment * pathSegments,
    Geom * geoms, 
    int geoms_size, 
    ShadeableIntersection * intersections)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

__global__ void shadeSimpleMaterials (
    int iter, 
    int num_paths, 
    ShadeableIntersection * shadeableIntersections, 
    PathSegment * pathSegments, 
    Material * materials)
{
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    ShadeableIntersection intersection = shadeableIntersections[idx];
    PathSegment segment = pathSegments[idx];
    if (segment.remainingBounces == 0) {
      return;
    }

    if (intersection.t > 0.0f) { // if the intersection exists...
      segment.remainingBounces--;
      // Set up the RNG
      thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, segment.remainingBounces);

      Material material = materials[intersection.materialId];
      glm::vec3 materialColor = material.color;

      // If the material indicates that the object was a light, "light" the ray
      if (material.emittance > 0.0f) {
        segment.color *= (materialColor * material.emittance);
        segment.remainingBounces = 0;
      }
      else {
        glm::vec3 intersectPos = intersection.t * segment.ray.direction + segment.ray.origin;
        scatterRay(segment, intersectPos, intersection.surfaceNormal, material, rng);
      }
    // If there was no intersection, color the ray black.
    // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
    // used for opacity, in which case they can indicate "no opacity".
    // This can be useful for post-processing and image compositing.
    } else {
      segment.color = glm::vec3(0.0f);
      segment.remainingBounces = 0;
    }

    pathSegments[idx] = segment;
  }
}

__global__ void generateGBuffer (
    int num_paths,
    ShadeableIntersection* shadeableIntersections,
    PathSegment* pathSegments,
    GBufferPixel* gBuffer) 
{
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < num_paths)
    {
        ShadeableIntersection& i = shadeableIntersections[index];
        Ray&                   r = pathSegments[index].ray;

        gBuffer[index].t   = i.t;
        gBuffer[index].pos = r.origin + i.t * r.direction;
        gBuffer[index].nor = i.surfaceNormal;

    }
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}

    //showImage(uchar4 * pbo, int iter, bool ui_denoise)
}
    
/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
int pathtrace(int frame, int iter, int lastIter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

    ///////////////////////////////////////////////////////////////////////////

    // Pathtracing Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * NEW: For the first depth, generate geometry buffers (gbuffers)
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally:
    //     * if not denoising, add this iteration's results to the image
    //     * TODO: if denoising, run kernels that take both the raw pathtraced result and the gbuffer, and put the result in the "pbo" from opengl

    generateRayFromCamera <<<blocksPerGrid2d, blockSize2d >>>(cam, iter, traceDepth, dev_paths);
    checkCUDAError("generate camera ray");

    int depth = 0;
    PathSegment* dev_path_end = dev_paths + pixelcount;
    int num_paths = dev_path_end - dev_paths;
    int ret = (lastIter) ? num_paths : -1; 

    // --- PathSegment Tracing Stage ---
    // Shoot ray into scene, bounce between objects, push shading chunks

    // Empty gbuffer
    cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

    // clean shading chunks
    cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    bool iterationComplete = false;
	while (!iterationComplete) {

	    dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
	    computeIntersections <<<numblocksPathSegmentTracing, blockSize1d>>> (
		    depth, 
            num_paths, 
            dev_paths, 
            dev_geoms, 
            hst_scene->geoms.size(), 
            dev_intersections);
	    checkCUDAError("trace one bounce");
	    cudaDeviceSynchronize();

        if (depth == 0 && lastIter) {
            generateGBuffer<<<numblocksPathSegmentTracing, blockSize1d>>>(num_paths, dev_intersections, dev_paths, dev_gBuffer);
        }
        depth++;

        shadeSimpleMaterials<<<numblocksPathSegmentTracing, blockSize1d>>> (
            iter,
            num_paths,
            dev_intersections,
            dev_paths,
            dev_materials);
        iterationComplete = depth == traceDepth;

	}

    // Assemble this iteration and apply it to the image
    dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
    finalGather<<<numBlocksPixels, blockSize1d>>>(num_paths, dev_image, dev_paths);
    ///////////////////////////////////////////////////////////////////////////

    // CHECKITOUT: use dev_image as reference if you want to implement saving denoised images.
    // Otherwise, screenshots are also acceptable.
    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("pathtrace");
    cudaDeviceSynchronize();
    return ret;
}

// CHECKITOUT: this kernel "post-processes" the gbuffer/gbuffers into something that you can visualize for debugging.
void showGBuffer(uchar4* pbo) {
    const Camera &cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // CHECKITOUT: process the gbuffer results and send them to OpenGL buffer for visualization
    gbufferToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, dev_gBuffer);
}

void showImage(uchar4* pbo, int iter, bool ui_denoise) {
const Camera &cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // Send results to OpenGL buffer for rendering
    if (ui_denoise) {
        sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_imageDenoise);
    }
    else {
        sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);
    }
}

__global__ void denoiseIter(
    const Camera cam,
    const int step, 
    const float c_phi, 
    const float p_phi,
    const float n_phi,
    const float* gaussian, 
    glm::vec3* imageDenoise, 
    const glm::vec3* image, 
    const GBufferPixel* gBuffer) 
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < cam.resolution.x && y < cam.resolution.y) {

        glm::vec3 sumColor = glm::vec3(0.f);
        float     sumWeight = 0.f;

        int index = x + (y * cam.resolution.x);

        glm::vec3 col = image[index];
        glm::vec3 pos = gBuffer[index].pos;
        glm::vec3 nor = gBuffer[index].nor;

        for (int j = -2; j <= 2; j++) {

            //int relY = glm::clamp(y + j * step, 0, cam.resolution.y);
            int relY = y + j * step; 
            if (relY < 0 || relY >= cam.resolution.y) continue;

            for (int i = -2; i <= 2; i++) {

                //int relX = glm::clamp(x + i * step, 0, cam.resolution.x);
                int relX = x + i * step;
                if (relX < 0 || relX >= cam.resolution.x) continue;

                int relIndex = relX + cam.resolution.x * relY;

                glm::vec3 t; glm::vec3 colTemp; float dist2;
                // Color weighting
                colTemp = image[relIndex];
                t = col - colTemp;
                dist2 = glm::dot(t, t);
                float c_w = glm::min(std::exp(-(dist2) / (c_phi + EPSILON)), 1.f);

                // Position weighting  
                t = pos - gBuffer[relIndex].pos;
                dist2 = glm::dot(t, t);
                float p_w = glm::min(std::exp(-(dist2) / (p_phi + EPSILON)), 1.f);

                // Normal weighting 
                t = nor - gBuffer[relIndex].nor;
                dist2 = glm::max(glm::dot(t, t), 0.f);
                float n_w = glm::min(std::exp(-(dist2) / (n_phi + EPSILON)), 1.f);

                //float weight = c_w * c_w * p_w * p_w * n_w * n_w;
                float weight =  c_w * p_w * n_w;
                float influence = weight * gaussian[((i + 2) + 5 * (j + 2))];
                sumColor  += (colTemp * influence);
                sumWeight += influence;
            }
        }

        imageDenoise[index] = sumColor / sumWeight;

    }
}

void denoise(const int filterSize, const float cPhi, const float pPhi, const float nPhi) {

    if (filterSize < 25) return; 
    
    const Camera& cam = hst_scene->state.camera;

    const dim3 blockSize2d(BLOCK_LENGTH, BLOCK_LENGTH);
    const dim3 blocksPerGrid2d(
        (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
        (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    cudaMemcpy(dev_imageDenoiseDup, dev_image, cam.resolution.x * cam.resolution.y * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);

    for (int step = 1; step <= std::floor(std::sqrt(filterSize)); step++) {
        denoiseIter << <blocksPerGrid2d, blockSize2d >> > (cam, 1 << step, cPhi, pPhi, nPhi, dev_gaussian, dev_imageDenoise, dev_imageDenoiseDup, dev_gBuffer);
        std::swap(dev_imageDenoise, dev_imageDenoiseDup);
    }
    cudaDeviceSynchronize(); 
}   