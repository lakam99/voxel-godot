#pragma once

#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend::tests {

struct TestCase {
    const char *name;
    void (*body)();
};

std::vector<TestCase> &registry();

struct RegisterTest {
    RegisterTest(const char *name, void (*body)());
};

[[noreturn]] void fail(const char *expression, const char *file, int line, const std::string &detail = {});

template <typename Expected, typename Actual>
void expect_equal(const Expected &expected, const Actual &actual, const char *expression, const char *file, int line) {
    if (!(expected == actual)) {
        fail(expression, file, line, "values differ");
    }
}

template <typename Exception, typename Callable>
void expect_throw(Callable &&callable, const char *expression, const char *file, int line) {
    try {
        callable();
    } catch (const Exception &) {
        return;
    } catch (...) {
        fail(expression, file, line, "wrong exception type");
    }
    fail(expression, file, line, "expected exception was not thrown");
}

} // namespace voxel::world_backend::tests

#define VWB_TEST_CONCAT_INNER(a, b) a##b
#define VWB_TEST_CONCAT(a, b) VWB_TEST_CONCAT_INNER(a, b)
#define VWB_TEST(name) \
    static void name(); \
    static ::voxel::world_backend::tests::RegisterTest VWB_TEST_CONCAT(register_, name)(#name, &name); \
    static void name()
#define VWB_EXPECT(expression) do { if (!(expression)) ::voxel::world_backend::tests::fail(#expression, __FILE__, __LINE__); } while (false)
#define VWB_EXPECT_EQ(expected, actual) ::voxel::world_backend::tests::expect_equal((expected), (actual), #expected " == " #actual, __FILE__, __LINE__)
#define VWB_EXPECT_THROW(exception, expression) ::voxel::world_backend::tests::expect_throw<exception>([&]() { expression; }, #expression, __FILE__, __LINE__)
