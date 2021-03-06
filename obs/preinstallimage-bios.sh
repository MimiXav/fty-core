#!/bin/bash
#
#   Copyright (c) 2014-2018 Eaton
#
#   This file is part of the Eaton 42ity project.
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License along
#   with this program; if not, write to the Free Software Foundation, Inc.,
#   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
#! \file    preinstallimage-bios.sh
#  \brief   Script to generate the expected directory structure and configuration files
#  \author  Michal Hrusecky <MichalHrusecky@Eaton.com>
#  \author  Jim Klimov <EvgenyKlimov@Eaton.com>
#  \details Script to generate the expected directory structure
#   and configuration files "baked into" the read-only OS images that
#   are prepared by OBS for dev/test X86 containers as well as the
#   ultimate RC3 environments. Any changes to the files "hardcoded"
#   here can be applied by the deployed systems either as overlay
#   filesystem or unpacked tarballs.
#
#   This code used to be part of a spec-like file hidden in the OBS
#   job setup - now the code part can be tracked in common Git sources.
#   Note there are also spec-headers with different BuildRequires and
#   BuildIgnore sets of Debian packages for different OS image types,
#   which are still parts of the "hidden" OBS _preinstallimage recipes.
#
#   Also note that some parts of the setup here are geared towards
#   internal dev-test deployments in Eaton network, at the moment.
#
#   This script is executed in the chroot'ed filesystem tree prepared
#   by OBS installation of packages, including the 42ity core package.
#   It is called as the "%build" recipe implementation from the OBS
#   specfile, with an IMGTYPE envvar pre-set to "devel" or "deploy".

echo "INFO: Executing $0 $*"
echo "    IMGTYPE='$IMGTYPE'"

# Protect against errors... such as maybe running on a dev workstation
set -e

# Setup core dumps
if true; then
    mkdir -p /var/crash
    chmod 1777 /var/crash
    ( echo 'kernel.core_pattern = /var/crash/%t-%e-%s.core'
      echo 'fs.suid_dumpable = 2' \
    ) > /etc/sysctl.d/10-core.conf
    sed -i 's|.*DefaultLimitCORE=.*|DefaultLimitCORE=infinity|' /etc/systemd/system.conf
    sed -i 's|.*DumpCore=.*|DumpCore=yes|' /etc/systemd/system.conf
fi

# We set bash HISTORY in /etc/profile.d (see below) and mark it readonly
# Note: This must be done before user accounts (and homes) are created
mkdir -p /etc/profile.d
sed -e 's/^\([ \t]*HIST.*=.*\)$/###\1/' \
    -e 's/^\([ \t]*set -o hist.*\)$/###\1/' \
    -e 's/^\([ \t]*shopt.* hist.*\)$/###\1/' \
    -i /etc/skel/.bashrc -i /root/.bashrc

( echo ""; echo ""; echo "" ) > /etc/skel/.bash_history
[ -s /root/.bash_history ] || ( echo ""; echo ""; echo "" ) > /root/.bash_history
chmod 600 /etc/skel/.bash_history /root/.bash_history

# Create user and set root password
passwd <<EOF
@PASSWORD@
@PASSWORD@
EOF

# NOTE: This is the name in debian; for other distros it may be different
SASL_GROUP=sasl
groupadd -g 8003 bios-admin
groupadd -g 8002 bios-poweruser
groupadd -g 8001 bios-user
groupadd -g 8000 bios-dash
groupadd -g 8004 bios-infra
groupadd -g 7999 bios-logread

useradd -m bios -N -g bios-infra -G dialout -s /bin/bash
mkdir -p /home/bios && chown bios:bios-infra /home/bios

# Create a GPIO group to access GPIO pins, and add the user bios
groupadd --system -f gpio
usermod -G gpio -a bios

# add an access to sasl, bios-logread (for /var/log/messages) and systemd journal
# note that earlier OS images had custom logs owned by "adm" group, so we also
# support it for admin account at this time (so that upgraders can read old logs)
useradd -m admin -G "${SASL_GROUP}",adm,bios-logread,systemd-journal -N -g bios-admin -s /bin/bash
passwd admin <<EOF
admin
admin
EOF
mkdir -p /home/admin && chown admin:bios-admin /home/admin

# add an access to bios-logread (for /var/log/messages) to webserver
usermod -G bios-logread -a www-data

# add an access to sasl for bios
usermod -G "${SASL_GROUP}" -a bios

# TODO: See if "sudo"able tasks that this account may have to do can be done
# with another shell like /bin/nologin or /bin/false - and then secure it...
if ! getent passwd monitor ; then
    useradd -m monitor -G "$SASL_GROUP" -N -g bios-dash -s /bin/bash
    passwd monitor <<EOF
monitor
monitor
EOF
fi
mkdir -p /home/monitor && chown monitor:bios-dash /home/monitor

# _bios-script user - special user allowing us to call REST API from scripts
useradd -m _bios-script -N -g bios-admin -G sasl -s /usr/sbin/nologin

# Workplace for the webserver and graph daemons
if [ -d /var/lib/bios ]; then
    chown -R www-data /var/lib/bios || true
    if [ -d /var/lib/fty ]; then
        NUMOBJ="$(cd /var/lib/bios && find . | wc -l)" || NUMOBJ=-1
        if [ "$NUMOBJ" -gt 1 ]; then
            ( cd /var/lib/bios && mv -f `ls -1A` /var/lib/fty )
        fi
        rm -rf /var/lib/bios
    else
        mv /var/lib/bios /var/lib/fty
    fi
fi
mkdir -p /var/lib/fty
# webserver needs to store license file, currently in root of /var/lib/fty
chown www-data /var/lib/fty
# Legacy link just in case
# TODO: Verify on a rack controller that this can be overlaid by existing
# directories (from older-version installations).
ln -sfr /var/lib/fty /var/lib/bios

# The bios-boot::init script assumes only the first line of /etc/issue to be useful
cat > /etc/issue << EOF
\S{NAME} \S{VERSION_ID} \n \l@\b ; Current IP(s): \4{eth0} \4{eth1} \4{eth2} \4{eth3} \4{LAN1} \4{LAN2} \4{LAN3}
EOF

