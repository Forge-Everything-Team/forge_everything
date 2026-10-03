// Everything Food owns vegetable oil. The mod's c:vegetable_oil / c:plantoil tags
// unify it with the other mods' fluids and Almost Unified hides the duplicate
// buckets (see config/almostunified/unification/foods.json); this hides the
// duplicate fluids themselves from JEI.
// Client scripts share one global scope, so this name must not collide with
// DUPLICATE_FLUIDS in hide_duplicate_fluids.js.
const DUPLICATE_FOOD_FLUIDS = [
  // Vegetable oil
  'pneumaticcraft:vegetable_oil',
  'createfood:vegetable_oil'
]

RecipeViewerEvents.removeEntries('fluid', event => {
  DUPLICATE_FOOD_FLUIDS.forEach(id => event.remove(id))
})
