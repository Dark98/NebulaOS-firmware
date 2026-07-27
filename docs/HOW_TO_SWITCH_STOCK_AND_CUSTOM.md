# How to switch between stock and custom firmware

Your printer's little computer (the Nebula Pad) can hold **two complete operating systems at the
same time**, on two separate storage slots:

- **Stock** — the original Creality software that came with the printer.
- **Custom** — this project's own firmware (real Klipper, Moonraker, Mainsail, GuppyScreen).

Only one runs at a time. A tiny file tells the printer which one to boot next time it powers on.
Nothing you do here ever deletes or overwrites the other one — they're on completely separate
storage, so you can always go back.

There are two ways to do the switch: an **easy way** you'll use almost every time, and a **hard
way** that only matters if the easy way is unavailable (e.g. the printer won't connect to Wi-Fi).

---

## Method 1: The easy way (SSH) — use this one

You need: a computer, and the printer connected to your Wi-Fi network (either OS can be running
right now — it works the same either way).

**What it does, in plain terms:** you connect to the printer over the network, run one command
that flips a switch, then reboot the printer. Two minutes, no tools, no opening the case.

### Step by step

1. **Find the printer's IP address.** It's shown on the printer's own screen under Wi-Fi settings,
   or check your router's device list. (In this project's own testing sessions, stock and custom
   showed up as *different* IP addresses on the same network — that's normal. If SSH suddenly
   won't connect after a switch, that's usually just this: try the *other* address, or check your
   router's device list again.)

2. **Connect over SSH** (Terminal on Mac/Linux, or PowerShell/PuTTY on Windows):
   ```
   ssh root@<the-ip-address>
   ```
   Password: `openke`

3. **Tell it which one to boot next.** Run exactly one of these two commands:

   To boot **stock** next:
   ```
   sh -c '. /etc/ota_marker.sh; write_ota_marker "ota:kernel"'
   ```

   To boot **custom** next:
   ```
   sh -c '. /etc/ota_marker.sh; write_ota_marker "ota:kernel2"'
   ```

   (`/etc/ota_marker.sh` only exists on the **custom** side. If you're currently on **stock** and
   want to switch to custom, that file won't be there — ask for help getting a copy over first, or
   use Method 2 below.)

4. **Reboot:**
   ```
   reboot
   ```

5. **Wait about a minute.** The printer will restart and boot into whichever one you picked. Watch
   its screen or try reconnecting to confirm.

That's the whole thing. If you ever want to switch back, repeat the same steps with the other
command.

### A safety net you get for free

Custom firmware has a built-in "oops" protection: the very first thing it does on every boot is
quietly set the switch back to **stock**. Only after everything (Klipper, Moonraker, the screen)
is confirmed actually working does it flip the switch back to "boot custom again next time." So if
a custom boot ever crashes or hangs, the *next* reboot automatically lands you back on stock —
even if you can't get to a keyboard. You never get stuck.

---

## Method 2: The hard way (USB recovery mode) — only if Method 1 doesn't work

Use this only if the printer won't connect to Wi-Fi/SSH at all (for example, if a custom firmware
attempt fails to boot far enough to even bring up the network). This is a real, tested fallback,
but it's more involved: it needs a computer, a USB cable, and physically touching two small
buttons on the board.

**Heads up:** this method is really a "**panic button back to stock**," not a general switch —
the tool used here is built to force the printer back to stock specifically, not to send it to
custom. If you're in a spot where you need this, you're recovering, not casually switching.

### What you need
- A USB cable connected from your computer to the Nebula Pad's MicroUSB port.
- The `ballaswag/ingenic-usbboot` tool, built from source on your computer:
  ```
  git clone https://github.com/ballaswag/ingenic-usbboot
  cd ingenic-usbboot
  make
  ```

### Step by step
1. Power off the printer.
2. Find the two small buttons on the Nebula Pad's circuit board, right next to the MicroUSB port
   (you may need to open the case).
3. **Hold both buttons down together for 3 seconds.** Then **release the reset button first**,
   and let go of the boot button right after. This puts the board into a special USB recovery mode
   instead of a normal boot — nothing runs yet, it's just waiting for instructions from your
   computer.
4. On your computer, confirm it's detected (optional, but reassuring):
   ```
   lsusb
   ```
   You're looking for a device that shows up as Ingenic's USB boot device.
5. Force it back to stock:
   ```
   ./ingenic-usbboot --force-swap-ota
   ```
6. Power the printer off and on again normally (or press reset) to leave recovery mode and do a
   real boot. It will come up on stock.

---

## Method 3: The "start completely over" option — last resort only

Creality also publishes official, ready-made recovery images and a USB flashing tool that
reinstalls *everything* (bootloader, kernel, rootfs — the whole board) back to a totally fresh,
factory-original state. This is not really "switching" — it's a full factory reset, and it uses
the same USB recovery mode described in Method 2. Only reach for this if both other methods have
failed and you want to guarantee a clean stock printer to start from again. It's not something to
do casually, and it's outside the scope of this guide — if you ever need it, treat it as its own
careful, deliberate step, not a quick fix.

---

## Quick summary

| Situation | Use |
|---|---|
| Normal, everything's working, just want to switch | **Method 1** (SSH) |
| Printer won't connect to Wi-Fi/network at all | **Method 2** (USB recovery, back to stock) |
| Something's badly broken and you want a clean slate | **Method 3** (full factory restore — ask for help first) |

You can always tell which one is currently running by checking `/proc/cmdline` over SSH: stock
shows `root=/dev/mmcblk0p7`, custom shows `root=/dev/mmcblk0p8`.
