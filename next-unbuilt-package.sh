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
POPULAR_CRATES="
y2z/monolith
ogham/dog
tanakh/cargo-atcoder
bat
benschza/pier
cargo-bump
watchexec
ripgrep
just
tokei
exa
starship
fd-find
kbknapp/docli
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
intel-mkl-tool
lsd
bandwhich
sd
gitui
project_init
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
"

for CRATE in $POPULAR_CRATES; do

  VERSION=$(curl --location --fail "https://crates.io/api/v1/crates/${CRATE}" | jq -r .versions[0].num)
  TARGET_ARCH=$(rustc --version --verbose | sed -n 's/host: //p')

  if curl --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
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
