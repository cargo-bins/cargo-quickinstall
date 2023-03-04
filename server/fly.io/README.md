# cargo-quickinstall stats server

## Deploy

```bash
brew install flyctl
flyctl auth login
fly launch --now
# install the 'in' command (needs escaping with \ in bash, but not zsh or powershell)
cargo-quickinstall in-directory
```

Then:

```bash
\in server/fly.io fly deploy
```
