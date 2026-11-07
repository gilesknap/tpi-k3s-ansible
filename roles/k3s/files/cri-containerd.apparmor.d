# containerd's default AppArmor profile, installed by the k3s role
# (roles/k3s/tasks/apparmor.yml). containerd does not generate its own
# when a profile of this name is already loaded, so this copy wins.
#
# It is containerd's contrib/apparmor/template.go as rendered on these
# nodes (k3s-io/containerd v2.2.2-k3s1), plus the two rules that name the
# stacked peer cri-containerd.apparmor.d//&unconfined. Diff it against the
# template at each k3s bump, and delete it once containerd ships the fix:
#   https://github.com/containerd/containerd/issues/14485
#
abi <abi/3.0>,

#include <tunables/global>


profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {

  #include <abstractions/base>


  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=unconfined,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=cri-containerd.apparmor.d,
  # Ubuntu 25.04+: kernel.apparmor_restrict_unprivileged_unconfined=1 turns
  # runc's change_onexec into a stack, labelling tasks
  # cri-containerd.apparmor.d//&unconfined. Allow that exact peer too.
  signal (send,receive) peer="cri-containerd.apparmor.d//&unconfined",

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9],[^1-9][^0-9],[^1-9s][^0-9y][^0-9s],[^1-9][^0-9][^0-9][^0-9]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/mem rwklx,
  deny @{PROC}/kmem rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,
  ptrace (trace,tracedby,read,readby) peer="cri-containerd.apparmor.d//&unconfined",
}
