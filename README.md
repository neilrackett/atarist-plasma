# Atari ST Mega Plasma

Have you ever dreamed of displaying 3,000 colours on screen at once on your Atari STE? Well, a mere 37 years after the STE was released, here's a scanline-blasting plasma demo that will bring your dream to life.

Enjoy!

## Apps

### PLASMA1.TOS

<video src="https://github.com/user-attachments/assets/2058cbde-a425-426b-ab5a-0f65dfe67e24" width="640" height="400" muted autoplay loop></video>

Computes and renders a range of ~3,000 colour gradients on any Atari STE or Mega STE (or hundreds of colours on a regular ST)

- 1-4: Select visualisation
- Space: Next visualisation
- Esc: Quit

### PLASMA2.TOS

<video src="https://github.com/user-attachments/assets/ef482a9b-0fc9-4d5d-a82f-7b0813171eec" width="640" height="400" muted autoplay loop></video>

Animated 3x3 gradient for ~Atari Mega STE~ any ST, STE or Mega STE

- Esc: Quit

### IMAGE4K1.TOS, IMAGE4K2.TOS, IMAGE4K3.TOS

<img src="./docs/image4k3.png" width="640" height="400" />

To see if I could replicate Spectrum 512's palette tricks to display images in the STE's full 4096 colours, I created 3 photo viewers that implement up to 3 palettes per scanline, giving us 16, 32 or 48 colours on every row, or up to 3,200, 6,400 or 9,600 colour options per picture. `IMAGE4K1` is solid, `IMAGE4K2` and `IMAGE4K3` are experimental; see [src/image4k](src/image4k/README.md) for the details.

- Space / Return: Next picture
- ← / →: Nudge the beam phase
- Esc: Quit

## Source

Each app has its own folder in `src`, and code they share is in `src/shared`:

- `src/plasma1`: PLASMA1.TOS
- `src/plasma2`: PLASMA2.TOS
- `src/image4k`: IMAGE4K1.TOS, IMAGE4K2.TOS and IMAGE4K3.TOS
- `src/shared`: Mega STE detection and 16MHz/cache control

## Build

The quickest way to build this for yourself is to install [atarist-toolkit-docker](https://github.com/sidecartridge/atarist-toolkit-docker) and run:

```sh
stcmd make
```

Outputs `PLASMA1.TOS`, `PLASMA2.TOS`, `IMAGE4K1.TOS`, `IMAGE4K2.TOS` and `IMAGE4K3.TOS` in the `dist` folder.

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
