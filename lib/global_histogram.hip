#include <hip/amd_detail/amd_hip_atomic.h>
#include <hip/amd_detail/amd_warp_sync_functions.h>
#include <hip/hip_runtime.h>

#define BITS_PER_PASS           8
#define BUCKETS                 (1 << BITS_PER_PASS) // 2^8

#define WAVES                   8
#define TOTAL_PASSES            (32 / BITS_PER_PASS) // 32 but uint's
#define KEYS_PER_WAVE           128
#define KEYS_PER_THREAD         4
#define KEYS_PER_BLOCK          1024
#define THREADS_PER_WAVE        32

__global__ void 
hist_gen(
    const uint32_t* __restrict__ d_keys,
          uint32_t               nmem,
          uint32_t* __restrict__ global_histogram
) {
    size_t thread_id   =   threadIdx.x;
    size_t wave_id     =   thread_id / THREADS_PER_WAVE;
    size_t block_id    =   blockIdx.x;
    size_t lane        =   thread_id % THREADS_PER_WAVE;

    // wave local histograms for 16 buckets
    __shared__ uint32_t block_histogram[WAVES][TOTAL_PASSES][BUCKETS];

    // clear out the local histogram
    for(uint32_t i = 0; i < 32; ++i) {
        ((uint32_t*)block_histogram)[thread_id + i * 256] = 0;
    }
    __syncthreads();

    uint32_t wave_offset = block_id * KEYS_PER_BLOCK + wave_id * KEYS_PER_WAVE;
    #pragma unroll
    for(uint32_t i = 0; i < KEYS_PER_THREAD; ++i) {

        uint32_t key_index = wave_offset + (i * THREADS_PER_WAVE) + lane;
        if (key_index < nmem) {

            uint32_t key = d_keys[key_index];
            #pragma unroll
            for(uint32_t pass = 0; pass < TOTAL_PASSES; ++pass) {
                uint32_t key_digit = (key >> (pass * BITS_PER_PASS)) & (BUCKETS - 1);
                atomicAdd(&block_histogram[wave_id][pass][key_digit], 1u);
            }
        }
    }
    __syncthreads();

    #pragma unroll
    for(uint32_t pass = 0; pass < TOTAL_PASSES; ++pass) {

        uint32_t digit = thread_id; // because block size (256) = bucket size
        uint32_t sum = 0;

        #pragma unroll
        for(uint32_t wave = 0; wave < WAVES; ++wave) {
            sum += block_histogram[wave][pass][digit];
        }

        atomicAdd(&global_histogram[pass * BUCKETS + digit], sum);
    }
}