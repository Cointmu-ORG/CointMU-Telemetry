# shellcheck shell=bash
# The commands enroll.sh prints for the operator's workstation, sourced by
# scripts/enroll.sh. The bundle goes through a pipe on the workstation: no
# secret on a command line, nothing stored there, no SSH access from the VM.

readonly VM_SSH="${ENROLL_VM_SSH:-server104}"

# $1 ssh target, $2 remote path of the bundle, $3 sha256.
print_transfer() {
  cat <<CMD
set -o pipefail; ssh $VM_SSH 'cd $PWD && scripts/enroll.sh bundle $h_host' | ssh $1 'umask 077; cat > $2 && echo "$3  $2" | sha256sum -c'
CMD
}

print_commands() {
  local sha bundle="$h_host.tar" ctid pve
  sha=$(sha256sum "$(bundle_file "$h_host")" | cut -d' ' -f1)
  echo "# On your workstation, in this order (the bundle is kept on the VM until verify passes, at most 24 h):"
  case "$h_type" in
    pve)
      print_transfer "$h_ssh" "/root/$bundle" "$sha"
      echo "ssh -t $h_ssh 'd=\$(mktemp -d) && tar -xf /root/$bundle -C \$d ./install-agent.sh && bash \$d/install-agent.sh /root/$bundle'"
      ;;
    linux)
      print_transfer "$h_ssh" "\$HOME/$bundle" "$sha"
      echo "ssh -t $h_ssh 'sudo bash -c \"d=\\\$(mktemp -d) && tar -xf \$HOME/$bundle -C \\\$d ./install-agent.sh && bash \\\$d/install-agent.sh \$HOME/$bundle\"'"
      ;;
    lxc)
      pve="${h_via%:*}"
      ctid="${h_via##*:}"
      print_transfer "$pve" "/root/$bundle" "$sha"
      echo "ssh -t $pve 'trap \"shred -u /root/$bundle\" EXIT; pct push $ctid /root/$bundle /root/$bundle --perms 0600 --user 0 --group 0 && pct exec $ctid -- bash -c \"d=\\\$(mktemp -d) && tar -xf /root/$bundle -C \\\$d ./install-agent.sh && bash \\\$d/install-agent.sh /root/$bundle\"'"
      ;;
  esac
  echo "ssh $VM_SSH 'cd $PWD && scripts/enroll.sh verify $h_host'"
}
