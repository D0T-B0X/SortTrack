#pragma once

#include <fstream>
#include <iostream>
#include <string>
#include <cstdint>
#include <vector>

class CSVReader {
public:
    static void read_csv(std::string path, std::vector<uint32_t>& arr, size_t cap) {
        std::ifstream file(path);

        if (!file.is_open()) {
            std::cerr << "ERROR::Could not open file" << std::endl; 
            exit(-1);
        }
        
        std::string line;
        std::getline(file, line);
        uint32_t size = std::stoul(line);

        size_t count = 0;
        while(std::getline(file, line) && count < cap) {
            arr.push_back(std::stoull(line));
            count += 1;
        }
    }
};