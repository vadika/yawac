# Troubleshooting

## `brew tap` asks for GitHub credentials

`brew tap` runs `git clone` under the hood. GitHub no longer accepts
password auth on git operations, so a stale credential helper can
turn a public-repo clone into:

```
remote: Invalid username or token. Password authentication is not
supported for Git operations.
```

Fixes (pick one):

```sh
# Suppress the credential prompt for this one tap.
GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
  brew tap vadika/yawac https://github.com/vadika/yawac

# Or skip brew entirely and grab the latest release zip directly.
ver=$(curl -sSL https://api.github.com/repos/vadika/yawac/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
curl -L -o /tmp/yawac.zip \
  "https://github.com/vadika/yawac/releases/download/v${ver}/yawac-${ver}.zip"
unzip -o /tmp/yawac.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/yawac.app
open /Applications/yawac.app
```

Builds are ad-hoc signed; the cask strips the macOS quarantine flag
automatically.
