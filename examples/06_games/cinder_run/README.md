```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cinder Run

### The Last Lamplighter

A one-player, endless sidescroller for the Atari 2600. Carry your lantern through
the volcanic ruins: climb three tiers of scrolling platforms above the road,
leap over rolling cinders, duck low embers, shoot monsters and collect sparks.
Three lamps in the upper-left corner show your lives; there is no mirrored copy.

## The story

**The mountain didn't erupt. Someone opened the furnace beneath it.**

The city once kept its nights in a communal kiln. At sunset, the lamplighters
carried its fire through the streets, borrowing enough daylight to last until
morning. Then the kiln grew hungry. It began taking more than wood: first names,
then dreams, then the people who remembered them. Dawn stopped coming.

You are the last lamplighter. The creatures in the ruins aren't all hunting you.
Some are still walking to work, guarding a doorway, or flying the same route
home. The furnace has burned away their destinations, but not their habits.
That's why they keep moving past you instead of stopping overhead.

### Why collect the dots?

Those little lights are **memory sparks**: things the furnace couldn't quite
burn. A remembered song. A kitchen window. Someone waiting up for you. Their
colors echo the kiln-bound creatures nearby; the memories and the creatures
were caught in the same stolen fire.

Your lantern shelters each spark from the kiln. Once rescued, it stays rescued:
walking away and coming back cannot make the furnace sell you the same memory
twice. In this build, each spark awards **50 points**, not extra health or ammo.
The three life lamps represent your three borrowed sunrises; lose them all and
the journey ends. Restarting begins a fresh journey, with fresh memory sparks.

### What is the weapon?

The **Dawnspike** began as a lamplighter's brass wick-pricker: a small tool for
clearing soot from a stubborn lamp. Yours has been fitted with the last unburned
fragment of the city's morning bell. Squeeze its handle and it strikes one hard
note, compressing clean lantern light into a needle of cold dawn.

It doesn't fight the furnace with more fire. A hit punctures a creature's ash
shell and breaks the kiln's binding, letting what remains escape. The shell
disappears; elsewhere, another bound creature continues its old journey.
Mechanically, one hit removes a monster and awards **100 points**. Shots travel
in eight directions, with one shot on screen at a time; release Fire between
shots. The Dawnspike consumes neither rescued sparks nor life lamps.

### The kiln-bound

Their colors show what the furnace made of them, not how many hits they take.
Every type currently takes one Dawnspike hit.

| Creature | Color | What remains |
| --- | --- | --- |
| Coalback | Copper-orange | A kiln stoker, still hauling an invisible load. |
| Low ember | Hot orange | A streetlighter's flame, loose from its lantern. |
| Kiln moth | Violet | A night messenger, following light that leads nowhere. |
| Roof bat | Indigo | A keeper of the city's vanished rooftops. |
| Ash walker | Pale cyan | Someone whose borrowed fire is almost gone. |
| Cinder wraith | Silver-gray | The shape left behind when a name burns away. |
| Bellkeeper | Brass-yellow | A watchman still waiting for the morning bell. |
| Root warden | Moss-green | A garden keeper carrying the city's last roots. |

**The furnace can keep the city. You're taking its mornings back.**

## Music: Borrowed Morning

The lantern remembers a little of the morning bell's music, too. **Borrowed
Morning** is an original eight-bar progressive-rock miniature. Its opening
alternates **7/8 (3+2+2)** and **5/8 (3+2)**, with shifting accents and a higher
answer to the opening motif. A more spacious **6/8 (3+3)** bridge lets notes ring
between rests, before the odd-meter theme returns in the upper register and
settles back onto D. The hollow TIA voice keeps the heavy, swaying feel; this
is not a transcription of an existing song.

The loop lasts 1,200 frames (about twenty seconds), at roughly **72 BPM**.
It plays during a run, stops on game over or Reset, and starts from the beginning
on a fresh run. TIA channel 1 carries the music; channel 0 retains the distinct
jump, collection, weapon and damage effects. The music ducks beneath those
effects so the lantern's song doesn't hide gameplay cues.

## Play

```sh
make
make play
```

- **Up:** jump. Release between jumps; holding Up does not jump repeatedly.
  Jumping makes an upward pitch sweep; catching a spark makes a high fixed chime.
- **Left joystick fire:** start, shoot, or restart after losing all three lives.
  One shot at a time; release between shots. Hold Fire with any joystick direction
  to aim in eight directions. Neutral Fire shoots in the last facing direction.
  While Fire is held, the stick aims rather than moving, crouching, or jumping.
  A three-frame aim grace period accepts Up just after Fire, making straight-up
  shots easier without accidentally jumping.
- **Left/right:** run in either direction. The camera follows near the side of
  the movement window; there is no forced scrolling or speed acceleration.
- **Down:** crouch. Your feet stay planted while the body becomes half-height;
  low embers that hit a standing courier pass overhead. Release to stand up.
- **Console Reset:** return to the starting scene.

Sparks award 50 points, kills award 100, and survival adds points over time.
After a hit, the courier flashes
and is briefly invulnerable. Eight animated monster types vary in silhouette,
speed and elevation. They keep their spawn direction, pass above or below you,
and continue off screen rather than tracking your horizontal position.
The red score means game over; release fire, then press it to begin a fresh run.

## Platforms and movement

The platforms are real terrain, not background hills. Jump early onto an
approaching ledge, then jump again to climb the next tier. Falling feet land on
the top; jumping into an underside bumps your head. Walk off an edge and gravity
takes over. Side walls block movement and scrolling walls push the courier back.
There is always a continuous road below, so a missed jump is recoverable.
Ledges are four scanlines thick, a quarter of their original thickness; their tops
remain at the same three heights.

The four-frame running cycle alternates extended strides and passing/recovery
poses, with counter-swinging arms and contrasting boots. Airborne and crouched
poses are separate from the running cycle. Releasing the movement stick selects
a standing pose, also used while aiming. A ceiling keeps the whole courier below
the lamp strip.

Treasure sparks are centered four-scanline dots with widths **2/4/4/2 pixels**:
the narrow rows sit one pixel inside each side of the wide rows. M1 shifts left
one pixel for the first wide row, then right one for the bottom narrow row.
Normal HMOVE causes two short eight-pixel blanking marks at the left edge on
those transition lines, in the otherwise-empty gap, not on platforms or the road.
Dots are hidden within the leftmost eight pixels to avoid showing a clipped
half-dot in that HMOVE area; terrain still covers the full 160 pixels. Each
256-pixel world sector has one fixed treasure; a 32-byte bitmap remembers all
256 treasure IDs until restart or Reset. Leaving the screen and returning cannot
respawn a collected treasure. IDs repeat after 65,536 pixels; taken IDs remain
taken even on later circuits. Terrain itself continues its reversible LFSR cycle.

PF0, PF1 and PF2 cover all forty four-pixel columns: **160 pixels**, not only
the central 128. Scrolling advances a terrain column after four movement pixels.
Each reversible 16-bit LFSR state describes a sixteen-pixel chunk of platform
occupancy; the nonzero initial seed is `$ACE1`, with feedback polynomial `$B400`.
Moving left uses the inverse step, so returning to a location restores exactly
the same platforms. Chunk widths are bounded; the continuous road remains a
fallback, but the generator does not promise every overhead route is climbable.

## Cartridge

NTSC, **16K F6SC**, ordinary joystick, official 6502 opcodes only. The cartridge
provides 128 bytes of Superchip RAM; no emulator modifications are required.
The build uses 64 cartridge-RAM bytes and 127 RIOT-RAM bytes, including a
19-byte hardware-stack allowance.

The game-owned 181-line raster draws two eight-row sprites, an M0 shot, an M1
spark, and three independent full-width platform tiers. The visible terrain uses
**18 bytes**: left PF0/PF1/PF2 and reflected right PF2/PF1/PF0 for each tier.
This is three bytes more than a bit-packed 15-byte window, but needs no expanded
render cache. Gaps and the full-width road are implicit. Two LFSR endpoint states
and a chunk phase regenerate newly exposed columns without a stored level.
The Ball is disabled. M0 shares the courier palette; M1 shares the
monster palette, contrasting with the platforms. While a shot is active, M0 and
M1 alternate frames (30 Hz each); players and terrain remain steady at 60 Hz.
The courier retains per-row colours and reflects when facing left; each monster
type has its own tint, prepared in cartridge RAM without adding raster cycles.
M1 shares that current monster tint through COLUP1. Missile enables commit in horizontal
blanking, avoiding partial scanlines as a missile approaches the left edge.
Collision probes sample the same
packed playfield bytes that the kernel displays. The six-glyph component supplies
the score above gameplay in the Whimsey font. TIA collision latches drive damage,
kills and collection.
Physics runs in VBLANK; terrain updates, treasure lookup, monster-art preparation
and scoring run in overscan, keeping both
blanking deadlines bounded. Beam-critical graphics stay in the startup bank.
Overscan/VBLANK scratch aliases reuse dead renderer workspace, never persistent
coordinates or live drawing state.

`test/vcs_cinder_run.pl` builds the ROM and runs a CPU/input oracle covering
jumping, crouching, all three swept platform landings, solid undersides, falling
off ledges, injected missile/damage/collection responses, game over, restart,
Reset, distinct jump/catch tones, and all eight aim directions without accidental
movement. An additional 7,200-frame traversal compares every displayed terrain
column with an independent LFSR decoder, checks inverse steps and window endpoint
states, and verifies that revisiting terrain restores its bytes. Every frame must
retain the established 264-line period. Further routes check treasure persistence,
monster motion past the player and off screen, eight distinct monster designs and tints,
and buffered upward aiming. Broken kills, ceilings, inverse steps, treasure flags
and restored chasing behavior are rejected as negative controls; injected
collisions do not prove TIA geometry.
The endurance run also checks every music pitch, rest, attack and release over
multiple complete loops against an independent score/tempo oracle. Separate
checks require music to duck beneath effects, stop on game over/Reset, and
restart at its first note. A muted-music negative control must fail audibly
relevant channel-register assertions, not just differ in ROM bytes.

`test/vcs_cinder_run_stella.pl` checks all 160 pixels of every platform scanline
and intervening gap, every full-width road line, upper-left-only lamps, stationary
and four distinct running poses, Up jumping,
fixed-foot crouching, all eight monster colors on actual rendered creatures,
a real missile kill, and visible travel in all eight aim
directions. A scripted right/left excursion must restore the original platform
pixels. A real TIA treasure collection must stay absent after leaving and returning.
Sweeps cover all four treasure heights, a complete X1..128 cycle, and X120..151.
Every visible dot must have exactly four centered lines of widths 2/4/4/2; the
seven positions hidden in the left margin are counted separately, not discarded.
A no-motion negative control must be rejected even though its row widths are
correct: an arrowhead is not a centered dot. The CPU oracle checks paired
minus/plus-one HMOVEs, zero motion on other objects, and unchanged frame periods.
Captures use recorded
RawStream frame identities, never stream positions or artwork/ROM goldens.
