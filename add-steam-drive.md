## Steam Flatpak: restore a game library on an ext4 drive

Use this guide when Steam cannot see games stored on an ext4 drive mounted through `fstab`.

Replace these placeholders throughout:

- `<MOUNTPOINT>` — where the drive is mounted, such as `/home/<user>/games-drive`
- `<LIBRARY>` — the Steam library directory, such as `/home/<user>/games-drive/SteamLibrary`
- `<FLATPAK_APP_ID>` — Steam’s Flatpak ID, normally `com.valvesoftware.Steam`

### 1. Confirm that the drive is mounted

```bash
findmnt <MOUNTPOINT>
df -hT <MOUNTPOINT>
```

The output should show the drive’s partition, `ext4`, and the expected mountpoint.

If it is not mounted:

```bash
sudo mount -a
```

Then check again.

### 2. Confirm the Steam library structure

```bash
ls -la <LIBRARY>/steamapps
```

An existing library should contain files like:

```text
appmanifest_*.acf
common/
```

Installed game files should be located under:

```text
<LIBRARY>/steamapps/common
```

A message about `lost+found` being inaccessible is normal on ext4 and can be ignored.

### 3. Give Flatpak Steam access to the drive

```bash
flatpak override --user \
  --filesystem=<MOUNTPOINT> \
  <FLATPAK_APP_ID>
```

For the standard Steam Flatpak, that would be:

```bash
flatpak override --user \
  --filesystem=/home/<user>/games-drive \
  com.valvesoftware.Steam
```

Verify the permission:

```bash
flatpak info --show-permissions <FLATPAK_APP_ID>
```

Look for a filesystem permission containing the mountpoint.

### 4. Restart Steam completely

```bash
flatpak kill <FLATPAK_APP_ID>
flatpak run <FLATPAK_APP_ID>
```

### 5. Add the library in Steam

Open **Steam → Settings → Storage** and add the exact library directory:

```text
<LIBRARY>
```

For example:

```text
/home/<user>/games-drive/SteamLibrary
```

Select the library directory itself—not its `steamapps` or `common` subdirectory, and not just the drive’s mountpoint.

Steam may call the location an **external drive**. This is normal for a library stored on a separate mounted filesystem; it does not mean the drive must be physically external.

### 6. If the games still do not appear

Find Steam’s Flatpak configuration:

```bash
find ~/.var/app/<FLATPAK_APP_ID> \
  -name libraryfolders.vdf -print 2>/dev/null
```

Then inspect the result:

```bash
grep -n -A6 -B2 '<MOUNTPOINT>\|SteamLibrary' \
  ~/.var/app/<FLATPAK_APP_ID>/data/Steam/steamapps/libraryfolders.vdf
```

The registered path should point to:

```text
<LIBRARY>
```

Do not delete or move the following:

```text
steamapps/
appmanifest_*.acf
steamapps/common/
```

The `appmanifest_*.acf` files tell Steam which games are installed.

### Quick repair commands

```bash
sudo mount -a

flatpak override --user \
  --filesystem=<MOUNTPOINT> \
  com.valvesoftware.Steam

flatpak kill com.valvesoftware.Steam
flatpak run com.valvesoftware.Steam
```

After restarting Steam, add:

```text
<LIBRARY>
```

under **Settings → Storage**.
