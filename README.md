# Gold Grinder

An isometric 3D bulldozer game for iPhone and Mac, written in Swift with SceneKit (rendered on Metal).

Drive a little bulldozer with a zombie driver, scoop up the gold coins a conveyor belt throws into the mine, and push them into
heaps on glowing buttons in the floor. When a heap is big enough it melts into the button and you get a
bigger dozer or open the gate to the next mine. Melt a huge golden pile in the last mine to win.

Inspired by "Idle Zombie Miner" ads.

## How to play

- Each mine is fed by a **conveyor belt** outside its wall. Random little piles of coins ride out of a hopper,
  and at the end of the belt the coins fly through a gap in the crystal wall and scatter across the mine floor.
  The belt slows down as it empties and finally runs dry. It is the only gold in the mine.
- Push coins onto a **button** in the floor (orange: next dozer, purple: gate, yellow: victory).
  The ring around it fills up as coins pile on. Push coins off again and it goes down.
- When the pile reaches the price, it **melts** into the button:
  - **DOZER** buttons give you the next, bigger bulldozer (6 levels, wider plows, more pushing power).
  - **GATE** buttons open the next mine (4 mines, each coin is worth more: 1, 3, 8, 25).
  - The **VICTORY** button in mine 4 needs about 2,000 coins. Fill it to win.
- Each belt holds just a little more gold than its mine's dozer and gate cost together, so collect every coin.
- The game does not save. **NEW GAME** (top right, tap twice) starts over.

### Controls

| | Drive | Notes |
|---|---|---|
| iPhone | On-screen buttons: ▲ / ▼ on the left, ◀ / ▶ on the right | Use both thumbs at once. |
| Mac, mouse | Drag where you want to go | Drag behind the dozer to back up. |
| Mac, keyboard | W / S forward and reverse, A / D turn | Arrow keys work too. |

## Building

Requires Xcode (made with Xcode 27, iOS 17+ / macOS 14+).

### Mac

```sh
swift run -c release
```

Use the release build: the coin physics is too slow in a debug build.
If `swift` picks the Command Line Tools instead of Xcode, prefix the command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

### iPhone

1. Open `iOS/GoldGrinder.xcodeproj` in Xcode.
2. Under *Signing & Capabilities*, pick your own team (and change the bundle ID if needed).
3. Choose your iPhone or a simulator and press Run.

The project compiles the shared game code with optimisation even in Debug, so it runs smoothly on device.

## Project layout

```
Package.swift                 Swift package for the Mac app
Sources/GoldGrinder/
  main.swift                  Mac window, mouse and keyboard input
  Game.swift                  Game rules, mines, belts, buttons, camera, driving
  Coins.swift                 Coin physics (pushing, stacking, falling) and batched coin rendering
  DozerModel.swift            The six 3D bulldozers, built from code
  Art.swift                   Materials, crystal walls, textures, signs and icons (CoreGraphics)
  Hud.swift                   2D overlay: labels, joystick, NEW GAME button, win screen
  Resources/dozer1-6.png      Dozer pictures used on the button signs
iOS/
  GoldGrinder.xcodeproj       iPhone app project (uses the shared sources above)
  GoldGrinder/App.swift       iPhone app, scene and touch input
  GoldGrinder/Assets.xcassets App icon
*.png, *.jpeg                 Reference art the dozers, gold and buttons were based on
```

## How it works

- **Rendering:** SceneKit on Metal with an orthographic isometric camera, HDR bloom, shadows and
  physically based materials. The dozers, crystal walls, belts and buttons are all built from code.
- **Coins:** thousands of coins with simple 2D physics on the ground plane. Coins sleep until touched,
  climb on top of each other when squeezed (so heaps form), and fall when nothing is under them.
  They are drawn in 3x3 m chunks, and a chunk's mesh is only rebuilt when one of its coins moves.
- **Buttons** are placed in open floor away from the walls so you can push gold onto them from any side.
- **iPhone start-up:** the coins, molten blob and sparks are drawn once under the floor at launch, so the
  iPhone prepares their shaders while loading instead of stalling at the first melt.
- **The plow** is a polyline that is both drawn and used as the collision wall, so coins collect inside it
  and turn with the dozer. The whole dozer outline collides with walls, and it backs off a little when a turn
  would swing the plow into a wall.
