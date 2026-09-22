#pragma once
#include "godot_pcg_compat.hpp"
#include "native_forage_recipe.hpp"
#include <cstdint>
#include <stdexcept>
#include <vector>
namespace voxel::world_backend {
struct NativeForageStream final { NativeForageRecipe recipe; std::uint64_t state_before=0U; std::uint64_t state_after=0U; std::int64_t drop_count=0; std::vector<float> float_draws; };
class NativeForageStreamRejected final:public std::invalid_argument{public:NativeForageStreamRejected();};
class NativeForageStreamBuilder final{public:static NativeForageStream create(const NativeForageRecipe& recipe,GodotPcg32&rng);};
} // namespace voxel::world_backend
