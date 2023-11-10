# meta-tedge-bin

`Meta-tedge-bin` is Openembedded layer of [thin-edge.io](https://github.com/thin-edge/thin-edge.io) that uses precompiled binaries.

# Dependencies

This layer depends on:

* Poky
* meta-oe -> part of meta-openembedded
* meta-python -> part of meta-openembedded
* meta-networking -> part of meta-openembedded

# Support

This layer supports: 

- Architectures:
    * aarch64 / arm64
    * armv6
    * armv7
    * x86_64 / amd64
- Init-managers:
    * OpenRC (requires [meta-openrc](https://github.com/jsbronder/meta-openrc) layer)
    * Sysvinit
    * Systemd

# Quick install

1. Download all needed layers
2. source `poky/oe-init-build-env *Your environment directory*`
3. Add needed layers to bblayers.conf
4. Add following line to local.conf: `IMAGE_INSTALL:append = " tedge"`
5. Run `bitbake core-image-minimal`