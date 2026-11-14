#pragma once

#include <cstdint>
#include <vector>

constexpr uint32_t BITS_PER_PASS       =     8;
constexpr uint32_t BUCKETS             =     1 << BITS_PER_PASS; // 2^8

constexpr uint32_t WAVES               =     8;
constexpr uint32_t TOTAL_PASSES        =     32 / BITS_PER_PASS; // 32 but uint's
constexpr uint32_t KEYS_PER_WAVE       =     128;
constexpr uint32_t KEYS_PER_THREAD     =     4;
constexpr uint32_t KEYS_PER_BLOCK      =     1024;
constexpr uint32_t THREADS_PER_WAVE    =     32;

constexpr uint32_t NOT_READY           =     0;  
constexpr uint32_t AGGREGATE_READY     =     1;       
constexpr uint32_t PREFIX_READY        =     2;    
constexpr uint32_t FLAG_MASK           =     3;      

constexpr uint32_t SENTINEL            =     ~0;

class RadixSort {
public:
    static float sort(std::vector<uint32_t>& input, std::size_t nmem);
    static float rocprim_sort(std::vector<uint32_t>& input, std::size_t nmem);

private:
    template <typename T> static void swap_pointers(T** a, T** b);
};