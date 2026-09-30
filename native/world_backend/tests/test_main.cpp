#include "test_harness.hpp"

#include <iostream>
#include <sstream>
#include <typeinfo>

namespace voxel::world_backend::tests {

std::vector<TestCase> &registry() {
    static std::vector<TestCase> tests;
    return tests;
}

RegisterTest::RegisterTest(const char *name, void (*body)()) {
    registry().push_back({name, body});
}

[[noreturn]] void fail(const char *expression, const char *file, const int line, const std::string &detail) {
    std::ostringstream message;
    message << file << ':' << line << ": " << expression;
    if (!detail.empty()) {
        message << " (" << detail << ')';
    }
    throw std::runtime_error(message.str());
}

} // namespace voxel::world_backend::tests

int main(const int argc, char **argv) {
    std::string filter;
    for (int index = 1; index < argc; ++index) {
        if (std::string(argv[index]) != "--filter" || index + 1 >= argc || !filter.empty()) {
            std::cerr << "usage: world_backend_core_tests [--filter substring]" << std::endl;
            return 2;
        }
        filter = argv[++index];
        if (filter.empty()) {
            std::cerr << "test filter must not be empty" << std::endl;
            return 2;
        }
    }
    if (const std::optional<int> emitted =
            emit_native_bushy_oak_shadow_observations_if_requested(); emitted.has_value()) {
        return *emitted;
    }
    if (const std::optional<int> emitted =
            emit_native_savanna_observations_if_requested(); emitted.has_value()) {
        return *emitted;
    }
    if (const std::optional<int> emitted =
            emit_native_surface_deformation_observations_if_requested(); emitted.has_value()) {
        return *emitted;
    }
    using voxel::world_backend::tests::registry;
    std::size_t passed = 0;
    std::size_t selected = 0;
    std::vector<std::string> failures;
    for (const auto &test : registry()) {
        if (!filter.empty() && std::string(test.name).find(filter) == std::string::npos) continue;
        ++selected;
        try {
            test.body();
            ++passed;
        } catch (const std::exception &error) {
            failures.push_back(std::string(test.name) + ": [" + typeid(error).name() + "] " + error.what());
        } catch (...) {
            failures.push_back(std::string(test.name) + ": unknown exception");
        }
    }
    std::cout << "{\"schema\":\"native-world-backend-tests/v1\",\"total\":" << registry().size()
              << ",\"selected\":" << selected << ",\"filter\":\"" << filter
              << "\",\"passed\":" << passed << ",\"failed\":" << failures.size() << "}" << std::endl;
    for (const std::string &failure : failures) {
        std::cerr << failure << std::endl;
    }
    return !selected ? 2 : failures.empty() ? 0 : 1;
}
