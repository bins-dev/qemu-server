/usr/bin/kvm \
  -id 8006 \
  -name 'simple,debug-threads=on' \
  -no-shutdown \
  -chardev 'socket,id=qmp,path=/var/run/qemu-server/8006.qmp,server=on,wait=off' \
  -mon 'chardev=qmp,mode=control' \
  -chardev 'socket,id=qmp-event,path=/var/run/qmeventd.sock,reconnect-ms=5000' \
  -mon 'chardev=qmp-event,mode=control' \
  -pidfile /var/run/qemu-server/8006.pid \
  -daemonize \
  -smp '1,sockets=1,cores=1,maxcpus=1' \
  -nodefaults \
  -boot 'menu=on,strict=on,reboot-timeout=1000,splash=/usr/share/qemu-server/bootsplash.jpg' \
  -vnc 'unix:/var/run/qemu-server/8006.vnc,password=on' \
  -cpu kvm64,enforce,+kvm_pv_eoi,+kvm_pv_unhalt,+lahf_lm,+sep \
  -m 512 \
  -object '{"id":"throttle-drive-scsi0","limits":{},"qom-type":"throttle-group"}' \
  -object '{"id":"throttle-drive-scsi1","limits":{},"qom-type":"throttle-group"}' \
  -object '{"id":"throttle-drive-scsi2","limits":{},"qom-type":"throttle-group"}' \
  -object '{"id":"throttle-drive-scsi3","limits":{},"qom-type":"throttle-group"}' \
  -global 'PIIX4_PM.disable_s3=1' \
  -global 'PIIX4_PM.disable_s4=1' \
  -device 'pci-bridge,id=pci.1,chassis_nr=1,bus=pci.0,addr=0x1e' \
  -device 'pci-bridge,id=pci.2,chassis_nr=2,bus=pci.0,addr=0x1f' \
  -device 'piix3-usb-uhci,id=uhci,bus=pci.0,addr=0x1.0x2' \
  -device 'usb-tablet,id=tablet,bus=uhci.0,port=1' \
  -device 'VGA,id=vga,bus=pci.0,addr=0x2' \
  -device 'virtio-balloon-pci,id=balloon0,bus=pci.0,addr=0x3,free-page-reporting=on' \
  -iscsi 'initiator-name=iqn.1993-08.org.debian:01:aabbccddeeff' \
  -device 'virtio-scsi-pci,id=scsihw0,bus=pci.0,addr=0x5' \
  -blockdev '{"detect-zeroes":"unmap","discard":"unmap","driver":"throttle","file":{"cache":{"direct":true,"no-flush":false},"detect-zeroes":"unmap","discard":"unmap","driver":"raw","file":{"aio":"io_uring","cache":{"direct":true,"no-flush":false},"detect-zeroes":"unmap","discard":"unmap","driver":"host_device","filename":"/dev/pve/vm-8006-disk-0","node-name":"e6d87b01b7bb888b8426534a542ff1c","read-only":false},"node-name":"f6d87b01b7bb888b8426534a542ff1c","read-only":false},"node-name":"drive-scsi0","read-only":false,"throttle-group":"throttle-drive-scsi0"}' \
  -device 'scsi-hd,bus=scsihw0.0,channel=0,scsi-id=0,lun=0,drive=drive-scsi0,id=scsi0,device_id=drive-scsi0,bootindex=100,write-cache=on' \
  -blockdev '{"detect-zeroes":"unmap","discard":"unmap","driver":"throttle","file":{"cache":{"direct":false,"no-flush":false},"detect-zeroes":"unmap","discard":"unmap","driver":"raw","file":{"aio":"io_uring","cache":{"direct":false,"no-flush":false},"detect-zeroes":"unmap","discard":"unmap","driver":"host_device","filename":"/dev/pve/vm-8006-disk-0","node-name":"e96d9ece81aa4271aa2d8485184f66b","read-only":false},"node-name":"f96d9ece81aa4271aa2d8485184f66b","read-only":false},"node-name":"drive-scsi1","read-only":false,"throttle-group":"throttle-drive-scsi1"}' \
  -device 'scsi-hd,bus=scsihw0.0,channel=0,scsi-id=0,lun=1,drive=drive-scsi1,id=scsi1,device_id=drive-scsi1,write-cache=on' \
  -blockdev '{"detect-zeroes":"unmap","discard":"unmap","driver":"throttle","file":{"cache":{"direct":false,"no-flush":false},"detect-zeroes":"unmap","discard":"unmap","driver":"raw","file":{"aio":"io_uring","cache":{"direct":false,"no-flush":false},"detect-zeroes":"unmap","discard":"unmap","driver":"host_device","filename":"/dev/pve/vm-8006-disk-0","node-name":"e0b89788ef97beda10a850ab45897d9","read-only":false},"node-name":"f0b89788ef97beda10a850ab45897d9","read-only":false},"node-name":"drive-scsi2","read-only":false,"throttle-group":"throttle-drive-scsi2"}' \
  -device 'scsi-hd,bus=scsihw0.0,channel=0,scsi-id=0,lun=2,drive=drive-scsi2,id=scsi2,device_id=drive-scsi2,write-cache=off' \
  -blockdev '{"detect-zeroes":"unmap","discard":"unmap","driver":"throttle","file":{"cache":{"direct":true,"no-flush":false},"detect-zeroes":"unmap","discard":"unmap","driver":"raw","file":{"aio":"io_uring","cache":{"direct":true,"no-flush":false},"detect-zeroes":"unmap","discard":"unmap","driver":"host_device","filename":"/dev/pve/vm-8006-disk-0","node-name":"ea7b6871af66ca3e13e95bd74570aa2","read-only":false},"node-name":"fa7b6871af66ca3e13e95bd74570aa2","read-only":false},"node-name":"drive-scsi3","read-only":false,"throttle-group":"throttle-drive-scsi3"}' \
  -device 'scsi-hd,bus=scsihw0.0,channel=0,scsi-id=0,lun=3,drive=drive-scsi3,id=scsi3,device_id=drive-scsi3,write-cache=off' \
  -machine 'type=pc+pve0'
