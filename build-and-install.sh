#!/bin/bash
# Builds PipeWire's Bluetooth SPA plugin (libspa-bluez5.so) for the INSTALLED PipeWire version with the patches from
# ./patches and installs it for the current user only. No system file is changed:
#   ~/.local/lib/spa-0.2-patched/bluez5/libspa-bluez5.so
#   ~/.config/systemd/user/wireplumber.service.d/spa-bluez5-fix.conf   (makes WirePlumber look there first)
# Needs: git, meson, ninja, a C compiler, pkg-config, gdbus-codegen (glib2 development files) and the development
# files of bluez, sbc, dbus, glib2, libusb, opus and lc3 (liblc3).
#   Arch/CachyOS: sudo pacman -S --needed git meson ninja gcc pkgconf glib2-devel bluez-libs sbc libusb opus liblc3
# Usage: ./build-and-install.sh            build, install, restart WirePlumber
#        NO_INSTALL=1 ./build-and-install.sh   build only
# Undo:  rm ~/.config/systemd/user/wireplumber.service.d/spa-bluez5-fix.conf
#        systemctl --user daemon-reload && systemctl --user restart wireplumber
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
VER=${PIPEWIRE_VERSION:-$(pipewire --version | awk '/Compiled with/{print $NF}')}
[ -n "$VER" ] || { echo "cannot detect the PipeWire version; set PIPEWIRE_VERSION=x.y.z"; exit 1; }
WORK=${WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/pipewire-hfp-atbcc-fix}
SRC=$WORK/pipewire-$VER
echo "== PipeWire $VER, working directory $WORK"
mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
	git clone --depth 1 --branch "$VER" https://gitlab.freedesktop.org/pipewire/pipewire.git "$SRC"
fi
cd "$SRC"
git checkout -q -f "$VER"
for p in "$HERE"/patches/*.patch; do
	if git apply --check "$p" 2>/dev/null; then
		git apply "$p"; echo "applied: $(basename "$p")"
	elif git apply --reverse --check "$p" 2>/dev/null; then
		echo "already in this version, skipped: $(basename "$p")"
	else
		echo "!! does not apply to PipeWire $VER: $(basename "$p")"; exit 1
	fi
done
rm -rf build
meson setup build --prefix=/usr --buildtype=release -Dauto_features=disabled -Dspa-plugins=enabled -Dbluez5=enabled \
	-Dbluez5-backend-hsp-native=enabled -Dbluez5-backend-hfp-native=enabled -Dbluez5-backend-ofono=enabled \
	-Dbluez5-backend-hsphfpd=enabled -Dbluez5-codec-lc3=enabled -Dbluez5-codec-opus=enabled -Dopus=enabled \
	-Dlibusb=enabled -Ddbus=enabled -Dtests=disabled -Dexamples=disabled -Dsession-managers='[]' >/dev/null
ninja -C build spa/plugins/bluez5/libspa-bluez5.so
OUT=$SRC/build/spa/plugins/bluez5/libspa-bluez5.so
echo "== built: $OUT"
[ -n "$NO_INSTALL" ] && exit 0

DEST=$HOME/.local/lib/spa-0.2-patched/bluez5
SYS=$(dirname "$(dirname "$(find /usr/lib /usr/lib64 -path '*spa-0.2/bluez5/libspa-bluez5.so' 2>/dev/null | head -1)")")
[ -n "$SYS" ] || { echo "cannot find the system spa-0.2 plugin directory"; exit 1; }
install -Dm755 "$OUT" "$DEST/libspa-bluez5.so"
mkdir -p ~/.config/systemd/user/wireplumber.service.d
cat > ~/.config/systemd/user/wireplumber.service.d/spa-bluez5-fix.conf <<CONF
# Patched PipeWire Bluetooth plugin built for PipeWire $VER (pipewire-hfp-atbcc-fix).
# Remove this file after a PipeWire upgrade, then re-run build-and-install.sh if the bug is still there.
[Service]
Environment=SPA_PLUGIN_DIR=$HOME/.local/lib/spa-0.2-patched:$SYS
CONF
systemctl --user daemon-reload
systemctl --user restart wireplumber
echo "== installed. Reconnect the headset once (its A2DP profile is missing after a WirePlumber restart)."
