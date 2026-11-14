#include "onesweep.hpp"


#include <chrono>
#include <hip/amd_detail/amd_hip_atomic.h>
#include <hip/amd_detail/amd_hip_runtime.h>
#include <hip/amd_detail/amd_warp_sync_functions.h>
#include <hip/amd_detail/amd_device_functions.h>
#include <rocprim/device/device_radix_sort.hpp>
#include <rocprim/rocprim.hpp>
#include <hip/hip_runtime.h>
#include <iostream>

#define HIP_CHECK(cmd)                                                   \
    do {                                                                 \
        hipError_t err = cmd;                                            \
        if (err != HIP_SUCCESS) {                                        \
            std::cerr << "HIP Error: " << hipGetErrorString(err)         \
                      << " at " << __FILE__ << ": " << __LINE__ << "\n"; \
            exit(1);                                                     \
        }                                                                \
    } while (0)                                     

namespace OnesweepRadixSort {

__global__ void 
GlobalHistogram(
    const uint32_t* __restrict__ d_keys,
          uint32_t* __restrict__ global_histogram,
          uint32_t               nmem
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

__global__ void
GlobalHistogramScan(
    uint32_t* __restrict__ global_histogram
) {
    // each block handles its pass and a single block handles every bucket in that pass

    if (blockIdx.x >= TOTAL_PASSES || threadIdx.x >= BUCKETS) { 
        return;
    }

    __shared__ uint32_t scan[BUCKETS];

    size_t block_id = blockIdx.x;
    size_t thread_id = threadIdx.x;

    uint32_t own_count = global_histogram[block_id * BUCKETS + thread_id];
    scan[thread_id] = own_count;
    __syncthreads();

    for(uint32_t offset = 1; offset < BUCKETS; offset <<= 1) {
        uint32_t sum = (thread_id >= offset) ? scan[thread_id - offset] : 0;
        __syncthreads();
        scan[thread_id] += sum;
        __syncthreads();
    }

    global_histogram[block_id * BUCKETS + thread_id] = scan[thread_id] - own_count;
}

__global__ void
Bin(
          uint32_t* __restrict__ block_data, // bits 0-1 -> status, 2-31 -> value
          uint32_t* __restrict__ d_keys_out,
    const uint32_t* __restrict__ d_keys_in,
    const uint32_t* __restrict__ global_histogram,
    const uint32_t               nmem,
    const uint32_t               pass
) {
    size_t thread_id =   threadIdx.x;
    size_t wave_id   =   thread_id / THREADS_PER_WAVE;
    size_t block_id  =   blockIdx.x;
    size_t lane      =   threadIdx.x % 32;
    // 0xFF
    constexpr uint32_t BIT_MASK = (1 << BITS_PER_PASS) - 1;

    uint32_t keys[KEYS_PER_THREAD] = {};
    uint32_t digits[KEYS_PER_THREAD];
    uint32_t ranks[KEYS_PER_THREAD];

    // block local histogram accross all 8 waves
    __shared__ uint32_t block_histogram[WAVES][BUCKETS];
    for (uint32_t wave = 0; wave < WAVES; ++wave) {
        block_histogram[wave][thread_id] = 0;
    }
    __syncthreads();

    // wave prefix to store local wave ranks
    __shared__ uint32_t wave_prefix[WAVES][BUCKETS];

    // ---------------------------------
    // ----- BLOCK LOCAL HISTOGRAM -----
    // ---------------------------------

    size_t wave_offset = block_id * KEYS_PER_BLOCK + wave_id * KEYS_PER_WAVE;

    #pragma unroll
    for (uint32_t i = 0; i < KEYS_PER_THREAD; ++i) {
        size_t key_index = wave_offset + i * THREADS_PER_WAVE + lane;

        if (key_index < nmem) {
            keys[i]                        = d_keys_in[key_index];
            digits[i]                      = (keys[i] >> (pass * BITS_PER_PASS)) & BIT_MASK;

            unsigned long long mask        = __activemask();
            unsigned long long peer_mask   = __ballot(1);          // active (valid) lanes
            #pragma unroll
            for (int b = 0; b < BITS_PER_PASS; ++b) {
                bool bit                   = (digits[i] >> b) & 1;
                unsigned long long bal     = __ballot(bit);
                peer_mask                 &= bit ? bal : ~bal;                   // keep lanes that agree with me on this bit
            }
            uint64_t lanes_lt              = (1ull << lane) - 1;
            uint32_t peer_prefix           = __popcll(peer_mask & lanes_lt);
            uint32_t lane_leader           = __ffsll(peer_mask) - 1;
            
            uint32_t old_count = 0;
            if (lane == lane_leader) {
                old_count = atomicAdd(&block_histogram[wave_id][digits[i]], __popcll(peer_mask));
            }
            old_count = __shfl_sync(mask, old_count, lane_leader);

            ranks[i] = old_count + peer_prefix;
        }
    }
    __syncthreads();

    // calculate the block wide hhistogram
    uint32_t sum = 0;
    uint32_t last_sum = 0;

    #pragma unroll
    for (uint32_t wave = 0; wave < WAVES; ++wave) {
        sum += block_histogram[wave][thread_id];
        wave_prefix[wave][thread_id] = last_sum;
        last_sum = sum;
    }

    // mark aggregate ready for this bucket
    uint32_t bucket_data = (sum << 2) | AGGREGATE_READY;

    // store the aggregate in vram for lookback
    __hip_atomic_store(
        &block_data[block_id * BUCKETS + thread_id], 
        bucket_data, 
        __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT
    );
    __syncthreads();

    // --------------------
    // ----- LOOKBACK -----
    // --------------------

    // local copy of the final prefix sum of the current block
    __shared__ uint32_t prefix[BUCKETS];
    prefix[thread_id] = 0;

    int64_t queried_block = static_cast<int64_t>(block_id) - 1;
    while (queried_block >= 0) {     
        
        // wait for the queried block's bucket to publish its aggregate
        uint32_t queried_block_data;
        uint32_t status;
        do {
            queried_block_data = __hip_atomic_load(
                &block_data[queried_block * BUCKETS + thread_id],
                __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT
            );

            status = queried_block_data & FLAG_MASK;

            // a small delay to alleviate constant vram checks
            __builtin_amdgcn_s_sleep(1);
        } while (status == NOT_READY);

        // add the value to the block's running prefix sum
        prefix[thread_id] += queried_block_data >> 2;

        // terminate lookback if a prefix sum is found
        if (status == PREFIX_READY) {
            break;
        }

        queried_block -= 1;
    }

    // mark the prefix as ready for this bucket in the block
    uint32_t prefix_sum = prefix[thread_id] + sum;
    prefix_sum = (prefix_sum << 2) | PREFIX_READY;
    __hip_atomic_store(
        &block_data[block_id * BUCKETS + thread_id],
        prefix_sum,
        __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT
    );
    __syncthreads();

    // --------------------
    // ----- SCATTER ------
    // --------------------

    // local copy of global histogram for faster fetch
    __shared__ uint32_t histogram[BUCKETS];
    histogram[thread_id] = global_histogram[pass * BUCKETS + thread_id];
    __syncthreads();

    #pragma unroll
    for(uint32_t key = 0; key < KEYS_PER_THREAD; ++key) {
        
        // guard 
        size_t in_index = wave_offset + (key * THREADS_PER_WAVE) + lane;
        if (in_index >= nmem) continue;

        ranks[key] += wave_prefix[wave_id][digits[key]];
        size_t key_index = histogram[digits[key]] + prefix[digits[key]] + ranks[key];
        d_keys_out[key_index] = keys[key];
    }
}
} // namespace OnesweepRadixSort

float
RadixSort::sort(std::vector<uint32_t>& input, size_t nmem) {
    if (nmem == 0) return 0.0;

    if (nmem < 1000000) {
        auto start = std::chrono::steady_clock::now();
        std::sort(input.begin(), input.end());
        auto end = std::chrono::steady_clock::now();

        std::chrono::duration<double, std::milli> time = end - start;
        return static_cast<float>(time.count()); 
    }

    hipEvent_t start, stop;
    HIP_CHECK(hipEventCreate(&start));
    HIP_CHECK(hipEventCreate(&stop));

    const size_t block_count = (nmem + KEYS_PER_BLOCK - 1) / KEYS_PER_BLOCK;

    // slot 0 = histogram, 1 = scan, 2.. = one per binning pass
    float kernel_ms[2 + TOTAL_PASSES] = {};
    float ms = 0.0;
    auto time_kernel = [&](size_t slot, auto&& launch) {
        HIP_CHECK(hipEventRecord(start));
        launch();
        HIP_CHECK(hipGetLastError());
        HIP_CHECK(hipEventRecord(stop));
        HIP_CHECK(hipEventSynchronize(stop));
        float t = 0.0;
        HIP_CHECK(hipEventElapsedTime(&t, start, stop));
        kernel_ms[slot] = t;
        ms += t;
    };

    uint32_t* d_input               = nullptr;
    uint32_t* d_output              = nullptr;
    uint32_t* global_histogram      = nullptr;
    uint32_t* block_data            = nullptr;
    HIP_CHECK(hipMalloc(&d_input,           sizeof(uint32_t) * nmem));
    HIP_CHECK(hipMalloc(&d_output,          sizeof(uint32_t) * nmem));
    HIP_CHECK(hipMalloc(&global_histogram,  TOTAL_PASSES * BUCKETS * sizeof(uint32_t)));
    HIP_CHECK(hipMalloc(&block_data,        block_count * BUCKETS * sizeof(uint32_t)));

    // upload input to gpu vram
    HIP_CHECK(hipMemcpy(d_input, input.data(), sizeof(uint32_t) * nmem, hipMemcpyHostToDevice));

    // Global Histogram
    HIP_CHECK(hipMemsetAsync(global_histogram, 0, TOTAL_PASSES * BUCKETS * sizeof(uint32_t)));
    time_kernel(0, [&] {
        OnesweepRadixSort::GlobalHistogram<<<block_count, BUCKETS>>>(
            d_input,
            global_histogram,
            nmem
        );
    });

    // Hist scan
    time_kernel(1, [&] {
        OnesweepRadixSort::GlobalHistogramScan<<<TOTAL_PASSES,  BUCKETS>>>(global_histogram);
    });

    // 4 pass binning
    for (uint32_t pass = 0; pass < TOTAL_PASSES; ++pass) {
        HIP_CHECK(hipMemsetAsync(block_data, 0, block_count * BUCKETS * sizeof(uint32_t)));

        time_kernel(2 + pass, [&] {
            OnesweepRadixSort::Bin<<<block_count, BUCKETS>>>(
                block_data,
                d_output,
                d_input,
                global_histogram,
                nmem,
                pass);
        });

        RadixSort::swap_pointers(&d_input, &d_output);
    }

    // transfer the output back
    HIP_CHECK(hipMemcpy(input.data(), d_input, nmem * sizeof(uint32_t), hipMemcpyDeviceToHost));

    // free up memory
    HIP_CHECK(hipFree(d_input));
    HIP_CHECK(hipFree(d_output));
    HIP_CHECK(hipFree(global_histogram));
    HIP_CHECK(hipFree(block_data));

    HIP_CHECK(hipEventDestroy(start));
    HIP_CHECK(hipEventDestroy(stop));

    // per-kernel breakdown (parsed by run_test.py)
    std::cout << "Kernel hist: " << kernel_ms[0] << "ms\n"
              << "Kernel scan: " << kernel_ms[1] << "ms\n";
    for (uint32_t pass = 0; pass < TOTAL_PASSES; ++pass) {
        std::cout << "Kernel bin" << pass << ": " << kernel_ms[2 + pass] << "ms\n";
    }

    return ms;
}

float
RadixSort::rocprim_sort(std::vector<uint32_t>& input, size_t nmem) {
    if (nmem == 0) return 0.0;

    hipEvent_t start, stop;
    HIP_CHECK(hipEventCreate(&start));
    HIP_CHECK(hipEventCreate(&stop));

    float ms = 0.0;
    auto time_kernel = [&](auto&& launch) {
        HIP_CHECK(hipEventRecord(start));
        launch();
        HIP_CHECK(hipGetLastError());
        HIP_CHECK(hipEventRecord(stop));
        HIP_CHECK(hipEventSynchronize(stop));
        float t = 0.0;
        HIP_CHECK(hipEventElapsedTime(&t, start, stop));
        ms += t;
    };

    uint32_t* d_keys_in  = nullptr;
    uint32_t* d_keys_out = nullptr;
    HIP_CHECK(hipMalloc(&d_keys_in,  nmem * sizeof(uint32_t)));
    HIP_CHECK(hipMalloc(&d_keys_out, nmem * sizeof(uint32_t)));
    HIP_CHECK(hipMemcpy(d_keys_in, input.data(), nmem * sizeof(uint32_t), hipMemcpyHostToDevice));

    // query temp storage size
    size_t temp_bytes = 0;
    HIP_CHECK(rocprim::radix_sort_keys(
        nullptr, temp_bytes,
        d_keys_in, d_keys_out, nmem,
        0, 32, 0
    ));

    void* d_temp = nullptr;
    HIP_CHECK(hipMalloc(&d_temp, temp_bytes));

    time_kernel([&] {
        HIP_CHECK(rocprim::radix_sort_keys(
            d_temp, temp_bytes,
            d_keys_in, d_keys_out, nmem,
            0, 32, 0
        ));
    });

    HIP_CHECK(hipMemcpy(input.data(), d_keys_out, nmem * sizeof(uint32_t), hipMemcpyDeviceToHost));

    HIP_CHECK(hipFree(d_keys_in));
    HIP_CHECK(hipFree(d_keys_out));
    HIP_CHECK(hipFree(d_temp));

    HIP_CHECK(hipEventDestroy(start));
    HIP_CHECK(hipEventDestroy(stop));

    return ms;
}

template <typename T> void 
RadixSort::swap_pointers(T** a, T** b) {
    T* t = *a;
    *a = *b;
    *b = t;
}