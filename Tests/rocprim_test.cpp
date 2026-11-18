#include "../lib/onesweep.hpp"
#include "csv_reader.hpp"

#include <vector>
#include <iostream>

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

    float d_time = RadixSort::rocprim_sort(input, TEST_SIZE);
    std::cout << "Test Type: Random\nTest Size: " << TEST_SIZE << "\nROCm time: " << d_time << "\n";

    return 0;
}