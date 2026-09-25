# CHRONO RIFT 3D MOBA — v23 FBX Collision + Camera/Lighting Fix

This build uses the supplied `map mlbb 2022_fbx_Scene.fbx` as the actual 3D battlefield.

## Changes in v23
- Removed the broad tower-mesh collision approach that could create invisible blocking areas near turrets.
- Wall collision is generated only from the source FBX groups that clearly represent barriers:
  - `ML_5v5_waiweiqiang_*`
  - `ML_5v5_jidiwaiqiang_*`
  - `ML_5v5_jiqiwaiqiang_*`
  - `ML_5v5_weiqiang`
  - `ML_5v5_outsidestone_*`
- Tower collision is now a small cylinder around explicitly named main tower objects, instead of collision from every decorative tower sub-mesh. This prevents oversized/invisible barriers around towers.
- Player uses `CharacterBody3D.move_and_slide()` so the named static wall/stone bodies block movement.
- Camera is slightly higher and slightly more zoomed in, and looks directly at the player so the player stays centered.
- Placeholder player model and collision were reduced slightly in size.
- Lighting was reduced further. The directional light is positioned high above the map and angled downward to give softer, more balanced map shadows.
- Imported map textures remain intact; their material override is darkened slightly to avoid the washed-out appearance.

## Current experiment scope
- Player only.
- No minions, enemy heroes, or bot AI.
- Movement wheel remains enabled.
- Skill indicator remains on the map floor.

## Source naming analysis
The supplied FBX contains explicit wall/stone/tower names. The collision system intentionally uses those names rather than treating every object in the imported scene as solid.
