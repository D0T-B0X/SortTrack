# Low Level Design Documentation

The low level design doc is a comprehensive reference for all implementation details.

## Parititon Descriptor

The partition descriptor maintains the state of each partition in execution. It utilizes three fields which can be read by other partitions and written by the owner partition.

 - `aggregate:` The total sum of all values inside the partition.
 - `prefix_sum:` The prefix sum obtained by summing the local aggregate with the aggregates of all preceding partitions.
 - `invalid:` When neither the aggregate nor the prefix_sum is ready, the invalid flag acts as a signal for requesting partitions to wait.

The aggregate and prefix sum fields here are arrays of size `BUCKET_SIZE` since they need to store information for all keys in a bucket.

```cpp
struct partition_descriptor {
    uint32_t aggregate[BUCKET_SIZE];
    uint32_t prefix_sum[BUCKET_SIZE];
    bool invalid;
}
```
We can optimize the space occupied by the partition description by utilizing a single 64 bit unsigned integer to hold the aggregate and the prefix sum.

```cpp
uint64_t values; // values = { 0-31: aggregate, 32-63: prefix_sum }
```

The least significant 32 bits of the `values` field represents the parititon aggregate, while the most significant 32 bits store the prefix_sum collected upto the current partition.

## Algorithms

Every kernel will run on a 256 thread block, this creates a good balance between resource utilization and execution speed. Every block will run 8 Wave32 subunits in flight, this means the 64 kB Local Data Share must allocate enough space to handle 16 integers at once for every wavefront given the 4 bit bucket size, which fits easily with padding to avoid memory bank conflicts. All threads process 4 elements at once to maximize throughput.

### Histogram generation

Every histogram kernel extracts a 4 bit key from the input number, the location of the 4 bit key is based on the pass index as: 

$num >> (pass \times 4)$ & $15$

To ensure all 8 wavefronts are dispatched, each wavefront will have its own 16 integer section of the LDS, where distributes keys into their buckets. Therefore, every block stores $16 \times 8$ integers in its LDS.

Finally, the block collects each key's frequency from all wavefront buckets and stores it in a single intra-block histogram, which will be used by the decoupled-lookback phase.

$$ 
\begin{aligned} 
    &\mathbf{Shared\ Memory:} \\
    &\quad \textit{buckets}[\text{BUCKET\_COUNT} \times \text{WAVEFRONT\_COUNT}] \\ \\
    &\mathbf{HISTOGRAM\_GENERATION}(input, size) \\
    &\quad thId \leftarrow \text{threadIndex} \\
    &\quad waveIndex \leftarrow thId \mathbin{/} 32 \\
    &\quad \text{for} \ \textit{i} \ \text{in} \ \textit{0 to PASS\_COUNT} \\
    &\quad \quad key \leftarrow (input[thId] \gg (i \times 4)) \\
    &\quad \quad \text{atomic\_add}(\textit{buckets}[waveIndex \times \text{BUCKET\_COUNT} + key], 1) \\
    &\quad \quad \text{\_\_synchronize()} \\
    \\
    &\quad \quad bucket\_sums[BUCKET\_COUNT] \leftarrow \{0\} \\
    &\quad \quad \text{for \textit{j} in \textit{0 to WAVEFRONT\_COUNT}} \\
    &\quad \quad \quad bucket\_sums[j] \leftarrow bucket\_sums[j] + 
    \\
    &\quad if \ \ thId < BUCKET\_COUNT: \\
        &\quad \quad for \ \ i \leftarrow \text{0 to WAVEFRONT\_COUNT - 1} \\
        &\quad \quad \quad  \\
\end{aligned} 
$$