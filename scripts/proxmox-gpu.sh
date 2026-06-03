#!/bin/bash

# get PCI device id for GPUs
lspci -nn | grep -i nvidia
# expecting:
# 0000:02:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA107 [GeForce RTX 3050 6GB] [10de:2584] (rev a1)
# 0000:02:00.1 Audio device [0403]: NVIDIA Corporation GA107 High Definition Audio Controller [10de:2291] (rev a1)
# 0000:18:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA107 [GeForce RTX 3050 6GB] [10de:2584] (rev a1)
# 0000:18:00.1 Audio device [0403]: NVIDIA Corporation GA107 High Definition Audio Controller [10de:2291] (rev a1)

# prepare kernel
echo "options vfio-pci ids=10de:2584,10de:2291" > /etc/modprobe.d/vfio.conf
echo -e "vfio\nvfio_pci\nvfio_iommu_type1\nvfio_virqfd" >> /etc/modules
echo blacklist nouveau >> /etc/modprobe.d/blacklist.conf
update-initramfs -u -k all
reboot

# verify everything good from kernel side
lspci -nnk -s 02:00.0 # should be "use: vfio-pci"

# add resource mapping to proxmox
pvesh create /cluster/mapping/pci --id gpu0 --map node=proxmox2,path=0000:02:00
pvesh create /cluster/mapping/pci --id gpu1 --map node=proxmox2,path=0000:18:00
