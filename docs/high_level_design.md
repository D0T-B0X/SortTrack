# High Level Design Documentation

This document provides an abstract overview of the library's functions. It defines how the user can utilize the library and how those functions are implemented.

## User API

The user gets access to two functions:

1) `rsort_u32:` Takes a pointer to the array the user wants to sort, along with a pointer to output array and the number of elements they want sorted. It performs a Radix sort and stores the sorted array in the location specified by the output pointer.
2) `rsort_u32_kv`: This accepts two pointers for each input and output, one for an array that represents keys and another than holds values corresponding to those keys. It stores the sorted data array and the keys in the given output pointers, where the value of the keys array corresponds to the new location of the data in the data array.

<p align="center">
    <img src="media/radix_dfd.png" alt="User Abstraction of library" />
</p>

## Architecture

The library exposes two API endpoints to the user, upon receiving a call from one of them, it immediately extracts the size of the input and allocates memory on the device (GPU). This version of Radix sort employs a 4-bit key, this means a total of 8 passes for 32 bit integers. 

A pass executes the following:

 - A histogram generation step that drops a partition's values into their respective buckets based on the key.
 - Every partition performs the decoupled lookback by executing concurrent local value aggregation, followed by partition look backs to get the final exclusive prefix sum.
 - Based on the prefix sum, all values are scattered to their correct indices. In case of a key-value sort, the keys follow the scatter indices used by the data array.
 - Finally, the input and output buffers are swapped so the next pass can begin with the newly generated values.

Once all the passes are over, the final output is written to the memory address specified by the host.

<p align="center">
    <img src="media/execution_flowchart.png" alt="Order or execution for the Radix Sort algorithm" />
</p>

## Modules

### Host

 - An input verification module checks the input size and uses CPP's `std:sort()` to handle the output when it is below a certain threshold, since GPU based parallel sorting algorithms only provide a decent edge over CPU based algorithms when the input size is large.
 - The host code also handles system synchronization and vram buffer allocation before any kernels can execute on the device.

### Device

The GPU will utilize 3 kernels:

 - Historgram generation needs its own kernel, where all values are dropped into buckets pertaining to that values 4-bit key.
 - The decoupled lookback prefix scan executes on a standalone kernel that handles a single pass of the state machine.
 - The scatter kernel redistributes all sorted values to their correct indices and swaps the input and output vram buffers.

## Memory Requirements

Every input array needs an equal size output array on host memory. On device memory, the library needs two buffers for input-output ping pong, each of size `num_members * 4` bytes. Furthermore, every partition in the decoupled lookback prefix sum maintains a partition descriptor, which needs an additional `num_descriptors * sizeof(descriptor)` bytes.

