# shellcheck shell=bash
# The pinned Alloy package (agent/alloy.pin), sourced by scripts/enroll.sh. The
# VM downloads and checks it once; hosts get it in their bundle.

readonly ALLOY_PIN=agent/alloy.pin
readonly ALLOY_DIR=state/alloy
readonly APT_URL="${ENROLL_APT_URL:-https://apt.grafana.com}"
readonly APT_KEY_FINGERPRINT=B53AE77BADB630A683046005963FA27710458545
readonly DOWNLOAD_TIMEOUT_SECONDS=900

pin_value() { sed -n "s/^$1=//p" "$ALLOY_PIN"; }
download() { curl -fsS --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -o "$2" "$APT_URL/$1" || die "cannot download $APT_URL/$1"; }
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

deb_path() { echo "$ALLOY_DIR/alloy_$(pin_value VERSION)_$1.deb"; }

# Path of the checked package for $1; dies if it is missing or not the pinned one.
alloy_deb() {
  local deb
  deb=$(deb_path "$1")
  [[ -f "$deb" ]] || die "no $deb: scripts/enroll.sh fetch-alloy $1"
  [[ "$(sha256_of "$deb")" == "$(pin_value "SHA256_$1")" ]] || die "$deb does not match $ALLOY_PIN"
  echo "$deb"
}

# $1 key file: exactly one primary key, and it is Grafana's. A second key in the
# file would be trusted as well, so that stops here.
check_apt_key() {
  local keys
  keys=$(gpg --batch --no-autostart --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '$1 == "pub" { pub = 1; next } $1 == "fpr" && pub { print $10; pub = 0 }')
  [[ "$keys" == "$APT_KEY_FINGERPRINT" ]] || die "the apt key is not exactly $APT_KEY_FINGERPRINT; nothing stored"
}

# $1 arch: key -> signed index -> package list -> package, each checked by the one before, and the
# package against the pin in git.
fetch_alloy() {
  local arch="$1" tmp packages_sha filename deb_sha pin
  pin=$(pin_value "SHA256_$arch")
  [[ -n "$pin" ]] || die "no SHA256_$arch in $ALLOY_PIN (Alloy has no 32-bit ARM build)"
  for tool in gpg gpgv curl; do command -v "$tool" >/dev/null || die "$tool is missing"; done
  # enroll.sh removes "stage" on exit.
  stage=$(mktemp -d)
  tmp="$stage"
  export GNUPGHOME="$tmp/gnupg"
  install -d -m 700 "$GNUPGHOME"
  download gpg.key "$tmp/gpg.key"
  check_apt_key "$tmp/gpg.key"
  gpg --batch --no-autostart --dearmor -o "$tmp/key.gpg" "$tmp/gpg.key" 2>/dev/null
  download dists/stable/InRelease "$tmp/InRelease"
  gpgv --keyring "$tmp/key.gpg" --output "$tmp/Release" "$tmp/InRelease" 2>/dev/null || die "bad signature on the apt index; nothing stored"
  packages_sha=$(awk -v file="main/binary-$arch/Packages" '/^SHA256:/ { in_sha = 1; next } /^[^ ]/ { in_sha = 0 } in_sha && $3 == file { print $1 }' "$tmp/Release")
  download "dists/stable/main/binary-$arch/Packages" "$tmp/Packages"
  [[ -n "$packages_sha" && "$(sha256_of "$tmp/Packages")" == "$packages_sha" ]] || die "the package list does not match the signed index; nothing stored"
  read -r filename deb_sha < <(awk -v version="$(pin_value VERSION)" 'BEGIN { RS = ""; FS = "\n" }
    { delete f; for (i = 1; i <= NF; i++) { split($i, kv, ": "); f[kv[1]] = kv[2] }
      if (f["Package"] == "alloy" && f["Version"] == version) print f["Filename"], f["SHA256"] }' "$tmp/Packages") || true
  [[ "$deb_sha" == "$pin" ]] || die "alloy $(pin_value VERSION) $arch in the index is not the pinned package; nothing stored"
  download "$filename" "$tmp/alloy.deb"
  [[ "$(sha256_of "$tmp/alloy.deb")" == "$pin" ]] || die "the downloaded package does not match the pin; nothing stored"
  install -d -m 700 state "$ALLOY_DIR"
  install -m 600 "$tmp/alloy.deb" "$(deb_path "$arch")"
  echo "stored $(deb_path "$arch")"
}
