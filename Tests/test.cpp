#include "../lib/onesweep.hpp"
#include "csv_reader.hpp"

#include <algorithm>
#include <ratio>
#include <vector>
#include <iostream>
#include <chrono>

#ifndef TEST_CSV_PATH
#error "TEST_CSV_PATH not defined"
#endif

constexpr static size_t MAX_TEST_SIZE = 1'000'000'000;

int main(int argc, char* argv[]) {
    size_t TEST_SIZE;
    if (argc == 1) {
        TEST_SIZE = MAX_TEST_SIZE;
    } else if (argc == 2) {
        TEST_SIZE = std::atoi(argv[1]);
    } else {
        std::cerr << "1 argument expected found " << argc << "\n";
        exit(-1);
    }

    std::vector<uint32_t> input;
    input.reserve(TEST_SIZE);
    CSVReader::read_csv(TEST_CSV_PATH, input, TEST_SIZE);
    std::vector<uint32_t> copy = input;

    float d_time = RadixSort::sort(copy, TEST_SIZE);

    for (size_t i = 1; i < TEST_SIZE; ++i) {
        if (copy[i - 1] > copy[i]) {
            std::cerr << "ERROR: Incorrect Sort.\n\nElement at index " << i << " out of place\n";
            exit(-1);
        }
    }

    copy = input;
    float r_time = RadixSort::rocprim_sort(copy, TEST_SIZE);

    auto start = std::chrono::steady_clock::now();
    std::sort(input.begin(), input.end());
    auto stop = std::chrono::steady_clock::now();

    if (copy != input) {
        std::cerr << "ERROR: Incorrect Sort.\n";
        exit(-1);
    }

    std::chrono::duration<double, std::milli> h_time = stop - start;

    std::cout << "Test Type: Random\nTest Size: " << TEST_SIZE << "\n\nOnesweep time: " << d_time << "ms\nCPU time: " << h_time.count() << "ms\nROCM time: " << r_time << "ms\n";

    return 0;
}