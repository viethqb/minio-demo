#!/bin/bash

# Enable ssh password authentication
echo "[TASK 1] Enable ssh password authentication"
sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
systemctl reload sshd

# Set Root password
echo "[TASK 2] Set root password"
echo -e "admin\nadmin" | passwd root >/dev/null 2>&1

# Prepare and mount 4 data disks at /data1, /data2, /data3, /data4 (XFS)
echo "[TASK 3] Prepare data disks /data1, /data2, /data3, /data4"
DISKS=(/dev/sdb /dev/sdc /dev/sdd /dev/sde)
MOUNTS=(/data1 /data2 /data3 /data4)

# Wait for block devices to appear (disks attached by Vagrant)
for d in "${DISKS[@]}"; do
  for i in $(seq 1 30); do
    [ -b "$d" ] && break
    sleep 1
  done
  [ -b "$d" ] || { echo "Timeout waiting for $d"; exit 1; }
done

for i in "${!DISKS[@]}"; do
  disk="${DISKS[$i]}"
  mnt="${MOUNTS[$i]}"
  mkdir -p "$mnt"
  if ! blkid -o value -s TYPE "$disk" 2>/dev/null | grep -qx xfs; then
    echo "Formatting $disk as xfs..."
    mkfs.xfs -f "$disk"
  fi
  if ! grep -q "$mnt" /etc/fstab; then
    echo "$disk $mnt xfs defaults,noatime,nofail 0 0" >> /etc/fstab
  fi
done
mount -a
echo "Data disks mounted at /data1, /data2, /data3, /data4"

# Install Docker
echo "[TASK 4] Install Docker"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME:-$VERSION}") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
echo "Docker installed: $(docker --version)"

# Deploy docker-compose.yaml for this node (service/hostname/container = hostname)
echo "[TASK 5] Deploy docker-compose.yaml"
NODE=$(hostname)
mkdir -p /root/minio
cat > /root/minio/docker-compose.yaml << COMPOSE_EOF
services:
  ${NODE}:
    hostname: ${NODE}
    container_name: ${NODE}
    image: quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z
    command: server --console-address ":9001" http://minio{1...4}/data{1...4} 
    # command: server --console-address ":9001" http://minio{1...4}/data{1...4} http://minio{5...8}/data{1...4}
    ports:
      - "9000:9000"
      - "9001:9001"
    extra_hosts:
      - "minio1:172.16.16.101"
      - "minio2:172.16.16.102"
      - "minio3:172.16.16.103"
      - "minio4:172.16.16.104"
      - "minio5:172.16.16.105"
      - "minio6:172.16.16.106"
      - "minio7:172.16.16.107"
      - "minio8:172.16.16.108"
    environment:
      MINIO_ROOT_USER: admin
      MINIO_ROOT_PASSWORD: password
    volumes:
      - /data1:/data1
      - /data2:/data2
      - /data3:/data3
      - /data4:/data4
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3
COMPOSE_EOF
echo "Created /root/minio/docker-compose.yaml for node ${NODE}"