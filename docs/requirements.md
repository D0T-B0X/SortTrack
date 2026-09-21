# Objective

A library to sort a variable amount of `uint32_t` integers or key-value pairs using the Radix Sort algorithm. The algorithm will execute on the GPU and will utilize the ROCm/HIP stack for implementation.

## Scope

- Capable of scanning and sorting any number of integers
- Use the decoupled-lookback parallel prefix scan

## Operating Environment

### Hardware

- A GPU capable of executing HIP kernels natively

### Software

- A Linux/Unix system with CMake, and C++ support
- The ROCm/HIP runtime stack for static execution
- HIP compiler (hipcc version 7.2^)

## User Interface

### Supported types 

Provide two modes: `32-bit unsigned integers` and `32-bit unsigned integer key-value pairs`

### API

- `rsort_u32(uint32_t* d_in, uint32_t* d_out, size_t num_elements)`: Sorts a raw unsigned 32-bit integers list of size `num_elements`. Returns an error or success code indicative of execution state at the end.
- `rsort_u32_kv(uint32_t* d_in_keys, uint32_t* d_in_values, uint32_t* d_out_keys, uint32_t* d_out_values, size_t input_length)`: Sorts a list of size `num_elements` given as a pair or keys and values. The output contains sorted values with their keys also sorted to the corresponding index. Returns an error or success code indicative of execution state at the end.

## Functional Requirements

 - Users should be able to pass an array with its size and output array location in a single API call.
 - Several tests at `num_elements` ranges of 10,000 to 10,000,000 must be performed and plotted.

## Non-Functional Requirements

 - Faster than `std::sort()` on the CPU
 - Close to `cudaCUB` and `rocmPRIM` in performance
 - Maximum possible GPU compute saturation