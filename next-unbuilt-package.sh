#!/bin/bash

set -euxo pipefail

# To re-generate this list, run:
#     curl https://lib.rs/command-line-utilities > cli.html
#     cat cli.html |
#         pup ':parent-of(:parent-of(:parent-of(.bin))) json{}' |
#         jq -r '.[] |
#             (.children[1].children|map(select(.class == "downloads").title)[0]// "0 ")
#             + ":" +
#             (.children[0].children[0].text)' |
#         sort -gr |
#         head -n 100 |
#         sed s/^.*://
# and then audit any new entries.
#
# TODO: re-add crates from the quickinstall stats server at the top of the list,
# once someone has audited my github-actions sandboxing.
POPULAR_CRATES="
cargo-quickinstall
bat
cargo-bump
watchexec
ripgrep
just
tokei
exa
starship
fd-find
cargo-binutils
skim
gptman
streampager
rustdoc-stripper
du-dust
procs
broot
petname
bottom
dijo
elf2tab
lsd
bandwhich
sd
hyperfine
scryer-prolog
rsign2
wrangler
tealdeer
tin-summer
nj-cli
zoxide
cargo-rpm
mdcat
rustscan
rust-latest
jql
hexyl
git-delta
sgxs-tools
spotify-tui
fw
routinator
my-iot
critcmp
yaksay
rusty-tags
b3sum
dutree
tp-note
ffsend
git_lab_cli
viu
dotenv-linter
feroxbuster
sane-fmt
podcast
ff-find
cargo-trim
kmon
file-sniffer
grex
so
what-bump
xcompress
tab
dtn7
code-minimap
nitrocli
fblog
rexcli
zdump
navi
verco
svlint
emplace
spl-token-cli
bacon
yatt
stack-sizes
mdblog
complate
phetch
kurobako
flowy
rust-covfix
cobalt-bin
kickstart
gitoxide
otpcli
i2p_client
sniffglue
rmesg
investments
hunter
rpick
cicada
"

# FIXME: make a signal handler that cleans this up if we exit early.
if [ ! -d "${TEMPDIR:-}" ]; then
  TEMPDIR="$(mktemp -d)"
fi

# see crawler policy: https://crates.io/policies
curl_slowly() {
  sleep 1 && curl --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

for CRATE in $POPULAR_CRATES; do

  rm -rf "$TEMPDIR/crates.io-response.json"
  curl_slowly --location --fail "https://crates.io/api/v1/crates/${CRATE}" >"$TEMPDIR/crates.io-response.json"
  VERSION=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].num)
  TARGET_ARCH=$(rustc --version --verbose | sed -n 's/host: //p')
  LICENSE=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].license | sed -e 's:/:", ":g' -e 's/ OR /", "/g')

  if [[ "$LICENSE" = "BSD-3-Clause" || "$LICENSE" = "non-standard" ]]; then
    # FIXME: I should really do some kind of license translation so that bintray will accept my packages.
    echo "Skipping ${CRATE} to avoid \"License 'BSD-3-Clause' does not exist\" error when uploading."
  elif curl_slowly --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Keep going."
  else
    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz needs building"
    echo "::set-output name=crate_to_build::$CRATE"
    echo "::set-output name=version_to_build::$VERSION"
    echo "::set-output name=arch_to_build::$TARGET_ARCH"
    exit 0
  fi
done
# If there's nothing to build, just build ourselves.
echo "cargo-quickinstall"