# 42ity configuration file
mkdir -p /etc/default
# Common envvars for systemd services, primarily
touch /etc/default/fty
chown www-data /etc/default/fty
chmod 644 /etc/default/fty
# ZConfig default settings, if populated
touch /etc/default/fty.cfg
chown www-data /etc/default/fty.cfg

if diff /usr/libexec/fty/systemctl /usr/libexec/fty/journalctl >/dev/null 2>&1 ; then
    if [ ! -L /usr/libexec/fty/systemctl ] && [ ! -L /usr/libexec/fty/journalctl ] ; then
        rm -rf /usr/libexec/fty/journalctl && ln -s ./systemctl /usr/libexec/fty/journalctl
    fi
fi

# workaround - we need to change agents configuration from REST API config call
# so let tntnet touch the files
# FIXME: Limit this to specific pathnames or patterns, e.g.
#   find ... | egrep 'bios|fty' | xargs ... ???
for cfg in $(find /etc/ -maxdepth 2 -name '*.cfg' | xargs grep 'verbose =' | cut -d ':' -f1 | sort -u | grep -v malamute); do
    chown www-data "${cfg}"
done

# NOTE: /usr/lib/systemd/tmpfiles.d/ is a legacy fallback:
# we used this location before, and some of our packages
# still deliver their configs there until fixed/rebuilt.
for conf in $(find /usr/lib/tmpfiles.d/*.conf) $(find /usr/lib/systemd/tmpfiles.d/*.conf || true); do
    systemd-tmpfiles --create "${conf}"
done

# LEGACY PROBLEM NOTE: note that (older) uImage::init can reference
# the legacy path too, so we create the symlink here regardless of
# ipc-meta-setup.sh used for most of legacy links during first boot -
# these particular paths we may need in RO OS image archives already.
# Same problem holds for generate-release-details script and some other
# paths; also the macro PACKAGE==bios is due to configure.ac currently
# in both fty-core and fty-rest.
if [ -d /usr/share/bios -a ! -d /usr/share/fty ] ; then
    mv /usr/share/bios /usr/share/fty && \
    ln -srf /usr/share/fty /usr/share/bios || true
fi

if [ -d /usr/libexec/bios -a ! -d /usr/libexec/fty ] ; then
    mv /usr/libexec/bios /usr/libexec/fty && \
    ln -srf /usr/libexec/fty /usr/libexec/bios || true
fi

# Support zproject-ized fty-rest deliverables
for D in /usr/libexec /usr/lib /usr/share ; do
    for S in "" x86_64-linux-gnu arm-linux-gnueabihf ; do
        if [ -d "$D/$S/fty-rest" ] ; then
        ( cd "$D/$S/fty-rest" && \
          find . -type d -exec mkdir -p "$D"/bios/'{}' \; && \
          find . -type f -exec ln -srf '{}' "$D"/bios/'{}' \; && \
          find . -type l -exec ln -srf '{}' "$D"/bios/'{}' \;
        ) || exit
        fi
    done
done

# Setup 42ity lenses
mkdir -p /usr/share/fty/lenses
ln -sr /usr/share/augeas/lenses/dist/{build,ethers,interfaces,ntp,ntpd,pam,resolv,rx,sep,util,shellvars}.aug \
    /usr/share/fty/lenses

# Setup u-Boot
echo '/dev/mtd3 0x00000 0x40000 0x40000' > /etc/fw_env.config

# journald setup
sed -i 's|.*RuntimeMaxFileSize.*|RuntimeMaxFileSize=10M|' /etc/systemd/journald.conf
sed -i 's|.*Storage.*|Storage=volatile|'                  /etc/systemd/journald.conf

# rsyslogd setup
mkdir -p /etc/rsyslog.d /etc/rsyslog.d-early /var/spool/rsyslog
# the rsyslogd.conf "$WorkDirectory"
chmod 700 /var/spool/rsyslog
## remove conflicting Debian defaults
echo '$IncludeConfig /etc/rsyslog.d-early/*.conf' > /etc/rsyslog.conf.tmp
awk '{ print $0; } /^\$IncludeConfig/{ exit; }' </etc/rsyslog.conf >>/etc/rsyslog.conf.tmp && \
sed -i 's/^\$FileGroup.*$/\$FileGroup bios-logread/' /etc/rsyslog.conf.tmp && \
mv -f /etc/rsyslog.conf.tmp /etc/rsyslog.conf

## avoid "localhost" as the original host ID in logs
## this may need to be set before loading modules, so it is "early"
echo '$PreserveFQDN on' > /etc/rsyslog.d-early/00-PreserveFQDN.conf

## normal logging
cp /usr/share/fty/examples/config/rsyslog.d/10-ipc.conf /etc/rsyslog.d/

## remote logging template - changeable by end-user admins
cp /usr/share/fty/examples/config/rsyslog.d/08-ipc-remote.conf /etc/rsyslog.d/
chown root:bios-admin /etc/rsyslog.d/08-ipc-remote.conf
chmod 0660 /etc/rsyslog.d/08-ipc-remote.conf

# persistent TH naming
cp /usr/share/fty/examples/config/rules.d/90-ipc-persistent-th.rules /lib/udev/rules.d/

## Removable media mounting point for bios-admin group
mkdir -p /mnt/USB
chown root:bios-admin /mnt/USB
chmod 0770 /mnt/USB
ln -s mount_usb /usr/libexec/fty/umount_usb

# Basic network setup
mkdir -p /etc/network

cat > /etc/network/interfaces <<EOF
auto lo
allow-hotplug eth0 LAN1 LAN2 LAN3
iface lo inet loopback
iface `file -b /bin/bash | sed -e 's|.*x86-64.*|eth0|' -e 's|.*ARM.*|LAN1|'` inet dhcp
iface LAN2 inet static
    address 192.168.1.10
    netmask 255.255.255.0
    gateway 192.168.1.1
iface LAN3 inet static
    address 192.168.2.10
    netmask 255.255.255.0
    gateway 192.168.2.1
EOF

cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

cat > /etc/hosts <<EOF
127.0.0.1 localhost bios
EOF

DEFAULT_IFPLUGD_INTERFACES="eth0 LAN1 LAN2 LAN3"
mkdir -p /etc/default
[ -s "/etc/default/networking" ] && \
    sed -e 's,^[ \t\#]*\(EXCLUDE_INTERFACES=\)$,\1"'"$DEFAULT_IFPLUGD_INTERFACES"'",' -i /etc/default/networking \
    || echo 'EXCLUDE_INTERFACES="'"$DEFAULT_IFPLUGD_INTERFACES"'"' >> /etc/default/networking
cat > /etc/default/ifplugd <<EOF
INTERFACES="$DEFAULT_IFPLUGD_INTERFACES"
HOTPLUG_INTERFACES=""
ARGS="-q -f -u0 -d10 -w -I"
SUSPEND_ACTION="stop"
EOF


# Setup APT package sources
# Note: do not change the 'Pool\:/master' reference below because it may be
# substituted to corresponding actual repository during OBS image creation.
mkdir -p /etc/apt/sources.list.d
cat > /etc/apt/sources.list.d/debian.list <<EOF
deb http://ftp.debian.org/debian jessie main contrib non-free
deb http://ftp.debian.org/debian jessie-updates main contrib non-free
deb http://security.debian.org   jessie/updates main contrib non-free
deb http://obs.roz.lab.etn.com:82/Pool:/master/Debian_8.0 /
deb http://obs.roz.lab.etn.com:82/Pool:/master:/proprietary/Debian_8.0 /
EOF

mkdir -p /etc/apt/preferences.d
cat > /etc/apt/preferences.d/bios <<EOF
Package: *
Pin: origin "obs.roz.lab.etn.com"
Pin-Priority: 9999
EOF

cat << EOF | apt-key add -
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v2

mQGiBFafdbgRBACOJ2v+OPLFEIVSLDnibtuRUplIJFHHdHMn2PMPsYzxX67X/Liu
kk6nF+mNJsObLTHsPk99l3Qctt5Qn4MOspylVv/ieoiacs1qhcvVtpFv9V6rCjhn
ZBi5YgXdiXk5Vp9N2nSqkUKdE+ycBf3ks6gaE517SO6KAxZtG6I3v0ychwCgyqo6
xQh0xBAuan0bZCeD3QXMNGcD/3DPiw+1fluUv1j0SmhDwfqTkWI9yIDitDljx1AJ
vD/icREUVck907YCASVOgbM8hBKhABOOx22u6YtSVxMCAwnm6m9wwxvxILjjVajs
i8s44X6ng3ia2AzQgH2mwU2DOKFPTbcmkExCEwejH5Ef4k3DSfzaDcznmSDN4fNL
0VEcA/4iRR7kOt5p05Fm//Ob826MCD7BVsnikgVAQrks8omh/f/SgwNNwxLMziY0
JnJw0E9lK711FcxgZNnk4xxwHEnPjkVpFV18A+b+ldwhZ8I05Pw6Okr/f47MF9/O
pDlLPC6Va/c18v5hTIckRrBOh2nzPyJH7gKhTXCEFautYLOldbQ6cHJpdmF0ZSBP
QlMgKGtleSB3aXRob3V0IHBhc3NwaHJhc2UpIDxkZWZhdWx0a2V5QGxvY2Fsb2Jz
PohjBBMRAgAjBQJWn3W4AhsjBwsJCAcDAgEGFQgCCQoLBBYCAwECHgECF4AACgkQ
Myo8Ka8xTGhsnQCeMIzLSpdZG+zIaN4LtSeY/uS66+IAn0QOuM+EeK7ojKCkhTGY
Pcz3AHDquQENBFafdbgQBADzEHRnwTweK2cWT1pwoiNYbHkvksA1FicuUEhIEudd
tZE2VmbkvPnhFTzuC3vMq2znVITE68LifArovqPCk538jrs/g3Rz1e+540Ccq/QY
O2i5qJTQAD6TltNvnbR3juA0t9Pf8dp9OcpxD0sZeCt8qxcl/aEuAaEzXSFntmgI
rwADBQQAzDN3MN3YtaRhtJgzvYLjiIocejKBRadRKjudcIGEM+dltfQeYIwyZR1y
TItx3zoioTwRvJw6y51HPn2liyMRRAcql1IAqJv7Hbvg38aj9abQ3MDbvp1kzGFK
HABTa6I/DpREO2X35UnqJ91LYzRx26DC4PNHanGx4ZqgIRiLwyKISQQYEQIACQUC
Vp91uAIbDAAKCRAzKjwprzFMaD2ZAJ9uGAv1l4o1X88jpBT6wOUSX+3vHgCePkle
wscGBRaOr9hO4FqPjem8H6s=
=sSgW
-----END PGP PUBLIC KEY BLOCK-----
EOF

# Uninstall various packages that are not needed
# Note: We restore "/bin/diff" and "/bin/*grep" via busybox, below
for i in $(dpkg -l | awk '/perl/{ print $2; }') apt fakeroot ncurses-bin diffutils grep sysvinit ncurses-common lsb-release; do
    case "$IMGTYPE" in
        *devel*)
            echo dpkg -P --force-all $i
            ;;
        deploy|*)
            dpkg -P --force-all $i
            ;;
    esac
done

# Fetch metadata for quicker possible later installations
case "$IMGTYPE" in
    *devel*)
        apt-get update || true
        ;;
esac

# Setup all the busybox commands, if they're not provided by different package
busybox --install -s

# Original Debian /usr/sbin/update-rc.d tool is a script implemented in Perl.
# Replace it with our shell equivalent if Perl is not available, so that the
# Debian systemd can cover services still implemented via /etc/init.d scripts.
if [ ! -x /usr/bin/perl ] && [ -x /usr/share/fty/scripts/update-rc.d.sh ] && \
    head -1 /usr/sbin/update-rc.d | grep perl >/dev/null \
; then
    echo "Replacing perl version of /usr/sbin/update-rc.d with a shell implementation" >&2
    rm -f /usr/sbin/update-rc.d || true
    install -m 0755 /usr/share/fty/scripts/update-rc.d.sh /usr/sbin/update-rc.d
else
    echo "NOTE: Keeping the perl version of /usr/sbin/update-rc.d in place" >&2
fi

# Setup 42ity security
mkdir -p /etc/pam.d
cp /usr/share/fty/examples/config/pam.d/* /etc/pam.d
case "$IMGTYPE" in
    *devel*) ;;
    *) sed -i "s|\\(.*pam_cracklib.so\\).*|    password\tinclude\t\tfty-password|" /etc/pam.d/common-password ;;
esac

# Force creation of cracklib dictionary
if [ ! -f /var/cache/cracklib/cracklib_dict.pwd ]; then
    /usr/sbin/update-cracklib
fi

sed -i 's|\(secure_path="\)|\1/usr/libexec/fty:|' /etc/sudoers

mkdir -p /etc/sudoers.d
cp /usr/share/fty/examples/config/sudoers.d/fty_00_base /etc/sudoers.d
case "$IMGTYPE" in
    *devel*) cp /usr/share/fty/examples/config/sudoers.d/fty_01_citest /etc/sudoers.d ;;
esac
cp /usr/share/fty/examples/config/sudoers.d/fty_*_*agent* /etc/sudoers.d || true

mkdir -p /etc/security
cp /usr/share/fty/examples/config/security/* /etc/security

# Problem: Debian patched systemctl crashes on enable if perl is not installed
# Solution: provide systemd unit to not invoke the update-rc.d Perl script
# Note: now we provide our own shell re-implementation of that script, but
# if we have a native systemd unit - better keep it if it works, right? ;)
sed -i 's|START=no|START=yes|' /etc/default/saslauthd
rm -f /etc/init.d/saslauthd
cat <<EOF > /lib/systemd/system/saslauthd.service
[Unit]
Description=SASL Authentication Daemon

[Service]
Type=forking
EnvironmentFile=/etc/default/saslauthd
ExecStart=/usr/sbin/saslauthd -a \$MECHANISMS \$MECH_OPTIONS \$OPTIONS -n \$THREADS
ExecStop=/bin/kill -15 \$MAINPID
PIDFile=/var/run/saslauthd/saslauthd.pid

[Install]
WantedBy=multi-user.target
EOF
/bin/systemctl enable saslauthd

mkdir -p /etc/update-rc3.d
cp /usr/share/fty/examples/config/update-rc3.d/* /etc/update-rc3.d
[ -n "$IMGTYPE" ] && \
    echo "IMGTYPE='$IMGTYPE'" > /etc/update-rc3.d/image-os-type.conf

# Disable systemd-timesyncd - ntp is enough
/bin/systemctl mask systemd-timesyncd.service

# Enable ssh
rm /etc/init.d/ssh*
echo "UseDNS no" >> /etc/ssh/sshd_config
rm /etc/ssh/*key*
mkdir -p /etc/systemd/system
sed 's|\[Service\]|[Service]\nExecStartPre=/usr/bin/ssh-keygen -A|' /lib*/systemd/system/ssh@.service > /etc/systemd/system/ssh@.service
sed -i 's|\[Unit\]|[Unit]\nConditionPathExists=/var/lib/fty/license\nConditionPathExists=/mnt/nand/overlay/etc/shadow|' /etc/systemd/system/ssh@.service
/bin/systemctl disable ssh.service
/bin/systemctl mask ssh.service
/bin/systemctl enable ssh.socket

# Workaround nutscanner's ldopen
[ -s /usr/lib/libnetsnmp.so ] || \
    ln -sfr /usr/lib/*/libnetsnmp.so.*.* /usr/lib/libnetsnmp.so
[ -s /usr/lib/libupsclient.so ] || \
    ln -sfr /lib/*/libupsclient.so.*.*   /lib/libupsclient.so
[ -s /usr/lib/libusb.so ] || \
    ln -sfr /lib/*/libusb-*.so.*.*       /lib/libusb.so
[ -s /usr/lib/libneon.so ] || \
    ln -sfr /usr/lib/libneon.so.*.*      /usr/lib/libneon.so

# Enable malamute with 42ity configuration
mkdir -p /etc/malamute
cp /usr/share/fty/examples/config/malamute/malamute.cfg /etc/malamute
/bin/systemctl enable malamute

# Enable 42ity services (distributed as a systemd preset file)
/bin/systemctl preset-all
if [ "`uname -m`" = x86_64 ]; then
    /bin/systemctl disable lcd-boot-display
    /bin/systemctl disable lcd-net-display
    /bin/systemctl disable lcd-shutdown-display || true
    /bin/systemctl disable lcd-shutdown-inverse-display || true
    /bin/systemctl disable lcd-reboot-display || true
    /bin/systemctl disable lcd-poweroff-display || true
    /bin/systemctl mask lcd-boot-display
    /bin/systemctl mask lcd-net-display
    /bin/systemctl mask lcd-shutdown-display || true
    /bin/systemctl mask lcd-shutdown-inverse-display || true
    /bin/systemctl mask lcd-reboot-display || true
    /bin/systemctl mask lcd-poweroff-display || true
    /bin/systemctl disable bios-reset-button
    /bin/systemctl mask bios-reset-button
else
    /bin/systemctl enable lcd-boot-display
    /bin/systemctl enable lcd-net-display
    /bin/systemctl enable lcd-shutdown-display || true
    /bin/systemctl enable lcd-shutdown-inverse-display || true
    /bin/systemctl enable lcd-reboot-display || true
    /bin/systemctl enable lcd-poweroff-display || true
    #sed -i 's|PathChanged=/etc|PathChanged=/mnt/nand/overlay/etc|' /usr/lib/systemd/system/composite-metrics\@.path
fi

# Disable and mask the vendor-packaged mysql services - the database will
# be started after first boot and license acceptance, and wrapped by our
# own fty-db-engine customized service anyway.
/bin/systemctl mask mysql
/bin/systemctl disable mysql

# Our tntnet unit rocks, disable packaged default
if [ -s /lib/systemd/system/fty-tntnet@.service ]; then
    /bin/systemctl disable tntnet.service
    /bin/systemctl disable tntnet@.service
    rm -f /etc/init.d/tntnet || true
    rm -f /lib/systemd/system/tntnet@.service || true
    mv /lib/systemd/system/fty-tntnet@.service /lib/systemd/system/tntnet@.service
fi

# Generally enable everything fty-* (and related)
# Note: we do not unmask here, because if anyone went through the
# non-default trouble of masking, it must have had a reason :)
for unit in $(/bin/systemctl list-unit-files | egrep '^(fty|etn|ipc|ipm|ova)-*' | cut -d ' ' -f 1); do
    ### Note: some units declare Alias= names to be called by
    ### These names are returned among "systemctl list-unit-files" but since
    ### there are no actual files by that name, they can not be enabled!
    ### Also note we do not skip these units, because they may be our product's
    ### ways to manage a unit distributed with some naming pattern not matched
    ### above. Another fallback logic handles the case where systemctl is just
    ### "Running in chroot, ignoring request."
    unit_realname="$(/bin/systemctl show -p Id "${unit}" | sed 's,^Id=,,')" \
        && [ -n "${unit_realname}" ] || unit_realname="${unit}"
    if [ -n "$(ls -1d {/usr,}/lib/systemd/system/${unit} 2>/dev/null)" ]; then
        ### A masked unit can fail to become "enabled", and
        ### we don't want it to - so just ignore the errors :\
        /bin/systemctl enable ${unit_realname} || true
    else
        echo "SKIP: NOT ENABLING '${unit_realname}' because corresponding distributed file was not found" >&2
    fi
done

# Enable REST API via tntnet
# Note: for legacy reasons, we still maintain tntnet@bios.service (not @fty)
mkdir -p /etc/tntnet/bios.d
# Note: Here we only expect one file, e.g. /usr/share/fty/examples/tntnet.xml.example :
cp /usr/share/fty-rest/examples/tntnet.xml.* /etc/tntnet/bios.xml

sed -i 's|.*<allUserGroups>.*|<allUserGroups>yes</allUserGroups>|' /etc/tntnet/bios.xml || true
sed -e 's|<!--.*<user>.*|<user>www-data</user>|' \
    -e 's|<!--.*<group>.*|<group>'"${SASL_GROUP}"'</group>|' \
    -e 's|.*<daemon>.*|<daemon>0</daemon>|' \
    -e 's|\(.*\)<dir>.*|\1<dir>/usr/share/bios-web/</dir>|' \
    -e 's|<!--.*<sslProtocols>.*|<sslProtocols>-TLSv1_0</sslProtocols>|' \
    -e 's|<!--.*<sslCipherList>.*|<sslCipherList>HIGH:!aNULL:!3DES</sslCipherList>|' \
    -i /etc/tntnet/bios.xml

# Leave a backup template file
cp /etc/tntnet/bios.xml /usr/share/fty/examples/bios.xml.default

# Put aside structural head and tail of the config file
sed -n '1,/<mappings>/ p' /etc/tntnet/bios.xml  > /etc/tntnet/bios.d/00_start.xml
sed -n '/<\/mappings>/,$ p' /etc/tntnet/bios.xml > /etc/tntnet/bios.d/99_end.xml

# Separate the servlet mappings to dissect even more
sed '/<mappings>/,/<\/mappings>/!d; /mappings/ d' \
    /etc/tntnet/bios.xml > /etc/tntnet/bios.d/20_core.xml.tmp
# Static file mappings, caching setup:
sed '1,/<!-- Make sure everybody speaks json from now on -->/!d; /<!-- Make sure everybody speaks json from now on -->/ d' \
    /etc/tntnet/bios.d/20_core.xml.tmp > /etc/tntnet/bios.d/10_common_statics.xml
# JSON requirement, auth processing, auth validation
sed '/<!-- Make sure everybody speaks json from now on -->/,$!d; 1,/<!-- Here starts the real API -->/!d; /<!-- Here starts the real API -->/ d' \
    /etc/tntnet/bios.d/20_core.xml.tmp > /etc/tntnet/bios.d/20_common_basics.xml
# The actual diverse API calls of the product
sed '/<!-- Here starts the real API -->/,$!d' \
    /etc/tntnet/bios.d/20_core.xml.tmp > /etc/tntnet/bios.d/50_main_api.xml
rm -f /etc/tntnet/bios.d/20_core.xml.tmp

# Sanity check, excluding files that could be delivered by other packages
cat /etc/tntnet/bios.d/{00_*,10_*,20_*,50_*,99_*}.xml > /tmp/bios.xml && \
diff -bu /etc/tntnet/bios.xml /tmp/bios.xml || { echo "ERROR: bios.xml was sliced incorrectly" >&2; exit 1; }
rm -f /tmp/bios.xml

/bin/systemctl enable tntnet@bios
/bin/systemctl enable fty-envvars

# Disable logind
/bin/systemctl disable systemd-logind
find / -name systemd-logind.service -delete

# Our watchdogs - disable system ones, enable our custom service
# Note that actual service instances work or not based on presence of the
# /dev/watchdogN nodes, so we do not care much about missing devices and
# running in containers - so the services would fail (via unit Condition)
/bin/systemctl disable watchdog.service
/bin/systemctl disable wd_keepalive.service
/bin/systemctl mask wd_keepalive.service
/bin/systemctl enable wd_keepalive@watchdog0.service
/bin/systemctl enable wd_keepalive@watchdog1.service
/bin/systemctl enable wd_keepalive@watchdog2.service
/bin/systemctl enable wd_keepalive@watchdog3.service

# Disable etn-amqp and etn-ipm1 (in such a manner that
# they can be reenabled back in particular deployments):
/bin/systemctl mask etn-amqp
/bin/systemctl disable etn-amqp
/bin/systemctl mask etn-ipm1
/bin/systemctl disable etn-ipm1
# ...and corresponding REST API servlet configurations:
for F in /etc/tntnet/bios.d/*etn-ipm1-rest.xml ; do
    if [ -e "$F" ]; then
        mv -f "$F" "$F.disabled"
    fi
done

# Disable expensive debug logging by default on non-devel images
mkdir -p /usr/share/fty/etc/default
case "$IMGTYPE" in
    *devel*)
        echo "BIOS_LOG_LEVEL=LOG_DEBUG" > /usr/share/fty/etc/default/fty
        echo "BIOS_NUT_USE_DMF=true" >> /usr/share/fty/etc/default/fty
        ;;
    *)
        echo "BIOS_LOG_LEVEL=LOG_INFO" > /usr/share/fty/etc/default/fty
        sed -e 's|.*MaxLevelStore.*|MaxLevelStore=info|' \
            -i /etc/systemd/journald.conf
        ;;
esac
# set path to our libexec directory
echo "PATH=/usr/libexec/fty:/bin:/usr/bin:/sbin:/usr/sbin" >>/usr/share/fty/etc/default/fty

if [ ! -x "/usr/bin/man" -a ! -x "/bin/man" ] ; then
    echo "MAN program not available, killing manpages to save some space" >&2
    # Localizations - kill whole; leave standard mandirs in place but empty
    # NOTE: Not using '-exec rm -rf ...' because then 'find' complains it cannot proceed inspecting the directory
    find "/usr/share/man" -type d \! -name 'man*' | while read D ; do rm -rf "$D" ; done
    find "/usr/share/man" -type f -exec rm -f '{}' \;
fi

# Simplify ntp.conf
augtool -S -I/usr/share/fty/lenses << EOF
rm /files/etc/ntp.conf/server
set /files/etc/ntp.conf/server[1] pool.ntp.org
save
EOF

# 42ity emulator script which can fake some of the curl behaviour with wget
[ ! -x /usr/bin/curl ] && [ -x /usr/share/fty/scripts/curlbbwget.sh ] && \
    install -m 0755 /usr/share/fty/scripts/curlbbwget.sh /usr/bin/curl

#########################################################################
# Setup zabbix
# TODO: revise the list of 42ity services here
if [ -f /usr/bin/zabbix_agent ]; then
for i in mysql tntnet@bios malamute \
    bios-db bios-agent-inventory bios-agent-nut bios-driver-netmon \
    nut-driver nut-monitor systemd-journald \
; do
   find /lib /usr -name "$i".service | while read file; do
       sed -i 's|\(\[Service\]\)|\1\nMemoryAccounting=yes\nCPUAccounting=yes\nBlockIOAccounting=yes|' "$file"
   done
done

sed -i 's|127.0.0.1|greyhound.roz.lab.etn.com|' /etc/zabbix/zabbix_agentd.conf
sed -i 's|^Hostname|#\ Hostname|' /etc/zabbix/zabbix_agentd.conf
# Our network sucks, use longer timeouts
sed -i 's|#\ Timeout.*|Timeout=15|' /etc/zabbix/zabbix_agentd.conf
/bin/systemctl enable zabbix-agent
sed -i 's|\(chown -R.*\)|\1\nmkdir -p /var/log/zabbix-agent\nchown zabbix:zabbix /var/log/zabbix-agent|' /etc/init.d/zabbix-agent

cat > /etc/zabbix/zabbix_agentd.conf.d/mysql.conf << EOF
UserParameter=mysql.status[*],echo "show global status where Variable_name='\$1';" | mysql -N -u root | awk '{print \$\$2}'
UserParameter=mysql.ping,mysqladmin -u root ping | grep -c alive
UserParameter=mysql.version,mysql -V
EOF

cat > /etc/zabbix/zabbix_agentd.conf.d/systemd.conf << EOF
UnsafeUserParameters=1
UserParameter=system.systemd.service.cpushares[*],find /sys/fs/cgroup/cpu*         -name "\$1.service" -exec cat \\{\\}/cpuacct.usage \\;
UserParameter=system.systemd.service.memory[*],find /sys/fs/cgroup/memory          -name "\$1.service" -exec cat \\{\\}/memory.usage_in_bytes \\;
UserParameter=system.systemd.service.blkio[*],expr 0 + \`find /sys/fs/cgroup/blkio -name "\$1.service" -exec sed -n "s|.*\$2\ | + |p" \\{\\}/blkio.throttle.io_service_bytes \\;\`
UserParameter=system.systemd.service.processes[*],find /sys/fs/cgroup/systemd      -name "\$1.service" -exec cat \\{\\}/tasks \\; | wc -l
EOF

cat > /etc/zabbix/zabbix_agentd.conf.d/iostat.conf << EOF
UserParameter=custom.vfs.dev.discovery,/etc/zabbix/scripts/queryDisks.sh
# reads completed successfully
UserParameter=custom.vfs.dev.read.ops[*],cat /proc/diskstats | egrep \$1 | head -1 | awk '{print \$\$4}'
# sectors read
UserParameter=custom.vfs.dev.read.sectors[*],cat /proc/diskstats | egrep \$1 | head -1 | awk '{print \$\$6}'
# time spent reading (ms)
UserParameter=custom.vfs.dev.read.ms[*],cat /proc/diskstats | egrep \$1 | head -1 | awk '{print \$\$7}'
# writes completed
UserParameter=custom.vfs.dev.write.ops[*],cat /proc/diskstats | egrep \$1 | head -1 | awk '{print \$\$8}'
# sectors written
UserParameter=custom.vfs.dev.write.sectors[*],cat /proc/diskstats | egrep \$1 | head -1 | awk '{print \$\$10}'
# time spent writing (ms)
UserParameter=custom.vfs.dev.write.ms[*],cat /proc/diskstats | egrep \$1 | head -1 | awk '{print \$\$11}'
# I/Os currently in progress
UserParameter=custom.vfs.dev.io.active[*],cat /proc/diskstats | egrep \$1 | head -1 | awk '{print \$\$12}'
# time spent doing I/Os (ms)
UserParameter=custom.vfs.dev.io.ms[*],cat /proc/diskstats | egrep \$1 | head -1 | awk '{print \$\$13}'
EOF
mkdir -p /etc/zabbix/scripts/
cat > /etc/zabbix/scripts/queryDisks.sh << EOF
#!/bin/sh
echo '{
        "data":[
                { "{#DISK}":"mmcblk0" },
                { "{#DISK}":"ubiblock0_0" }
        ]
}'
EOF
chmod a+rx /etc/zabbix/scripts/queryDisks.sh
fi
# End of setup of zabbix
#########################################################################

# Set lang, timezone, etc.
install -m 0755 /usr/share/fty/examples/config/profile.d/lang.sh /etc/profile.d/lang.sh
for V in LANG LANGUAGE LC_ALL ; do echo "$V="'"C"'; done > /etc/default/locale

# logout from /bin/bash after 600s/10m of inactivity
case "$IMGTYPE" in
    *devel*) echo "Not tweaking TMOUT in devel image" ;;
    *) echo 'export TMOUT=600' > /etc/profile.d/tmout.sh ;;
esac

# Set up history tracking and syslogging for BASH
install -m 0755 /usr/share/fty/examples/config/profile.d/bash_history.sh /etc/profile.d/bash_history.sh
install -m 0755 /usr/share/fty/examples/config/profile.d/bash_syslog.sh /etc/profile.d/bash_syslog.sh

# MVY:
# original debian8 snoopy (v1.8.0) is NOT compatible with systemd!!!
#   https://bugs.freedesktop.org/show_bug.cgi?id=90364
#   BIOS-2423
# so the integration to the system must exclude systemd itself
# we customly deliver a newer version (should be 2.2.6+) in our repos

if [ -s "/lib/snoopy.so" ] && [ -z "`grep /lib/snoopy.so /etc/ld.so.preload`" ]; then
    echo "Installing LIBSNOOPY into common LD_PRELOAD"
    echo "/lib/snoopy.so" >> /etc/ld.so.preload

    if [ -d "/etc/logcheck" ]; then
        mkdir -p /etc/logcheck/ignore.d.server && \
        echo '^\w{3} [ :0-9]{11} [._[:alnum:]-]+ snoopy.*' > /etc/logcheck/ignore.d.server/snoopy

        mkdir -p /etc/logcheck/violations.ignore.d && \
        echo '^\w{3} [ :0-9]{11} [._[:alnum:]-]+ snoopy.*' > /etc/logcheck/violations.ignore.d/snoopy
    fi
fi

# Legality requires this notice
{ echo ""; echo "WARNING: All shell activity on this system is logged!"; echo ""; } >> /etc/motd

# A few helper aliases
install -m 0755 /usr/share/fty/examples/config/profile.d/fty_aliases.sh /etc/profile.d/fty_aliases.sh

# 42ity PATH
install -m 0755 /usr/share/fty/examples/config/profile.d/fty_path.sh /etc/profile.d/fty_path.sh

# Help ifup and ifplugd do the right job
install -m 0755 /usr/share/fty/scripts/ethtool-static-nolink /etc/network/if-pre-up.d
install -m 0755 /usr/share/fty/scripts/ifupdown-force /etc/ifplugd/action.d/ifupdown-force
install -m 0755 /usr/share/fty/scripts/udhcpc-override.sh /usr/local/sbin/udhcpc
echo '[ -s /usr/share/fty/scripts/udhcpc-hook.sh ] && . /usr/share/fty/scripts/udhcpc-hook.sh' >> /etc/udhcpc/default.script

#########################################################################
# install iptables filtering

## startup script
cat >/etc/network/if-pre-up.d/iptables-up <<[eof]
#!/bin/sh
test -r /etc/default/iptables && iptables-restore < /etc/default/iptables || true
test -r /etc/default/ip6tables && ip6tables-restore < /etc/default/ip6tables || true
[eof]
chmod 755 /etc/network/if-pre-up.d/iptables-up

## ipv4 default table
cat > /etc/default/iptables <<[eof]
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -d 127.0.0.0/8 ! -i lo -j REJECT --reject-with icmp-port-unreachable
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 4222 -j ACCEPT
-A INPUT -p udp -m udp --sport 4679 -j ACCEPT
-A INPUT -p udp -m udp --dport 5353 -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-port-unreachable
-A FORWARD -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -j ACCEPT
COMMIT
[eof]

## ipv6 default table
cat > /etc/default/ip6tables <<[eof]
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -d ::1/128 ! -i lo -j REJECT --reject-with icmp6-port-unreachable
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 4222 -j ACCEPT
-A INPUT -p udp -m udp --sport 4679 -j ACCEPT
-A INPUT -p udp -m udp --dport 5353 -j ACCEPT
-A INPUT -p icmpv6 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp6-port-unreachable
-A FORWARD -j REJECT --reject-with icmp6-port-unreachable
-A OUTPUT -j ACCEPT
COMMIT
[eof]

# install iptables filtering end
#########################################################################

# More space saving
SPACERM="rm -rf"
$SPACERM /usr/share/nmap/nmap-os-db /usr/bin/{aria_read_log,aria_dump_log,aria_ftdump,replace,resolveip,myisamlog,myisam_ftdump}
case "$SPACERM" in
    rm|rm\ *) # Replace cleaned-up stuff
        install -m 0755 /usr/share/fty/scripts/resolveip.sh /usr/bin/resolveip
        ;;
esac
for i in /usr/share/mysql/* /usr/share/locale /usr/share/fty/{develop,obs}; do
   [ -f "$i" ] || \
   [ "$i" = /usr/share/mysql/charsets ] || \
   [ "$i" = /usr/share/mysql/english ] || \
   $SPACERM "$i" || true
done

# Show the package list
dpkg --get-selections
dpkg-query -Wf '${Installed-Size}\t${Package}\n' | sort -n

# Create the CSV Legal packages manifest, to display from the Web UI
# copyright files path are adapted to Web UI display!
CSV_FILE_PATH="/usr/share/doc/ipc-packages.csv"
rm -f ${CSV_FILE_PATH}
touch ${CSV_FILE_PATH}
dpkg-query -W -f='${db:Status-Abbrev};${source:Package};${Version};${binary:Package}\n' | grep '^i' | cut -d';' -f2,3,4 | sort -u > ./pkg-list.log
while IFS=';' read SOURCE_PKG PKG_VERSION CURRENT_PKG
do
   CURRENT_PKG="`echo ${CURRENT_PKG} | cut -d':' -f1`"
   PKG_VERSION="`echo ${PKG_VERSION} | cut -d':' -f2`"
   grep -q "${SOURCE_PKG};" "${CSV_FILE_PATH}" || \
   if [ $? -eq 1 ]; then
      echo "${SOURCE_PKG};${PKG_VERSION};/legal/${CURRENT_PKG}/copyright" 2>/dev/null >> "${CSV_FILE_PATH}"
      [ ! -f "/usr/share/doc/${CURRENT_PKG}/copyright" ] && echo "Missing ${CURRENT_PKG}/copyright file!"
   fi
done < ./pkg-list.log
rm -f ./pkg-list.log

# Promote DMF driver for devel images
if [ -x /lib/nut/snmp-ups ] && [ -x /lib/nut/snmp-ups-dmf ] && \
   [ ! -x /lib/nut/snmp-ups-old ] && [ ! -L /lib/nut/snmp-ups ] \
; then
    mv /lib/nut/snmp-ups /lib/nut/snmp-ups-old && \
    case "$IMGTYPE" in
        *devel*) ln -s snmp-ups-dmf /lib/nut/snmp-ups ;;
        *)       ln -s snmp-ups-old /lib/nut/snmp-ups ;;
    esac
fi

# Prepare the ccache (for development image type)
case "$IMGTYPE" in
    *devel*)
        [ -x /usr/sbin/update-ccache-symlinks ] && \
            /usr/sbin/update-ccache-symlinks || true
        # If this image ends up on an RC3, avoid polluting NAND with ccache
        mkdir -p /home/admin/.ccache
        chown -R admin /home/admin/.ccache
        rm -rf /root/.ccache
        ln -s /home/admin/.ccache /root/.ccache
        echo "export PATH=\"/usr/lib/ccache:/usr/lib64/ccache:\$PATH\"" > /etc/profile.d/ccache.sh
        ;;
esac

# Require that services we need hop back up if they were started and then died
for i in mysql tntnet@bios malamute \
; do
    find /lib/systemd /usr/lib/systemd -name "$i".service | while read file; do
        egrep '^Restart=' "$file" >/dev/null || \
            sed -e 's,^\(ExecStart=.*\)$,\1\nRestart=always,' -i "$file"
    done
done

/bin/systemctl daemon-reload

# Prepare the source-code details excerpt, if available
[ -s "/usr/share/fty/.git_details" ] && \
    grep ESCAPE "/usr/share/fty/.git_details" > /usr/share/bios-web/git_details.txt || \
    echo "WARNING: Do not have /usr/share/fty/.git_details"

# Timestamp the end of OS image generation
# NOTE: This value and markup are consumed by bios-core::sysinfo.ecpp
# REST API and by bios-boot::init script.
echo "OSimage:build-ts: `LANG=C date -R -u`
OSimage:img-type: $IMGTYPE" > /usr/share/bios-web/image-version.txt || \
    echo "WARNING: Could not record OBS image-building timestamp and type"

# Get rid of static qemu binaries needed for crossinstallation
# TODO: Integrate this better into build-recipe-preinstallimage/init_buildsystem
rm -f /usr/bin/qemu*

# Make sure we have no cruft in the image (NFS-based builds on ARM farm may lag)
echo "Syncing OS image filesystem..."
sync; sync; sleep 3; sync
find / -type f -mount -name '\.nfs????????????????????????' -exec rm -f '{}' \; 2>/dev/null
# Sanitize the OS image from some more build-system cruft
rm -f /.guessed_dist /debian-binary
rm -rf /.reorder /.oldroot
#[ "$IMGTYPE" = deploy ] && \
    rm -rf /.preinstallimage /.preinstall_image
sync

# Some shells want these bits
chmod a+rx /etc/profile.d/*

# Some of our packaging cleanup could leave the OS image unable to manage
# user passwords... block such OS images from appearing at all!
if [ ! -f /var/cache/cracklib/cracklib_dict.pwd ]; then
    echo "cracklib dict is missing"
    exit 1
fi

# /usr/share/misc/file is a symlink on Debian 8 (jessie)
# and magic_load (_magic, NULL) fails. Pass the correct location
# as MAGIC variable to tntnet and bios-agent-smtp
if [[ -d /usr/share/file/magic ]]; then
    echo "MAGIC=/usr/share/file/magic" >> /usr/share/fty/etc/default/fty
fi

echo "WIPE OS image log file contents"
find /var/log -type f | while read F; do cat /dev/null > "$F"; done

echo "Fix up OS image log file and directory access rights"
find /var/log -group adm -exec chgrp 'bios-logread' '{}' \; || true
touch /var/log/messages /var/log/commands.log
chmod 640 /var/log/messages || true
chgrp bios-logread /var/log/messages || true
chmod 640 /var/log/commands.log || true
chgrp bios-logread /var/log/commands.log || true

# By default, when MySQL first starts it creates the log dir...
# but one only accessible to itself:
### $ ls -lad /var/log/mysql/ /var/log/mysql/error.log
### drwxrwx--- 2 mysql mysql 4096 Oct 26 12:22 /var/log/mysql/
### -rw-rw---- 1 mysql mysql 6066 Oct 31 09:10 /var/log/mysql/error.log
# We want those logs to be visible to admin as well, at least by direct request
# If we fail to set this up, leave things as they were (no initial directory)
mkdir -p /var/log/mysql && \
chown mysql:mysql /var/log/mysql && \
chmod 771 /var/log/mysql && \
touch /var/log/mysql/error.log && \
chown mysql:bios-logread /var/log/mysql/error.log && \
chmod 640 /var/log/mysql/error.log || \
rm -rf /var/log/mysql

find /var/log -group bios-logread -exec chmod go-w '{}' \; || true
find /var/log -group bios-logread -exec chmod g+r '{}' \; || true

# Note: unlike earlier revisions, this script no longer precreates
# legacy paths intended for compatibility with BIOS (MVP release).
# The logic to migrate such paths in existing upgraded deployments
# is now handled in setup/ipc-meta-setup.sh framework script and
# corresponding systemd service unit before BIOS services start up.

sync
echo "INFO: successfully reached the end of script: $0 $@"
