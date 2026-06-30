# Linux USB Access

Linux users normally need udev rules so `minipro-zig` can open XGecu programmers without running as root.

The build installs a sample rule file to `lib/udev/rules.d/60-minipro-zig.rules` under the selected install prefix. System packages should install that file into `/usr/lib/udev/rules.d/` or `/etc/udev/rules.d/`.

For a local manual install:

```sh
sudo install -m 0644 packaging/60-minipro-zig.rules /etc/udev/rules.d/60-minipro-zig.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Unplug and reconnect the programmer after reloading rules. On systems without `TAG+="uaccess"` support, adapt the rules to your distribution's preferred device group, such as `plugdev`, and add your user to that group.

The rules cover the USB IDs used by supported programmer families:

- `04d8:e11c` for TL866A/TL866CS-class devices.
- `a466:0a53` for TL866II Plus, T48, and T56-class devices.
- `a466:1a86` for T76-class devices.

Do not use `sudo` for normal chip operations. Fix device permissions instead, then keep using the CLI's `--execute` and destructive confirmation gates deliberately.
