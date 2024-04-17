
DESCRIPTION = "RAUC bundle generator"

inherit bundle

RAUC_BUNDLE_COMPATIBLE = "${MACHINE}"
RAUC_BUNDLE_VERSION = "v20200703"
RAUC_BUNDLE_DESCRIPTION = "RAUC Demo Bundle"

RAUC_BUNDLE_FORMAT = "verity"

RAUC_BUNDLE_SLOTS = "rootfs" 
RAUC_SLOT_rootfs ?= "core-image-tedge-rauc"
RAUC_SLOT_rootfs[fstype] = "ext4"

RAUC_KEY_FILE ?= "${THISDIR}/files/development-1.key.pem"
RAUC_CERT_FILE ?= "${THISDIR}/files/development-1.cert.pem"

# Hooks
# see: https://github.com/rauc/meta-rauc/issues/185
SRC_URI += " file://hook.sh"
RAUC_BUNDLE_HOOKS[file] = "hook.sh"
RAUC_BUNDLE_HOOKS[hooks] = "post-install"
#RAUC_SLOT_rootfs[hooks] = "post-install"
