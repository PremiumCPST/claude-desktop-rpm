# Dépôt dnf claude-desktop-builder

Branche générée par `builder/publish-repo.sh` (voir la branche main).

    sudo dnf config-manager addrepo --from-repofile=https://raw.githubusercontent.com/PremiumCPST/claude-desktop-rpm/repo/claude-desktop.repo
    sudo dnf install claude-desktop-builder
    sudo claude-desktop-update
