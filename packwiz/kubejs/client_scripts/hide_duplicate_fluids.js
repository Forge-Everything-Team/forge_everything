// Everything Ores owns crude oil, biofuel, gasoline, diesel, biodiesel, kerosene,
// ethanol, creosote, sulfuric acid, LPG, heavy oil and lubricant. The
// datapack retargets recipes and Almost Unified hides the duplicate buckets; this
// hides the duplicate fluids themselves from JEI.
const DUPLICATE_FLUIDS = [
  // Crude oil
  'pneumaticcraft:oil',
  'modern_industrialization:crude_oil',
  'tfmg:crude_oil',
  'oritech:still_oil',
  'stellaris:oil',
  // Biofuel
  'createaddition:bioethanol',
  'industrialforegoing:biofuel',
  'oritech:still_biofuel',
  // Gasoline
  'pneumaticcraft:gasoline',
  'tfmg:gasoline',
  // Diesel
  'pneumaticcraft:diesel',
  'tfmg:diesel',
  'oritech:still_diesel',
  'modern_industrialization:diesel',
  'stellaris:diesel',
  // Biodiesel
  'pneumaticcraft:biodiesel',
  'immersiveengineering:biodiesel',
  'modern_industrialization:biodiesel',
  // Kerosene
  'pneumaticcraft:kerosene',
  'tfmg:kerosene',
  // Ethanol
  'pneumaticcraft:ethanol',
  'immersiveengineering:ethanol',
  'modern_industrialization:ethanol',
  'electrodynamics:fluidethanol',
  // Creosote
  'immersiveengineering:creosote',
  'modern_industrialization:creosote',
  'tfmg:creosote',
  // Sulfuric acid (the fluids only; Mekanism's chemical of the same id is untouched)
  'mekanism:sulfuric_acid',
  'modern_industrialization:sulfuric_acid',
  'oritech:still_sulfuric_acid',
  'tfmg:sulfuric_acid',
  'electrodynamics:fluidsulfuricacid',
  // LPG
  'pneumaticcraft:lpg',
  'tfmg:lpg',
  // Heavy oil
  'oritech:still_heavy_oil',
  'tfmg:heavy_oil',
  // Lubricant
  'modern_industrialization:lubricant',
  'pneumaticcraft:lubricant',
  'tfmg:lubrication_oil'
]

RecipeViewerEvents.removeEntries('fluid', event => {
  DUPLICATE_FLUIDS.forEach(id => event.remove(id))
})
