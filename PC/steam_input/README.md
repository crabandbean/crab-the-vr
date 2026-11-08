# Steam Input template

A starting point for games that use tracked controllers the Vive way: grab with
the grip, use with the trigger, walk on the trackpad. Job Simulator and the
other room-scale games of its generation read these.

The app turns every controller you did not mark **Ignore** into a Vive-style
tracked controller (left hand, right hand or gamepad), with these components:

| Component | Nintendo input |
| --- | --- |
| `/input/trigger/value` | ZL / ZR, or the analog triggers |
| `/input/trigger/click` | ZL / ZR past halfway |
| `/input/grip/click` | L / R shoulder |
| `/input/application_menu/click` | Plus / Minus |
| `/input/system/click` | Home |
| `/input/trackpad/x`, `y` | the stick |
| `/input/trackpad/click` | A |
| `/input/trackpad/touch` | A, B, X or Y |

## Files

- `joyvr_actions.json` — the action manifest: an action set with
  `trigger_use`, `grip_grab`, `menu` and `trackpad_move`, plus the default
  binding entry.
- `joyvr_bindings_vive.json` — the binding: which source drives which action.

## Using it

1. Copy both files next to the game's own SteamVR input manifest, for example
   `steamapps/common/<game>/`.
2. Point the game's `steamvr.vrsettings` (or its developer console) at
   `joyvr_actions.json`, or merge our actions and sources into the manifest the
   game already ships.
3. In SteamVR's controller binding screen the layout appears as **Crab the VR**;
   remap anything the game wants differently.

These are templates, not a drop-in install: a game that ships its own actions
will need the `sources` in `joyvr_bindings_vive.json` copied into its binding,
and a game with desktop Steam Input can use the same components in its own
configuration.
