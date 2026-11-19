#include "../lib/onesweep.hpp"
#include "csv_reader.hpp"

#include <vector>
#include <print>

#ifndef TEST_CSV_PATH
#error "TEST_CSV_PATH not defined"
#endif

constexpr static size_t MAX_TEST_SIZE = 1'000'000'000;

int main(int argc, char* argv[]) {
    size_t TEST_SIZE;
    if (argc == 2) {
        TEST_SIZE = MAX_TEST_SIZE;
    } else if (argc == 3) {
        TEST_SIZE = std::atoi(argv[2]);
    } else {
        std::cerr << "2 arguments expected found " << argc << "\n";
        exit(-1);
    }

    char selected_algoritm = argv[1][0];

    std::vector<uint32_t> input;
    input.reserve(TEST_SIZE);
    CSVReader::read_csv(TEST_CSV_PATH, input, TEST_SIZE);
    std::vector<uint32_t> copy(input);

    // execution time check
    float time_agg = 0.0f;
    switch (selected_algoritm) {
        case 'r':
            // cold start mitigation
            RadixSort::rocprim_sort(copy, TEST_SIZE);
            RadixSort::rocprim_sort(copy, TEST_SIZE);

            for(size_t i = 0; i < 10; ++i) {
                std::copy(input.begin(), input.end(), copy.begin());
                time_agg += RadixSort::rocprim_sort(copy, TEST_SIZE);
            }
            break;
        case 'o':
            RadixSort::sort(copy, TEST_SIZE);
            RadixSort::sort(copy, TEST_SIZE);

            for(size_t i = 0; i < 10; ++i) {
                std::copy(input.begin(), input.end(), copy.begin());
                time_agg += RadixSort::sort(copy, TEST_SIZE);
            }
    }

    float time = time_agg / 10.0f;

    /*
    // CPU time
    auto start = std::chrono::steady_clock::now();
    std::sort(input.begin(), input.end());
    auto stop = std::chrono::steady_clock::now();

    std::chrono::duration<double, std::milli> h_time = stop - start;
    */

    std::println("Test size: {}\nTime: {}", TEST_SIZE, time);

    return 0;
}