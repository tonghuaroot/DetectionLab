#! /usr/bin/env bash

# This script is run on the Packet.net baremetal server for CI tests.
# While building, the server will start a webserver on Port 80 that contains
# the text "building". Once the test is completed, the text will be replaced
# with "success" or "failed".

export DEBIAN_FRONTEND=noninteractive
# Bypass prompt for libsslv1.1 https://unix.stackexchange.com/a/543706
echo 'libssl1.1:amd64 libraries/restart-without-asking boolean true' | sudo debconf-set-selections

# Download Packet.net storage utilities
echo "[$(date +%H:%M:%S)]: Downloading Packet external storage utilities..."
wget -q -O /usr/local/bin/packet-block-storage-attach "https://raw.githubusercontent.com/packethost/packet-block-storage/master/packet-block-storage-attach"
chmod +x /usr/local/bin/packet-block-storage-attach
wget -q -O /usr/local/bin/packet-block-storage-detach "https://raw.githubusercontent.com/packethost/packet-block-storage/master/packet-block-storage-detach"
chmod +x /usr/local/bin/packet-block-storage-detach

# Set a flag to determine if the boxes are available on external Packet storage
BOXES_PRESENT=0
# Attempt to mount the block storage
echo "[$(date +%H:%M:%S)]: Attempting to mount external storage..."
/usr/local/bin/packet-block-storage-attach
sleep 10
# Check if it was successful by looking for volume* in /dev/mapper
if ls -al /dev/mapper/volume* > /dev/null 2>&1; then
  echo "[$(date +%H:%M:%S)]: Mounting of external storage was successful."
  sleep 5
  if mount /dev/mapper/volume-fed37d73-part1 /mnt; then
    echo "[$(date +%H:%M:%S)]: External storage successfully mounted to /mnt"
  else
    echo "[$(date +%H:%M:%S)]: Something went wrong mounting the filesystem from the external storage."
  fi
  if ls -al /mnt/*.box > /dev/null 2>&1; then
    BOXES_PRESENT=1
  fi
else
  echo "[$(date +%H:%M:%S)]: No volumes found after attempting to mount storage. Trying again..."
  /usr/local/bin/packet-block-storage-attach
  sleep 15
  if ! ls -al /dev/mapper/volume* > /dev/null 2>&1; then
    echo "[$(date +%H:%M:%S)]: Failed to mount volumes even after a retry. Giving up..."
  else
    echo "[$(date +%H:%M:%S)]: Successfully mounted the external storage after a retry."
    sleep 10
    if mount /dev/mapper/volume-fed37d73-part1 /mnt; then
      echo "[$(date +%H:%M:%S)]: External storage successfully mounted to /mnt"
    else
      echo "[$(date +%H:%M:%S)]: Something went wrong mounting the filesystem from the external storage."
    fi
    if ls -al /mnt/*.box > /dev/null 2>&1; then
      BOXES_PRESENT=1
    fi
  fi
fi

# Disable IPv6 - may help with the vagrant-reload plugin: https://github.com/hashicorp/vagrant/issues/8795#issuecomment-468945063
echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
sysctl -p /etc/sysctl.conf > /dev/null

# Install Virtualbox 6.1
echo "deb [arch=amd64] https://download.virtualbox.org/virtualbox/debian $(lsb_release -sc) contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list
wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | sudo apt-key add -
wget -q https://www.virtualbox.org/download/oracle_vbox.asc -O- | sudo apt-key add -
echo "[$(date +%H:%M:%S)]: Running apt-get update..."
apt-get -qq update
echo "[$(date +%H:%M:%S)]: Running apt-get install..."
apt-get -qq install -y linux-headers-"$(uname -r)" virtualbox-6.1 build-essential unzip git ufw apache2

echo "building" > /var/www/html/index.html

# Set up firewall
ufw allow ssh
ufw allow http
ufw default allow outgoing
ufw --force enable

# Install Vagrant
echo "[$(date +%H:%M:%S)]: Installing Vagrant..."
mkdir /opt/vagrant
cd /opt/vagrant || exit 1
wget --progress=bar:force https://releases.hashicorp.com/vagrant/2.2.17/vagrant_2.2.17_x86_64.deb
dpkg -i vagrant_2.2.17_x86_64.deb
echo "[$(date +%H:%M:%S)]: Installing vagrant-reload plugin..."
vagrant plugin install vagrant-reload

# Make sure the plugin installed correctly. Retry if not.
if [ "$(vagrant plugin list | grep -c vagrant-reload)" -ne "1" ]; then
  echo "[$(date +%H:%M:%S)]: The first attempt to install the vagrant-reload plugin failed. Trying again."
  vagrant plugin install vagrant-reload
fi

# Re-enable IPv6 - may help with the Vagrant Cloud slowness
echo "net.ipv6.conf.all.disable_ipv6=0" >> /etc/sysctl.conf
sysctl -p /etc/sysctl.conf > /dev/null

## Git Clone DL (Only needed when manually building)
#git clone https://github.com/clong/DetectionLab.git /opt/DetectionLab


# Make the Vagrant instances headless
cd /opt/DetectionLab/Vagrant || exit 1
sed -i 's/vb.gui = true/vb.gui = false/g' Vagrantfile
cd /opt/DetectionLab/Vagrant/Exchange || exit 1
sed -i 's/vb.gui = true/vb.gui = false/g' Vagrantfile
cd /opt/DetectionLab/Vagrant || exit 1

# If the boxes are present on external storage, we can modify the Vagrantfile to
# point to the boxes on disk so we don't have to download them
if [ $BOXES_PRESENT -eq 1 ]; then
  echo "[$(date +%H:%M:%S)]: Updating the Vagrantfile to point to the boxes mounted on external storage..."
  sed -i 's#"detectionlab/win2016"#"/mnt/windows_2016_virtualbox.box"#g' /opt/DetectionLab/Vagrant/Vagrantfile
  sed -i 's#"detectionlab/win10"#"/mnt/windows_10_virtualbox.box"#g' /opt/DetectionLab/Vagrant/Vagrantfile
fi

# Recreate a barebones version of the build script so we have some sense of return codes
cat << 'EOF' > /opt/DetectionLab/build.sh
#! /usr/bin/env bash


build_vagrant_hosts() {

# Kick off builds for logger and dc
cd "$DL_DIR"/Vagrant || exit 1
for HOST in logger dc; do
  (vagrant up $HOST &> "$DL_DIR/Vagrant/vagrant_up_$HOST.log" || vagrant reload $HOST --provision &> "$DL_DIR/Vagrant/vagrant_up_$HOST.log") &
  declare ${HOST}_PID=$!
done

# We only have to wait for DC to create the domain before kicking off wef and win10 builds
DC_CREATION_TIMEOUT=30
MINUTES_PASSED=0
while ! grep 'I am domain joined!' "$DL_DIR/Vagrant/vagrant_up_dc.log" > /dev/null; do
    (echo >&2 "[$(date +%H:%M:%S)]: Waiting for DC to complete creation of the domain...")
    sleep 60
    ((MINUTES_PAST += 1))
    if [ $MINUTES_PAST -gt $DC_CREATION_TIMEOUT ]; then
      (echo >&2 "Timed out waiting for DC to create the domain controller. Exiting.")
      exit 1
    fi 
done;

# Kick off builds for wef and win10
cd "$DL_DIR"/Vagrant || exit 1
for HOST in wef win10; do
  (vagrant up $HOST &> "$DL_DIR/Vagrant/vagrant_up_$HOST.log" || vagrant reload $HOST --provision &> "$DL_DIR/Vagrant/vagrant_up_$HOST.log") &
  declare ${HOST}_PID=$!
done

# Wait for all the builds to finish
while ps -p $logger_PID > /dev/null || ps -p $dc_PID > /dev/null || ps -p $wef_PID > /dev/null || ps -p $win10_PID > /dev/null; do
  (echo >&2 "[$(date +%H:%M:%S)]: Waiting for all of the builds to complete...")
  sleep 60
done

for HOST in logger dc wef win10; do
  if wait $HOST_PID; then # After this command, the return code gets set to what the return code of the PID was
    (echo >&2 "$HOST was built successfully!")
  else 
    (echo >&2 "Failed to bring up $HOST after a reload. Exiting")
    exit 1
  fi
done
}

main() {
  # Get location of build.sh
  # https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
  DL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Build and Test Vagrant hosts 
  cd Vagrant
  build_vagrant_hosts
  /bin/bash $DL_DIR/Vagrant/post_build_checks.sh
}

main
exit 0
EOF
chmod +x /opt/DetectionLab/build.sh

# Start the build in a tmux session
sn=tmuxsession
tmux new-session -s "$sn" -d
tmux send-keys -t "$sn:0" 'cd /opt/DetectionLab && ./build.sh && echo "success" > /var/www/html/index.html || echo "failed" > /var/www/html/index.html; umount /mnt && /usr/local/bin/packet-block-storage-detach' Enter
