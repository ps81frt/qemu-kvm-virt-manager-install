# qemu-kvm-virt-manager-install


------

```bash
sudo apt update && sudo apt upgrade -y

if apt-cache policy qemu-kvm 2>/dev/null | grep -q "Candidate: (none)"; then
  QEMU_PKG="qemu-system-x86"
else
  QEMU_PKG="qemu-kvm"
fi

sudo apt install -y $QEMU_PKG qemu-utils libvirt-daemon-system libvirt-clients virt-manager virtinst bridge-utils ovmf cpu-checker

kvm-ok
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm $USER
ls -l /dev/kvm
sudo virsh net-list --all
sudo virsh net-start default 2>/dev/null
sudo virsh net-autostart default
```
