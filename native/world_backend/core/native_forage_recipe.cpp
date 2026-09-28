#include "native_forage_recipe.hpp"
#include <cmath>
namespace voxel::world_backend { namespace { [[noreturn]] void reject(){throw NativeForageRecipeRejected();}
bool matches(const NativeForageRecipe&r,const char*m,const char*d,const NativeForageNavigationPolicy n){return r.material_id==m&&r.drop_id==d&&r.navigation==n;}
bool grammar_matches(const NativeForageRecipe&r){switch(r.grammar){case NativeForageGrammar::berry:return matches(r,"berryBush","berries",NativeForageNavigationPolicy::blocking);case NativeForageGrammar::aloe:return matches(r,"aloePatch","aloe",NativeForageNavigationPolicy::nonblocking);case NativeForageGrammar::mushroom:return matches(r,"mushroomCluster","mirecap",NativeForageNavigationPolicy::nonblocking);case NativeForageGrammar::frost_herb:return matches(r,"frostHerbPatch","frostHerb",NativeForageNavigationPolicy::nonblocking);}return false;} }
NativeForageRecipeRejected::NativeForageRecipeRejected():std::invalid_argument("invalid native forage recipe"){}
NativeForageRecipe NativeForageRecipeCatalog::admit(NativeForageRecipe recipe){if(recipe.recipe_id.empty())reject();if(!grammar_matches(recipe))reject();if(recipe.drop_min<1)reject();if(recipe.drop_min>recipe.drop_max)reject();if(!std::isfinite(recipe.collider_radius))reject();if(recipe.collider_radius<=0)reject();return recipe;}
} // namespace voxel::world_backend
