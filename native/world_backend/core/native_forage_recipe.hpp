#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>
namespace voxel::world_backend {
enum class NativeForageGrammar : std::uint8_t { berry = 1, aloe = 2, mushroom = 3, frost_herb = 4 };
enum class NativeForageNavigationPolicy : std::uint8_t { blocking = 1, nonblocking = 2 };
struct NativeForageRecipe final { std::string recipe_id; std::string material_id; std::string drop_id; std::int32_t drop_min=0; std::int32_t drop_max=0; float collider_radius=0; NativeForageGrammar grammar=NativeForageGrammar::berry; NativeForageNavigationPolicy navigation=NativeForageNavigationPolicy::blocking; };
class NativeForageRecipeRejected final : public std::invalid_argument { public: NativeForageRecipeRejected(); };
class NativeForageRecipeCatalog final { public: static NativeForageRecipe admit(NativeForageRecipe recipe); };
} // namespace voxel::world_backend
