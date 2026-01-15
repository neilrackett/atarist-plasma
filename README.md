# Atari ST Mega Plasma

Have you ever dreamed of displaying 3,000 colours on screen at once on your Atari STE? Well, a mere 37 years after the STE was released, here's a scanline-blasting plasma demo that will bring your dream to life.

Enjoy!

## Apps

### PLASMA1.TOS

https://github.com/user-attachments/assets/2058cbde-a425-426b-ab5a-0f65dfe67e24

Computes and renders a range of ~3,000 colour gradients on any Atari STE or Mega STE (or hundreds of colours on a regular ST)

- 1-4: Select visualisation
- Space: Next visualisation
- Esc: Quit

### PLASMA2.TOS

https://github.com/user-attachments/assets/ef482a9b-0fc9-4d5d-a82f-7b0813171eec

Animated 3x3 gradient for Atari Mega STE (runs on ST/STE, but flickers badly)

- Esc: Quit

## Build

The quickest way to build this for yourself is to install [atarist-toolkit-docker](https://github.com/sidecartridge/atarist-toolkit-docker) and run:

```sh
stcmd make
```

Outputs `PLASMA1.TOS` and `PLASMA2.TOS` in the `build` folder.

## License

BSD 2-Clause License
