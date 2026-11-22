# RHCSA mock exam 1 (26 tasks, 3 hours)

Two exam nodes, both AlmaLinux 10 (works like RHEL 10):

| Node | Address | Login |
|---|---|---|
| `node1.lab.example` | 10.78.0.11 | `root` / `redhat`, `ssh root@10.78.0.11` |
| `node2.lab.example` | 10.78.0.12 | unknown, see task 16. Use its console in the Proxmox web UI |

`utility.lab.example` (10.78.0.10) provides package repos, NFS, DNS and NTP. Don't change it.

Everything has to survive a reboot: the grader reboots node1 and node2 before it checks.
You need 210 of 300 points (70 %). Points are in brackets. Unless a task says otherwise,
the password for new users is `kubl123`. Man pages and `/usr/share/doc` are allowed.

---

## node1

**1. Repositories (10)**
node1 has no package repositories. Configure these two:
- `http://utility.lab.example/repo/BaseOS`
- `http://utility.lab.example/repo/AppStream`

**2. Users and groups (15)**
- a group `sysops` with the GID 3000
- users `natasha` and `harry`, both with `sysops` as a supplementary group
- a user `sarah` who has no interactive login shell and is not in `sysops`
- all three have the password `kubl123`

**3. sudo (10)**
Members of the group `sysops` may run every command as root with `sudo`, without being
asked for a password.

**4. Shared directory (10)**
Create the directory `/common/sysops`. It belongs to the group `sysops`, members of the
group can read, write and enter it, everybody else has no access. New files in it
automatically belong to the group `sysops`.

**5. Password aging (10)**
- passwords of all users created from now on expire after 90 days
- the password of `harry` expires after 30 days

**6. Default permissions (10)**
Files that `natasha` creates get the permissions `rw-r-----`, directories `rwxr-x---`.

**7. Cron (10)**
The user `natasha` runs `logger "kubl daily check"` every day at 14:23.

**8. Time (10)**
node1 synchronizes its time with `utility.lab.example`.

**9. autofs (15)**
`utility.lab.example` exports `/rhome` over NFS. The user `remoteuser1` already exists on
node1, its home directory is `/rhome/remoteuser1`. Configure autofs so that
`utility.lab.example:/rhome/remoteuser1` is mounted there automatically (read-write) when it
is used.

**10. SELinux (10)**
SELinux on node1 must run in enforcing mode, also after a reboot.

**11. Web server (15)**
The web server on node1 listens on port 82. Make `http://node1.lab.example:82/` show the
existing page `/var/www/html/index.html` to the other machines, with SELinux enforcing.
Don't change the port or the page content. The web server starts at boot.

**12. Find files (10)**
Find all files that belong to the user `jacques` and copy them into the directory
`/root/found` (create it, files only, same names).

**13. Search text (5)**
Write all lines of `/var/log/kubl/app.log` that contain `ERROR` to `/root/errors.txt`,
in the original order.

**14. Archive (5)**
Create a bzip2-compressed tar archive `/root/local.tar.bz2` of the directory `/usr/local`.

**15. Shell script (15)**
Write the script `/usr/local/bin/bigfiles`. It copies all files from `/etc` (including its
subdirectories) that are larger than 100 KB into the directory `/root/bigfiles`, and creates
that directory if it doesn't exist. Run it once.

## node2

**16. Root password (15)**
Nobody knows the root password of node2. Set it to `redhat`. node2 must still boot
normally afterwards (SELinux labels).

**17. Network (20)**
Configure node2 (use the console, the current address is wrong):
- hostname `node2.lab.example`
- static IPv4 address `10.78.0.12/24`, gateway `10.78.0.1`
- DNS server `10.78.0.10`

**18. Repositories (10)**
node2 has no package repositories either. Configure the same two as on node1.

**19. Logical volume (20)**
On a new partition of `/dev/vdb` (GPT), create the volume group `datavg` with an extent size
of 16 MiB. Create the logical volume `datalv` with exactly 20 extents, format it with XFS
and mount it at `/data` at every boot, using its UUID or a label.

**20. Grow a logical volume (15)**
The logical volume `applv` (mounted at `/app`) is too small. Grow it and its filesystem to
800 MiB (760 to 840 MiB is accepted). The data on it must stay.

**21. Swap (15)**
Add a 512 MiB swap partition on `/dev/vdc` that is active at every boot. `/dev/vdc1` is
in use, don't destroy it.

**22. Tuning (5)**
Activate the tuned profile that tuned recommends for this machine.

**23. Journal (10)**
The system journal of node2 is lost at every reboot. Make it persistent.

**24. Process priority (10)**
The service `report-builder` on node2 must run its process with the nice value `10`, also
after a reboot. The service keeps running and starts at boot. Don't change
`/usr/local/bin/report-builder`.

**25. systemd timer (10)**
Create a service `kubl-cleanup.service` that runs `find /var/tmp -name '*.tmp' -delete`,
and a timer `kubl-cleanup.timer` that starts it every hour. The timer is active and starts
at boot.

## node1 and node2

**26. SSH keys (10)**
The user `deploy` exists on both nodes. `deploy` on node1 must be able to log in to node2
as `deploy` with `ssh node2.lab.example`, using a key, without a password.

---

## When you're done

On the Proxmox host, in the `rhcsa-lab` folder:

- `bash rhcsa-lab.sh grade` reboots node1 and node2, checks every task and shows your score
- `bash rhcsa-lab.sh exam 1` starts this exam again from a clean lab
- the solutions are in [`solutions.md`](solutions.md), open them only after grading
