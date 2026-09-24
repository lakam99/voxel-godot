#include "test_harness.hpp"

#include <iostream>
#include <sstream>

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

int main() {
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
    std::vector<std::string> failures;
    for (const auto &test : registry()) {
        try {
            test.body();
            ++passed;
        } catch (const std::exception &error) {
            failures.push_back(std::string(test.name) + ": " + error.what());
        } catch (...) {
            failures.push_back(std::string(test.name) + ": unknown exception");
        }
    }
    std::cout << "{\"schema\":\"native-world-backend-tests/v1\",\"total\":" << registry().size()
              << ",\"passed\":" << passed << ",\"failed\":" << failures.size() << "}" << std::endl;
    for (const std::string &failure : failures) {
        std::cerr << failure << std::endl;
    }
    return failures.empty() ? 0 : 1;
}
