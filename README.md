<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Pokey">
</p>

<h1 align="center">Pokey</h1>

<p align="center"><b>Poke your Mac with the keyboard. Catch Pokémon while you're at it.</b></p>

<p align="center">
  <img src="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/1.png" width="88" alt=""> <img src="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/4.png" width="88" alt=""> <img src="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/7.png" width="88" alt=""> <img src="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/25.png" width="88" alt=""> <img src="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/133.png" width="88" alt=""> <img src="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/143.png" width="88" alt="">
</p>

Pokey is a tiny menu bar app that lets you click anything on macOS without touching the mouse — buttons, links,
menu bar items, status icons, even a random spot on a canvas. And every so often, a wild Pokémon pops out of the
thing you just clicked. Gotta click 'em all.

Inspired by [Homerow](https://www.homerow.app) and [Scoot](https://github.com/mjrusso/scoot), and built by someone who
types on an HHKB and refuses to reach for the trackpad.

## What it does

| Default shortcut | Mode | How it works |
|---|---|---|
| `⌃D` | **Click Element** | Labels appear on every clickable thing — in the front window, its menu bar, the status icons on the right, or an open menu. Type a label to click it. `⇧` right-click · `⌘` ⌘-click · `⌥` just move the pointer · `Tab` focus the first text field (page inputs before the browser's address bar). |
| `⌃G` | **Grid** | The screen splits into lettered cells. Type a cell to click its center. Hold `⇧` on the last letter to only move there, then nudge with the arrow keys and press `↩`. `Tab` jumps to the next display. |
| `⌃F` | **Free Move** | Drive the pointer with `h j k l` or the arrows (`⌥` big steps, `⌘` screen edge). The element under the pointer is outlined so you know what you'll hit. `↩` click · `⇧↩` double-click · `]` right-click · `=` start a drag, `↩` to drop. |
| `⌃S` | **Scroll** | The area that will scroll gets outlined. `j k` / `h l` scroll, `d u` half a page, `space` a page, `g` / `⇧G` top / bottom. |

Everywhere: `⇧` + arrows scrolls, `esc` gets you out. Labels are read straight from key codes, so it works the same
with a Korean (or any) input source active. If you switch input sources with `⌃Space` and keep holding `⌃`, the next
letter is typed as a letter instead of triggering a mode.

All shortcuts are configurable in **Settings** (click the Poké Ball in the menu bar), along with the language
(English / 한국어) and launch at login.

## The Pokédex

Each click has a chance to summon a Pokémon right where the hint label was — guaranteed on your first click of the
day, then about one in three.

- **Generations unlock in order.** You only meet Gen 1 (Kanto) until you've seen all 151, then Gen 2 (Johto) opens
  up, then Gen 3 (Hoenn). To keep the hunt from dragging on, three out of ten encounters are drawn from the ones you
  haven't met yet.
- **Shinies** show up 1 in 64 times, from any generation you've unlocked, wrapped in a gold outline.
  <br><img src="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/shiny/6.png" width="88" alt="">
- **The Pokédex window** shows every unlocked generation, with separate Normal and ✨ Shiny tabs. Pokémon you haven't
  met are black silhouettes; the ones you have show how many times you've met them. New arrivals get a red dot until
  you open the Pokédex.

Sprites and names come from [PokéAPI](https://pokeapi.co) and are downloaded on first use into
`~/Library/Caches/Pokey`. None of them are shipped in this repository.

## Install

Requires macOS 13 or later and a Swift 5.9+ toolchain (Xcode or the command line tools).

```sh
git clone https://github.com/OdysseyJ/pokey.git
cd pokey
./build.sh --install   # builds, signs, copies to /Applications and launches
```

On first launch macOS asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility).
Pokey needs it to read what's on screen and to send clicks.

**Signing.** `build.sh` signs ad-hoc by default, which means macOS forgets the Accessibility grant every time you
rebuild. If you have a Developer ID or Apple Development certificate, put its name in `POKEY_SIGN_IDENTITY` or in a
git-ignored `.signing-identity` file and the grant survives rebuilds:

```sh
echo "Developer ID Application: Your Name (TEAMID)" > .signing-identity
```

## How it works

- A **CGEvent tap** watches for the shortcuts and, while a mode is active, swallows keystrokes before any input method
  sees them.
- The **Accessibility API** walks the front app's windows, menu bar, open menus and every app's status items to find
  clickable elements. Electron and Chromium apps get `AXManualAccessibility` / `AXEnhancedUserInterface` switched on
  when they come to the front, so their trees are ready by the time you press the shortcut.
- A transparent, click-through **overlay window** per display draws the labels, grid and outlines above the menu bar.
- Clicks are synthesized with `CGEvent` mouse events, so they behave like real clicks.

Debug helpers: `.build/release/Pokey --dump <bundle id>` prints how many targets Pokey finds in an app (add
`REGION=x,y,w,h` to list the ones inside a rectangle), and
`defaults write com.seongwoon.hintclick forceShinyNext -bool true` makes the next pop a shiny without recording it.

## Credits

- Inspired by [Homerow](https://www.homerow.app) and [Scoot](https://github.com/mjrusso/scoot).
- [PokéAPI](https://pokeapi.co) and its [sprites](https://github.com/PokeAPI/sprites) repository.

Pokémon and Pokémon character names are trademarks of Nintendo, Creatures Inc. and GAME FREAK Inc. Pokey is an
unofficial fan project and is not affiliated with or endorsed by them.

## License

[MIT](LICENSE)
