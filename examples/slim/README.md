Build a small system with minimum base packages.

Contains a custom image layout and a custom device dir.

```text
examples/slim/
|-- device
|   `-- mypi5
|       |-- post-build.sh
|       `-- rootfs-overlay
|           |-- boot
|           |   `-- firmware
|           |       `-- cmdline.txt
|           `-- etc
|               `-- fstab
|-- config
|   `-- pi5-slim.cfg
|-- image
|   `-- compact
|       |-- genimage.cfg.in
|       `-- pre-image.sh
|-- meta
|   `-- slim-customisations.yaml
|-- my.options
|-- profile
|   `-- v8-svelte
`-- README.md
```

```bash
./build.sh -D ./examples/slim/ -c pi5-slim -o ./examples/slim/my.options
```
