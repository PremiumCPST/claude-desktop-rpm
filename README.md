# Claude Desktop en RPM (Fedora, RHEL et dérivés)

Reconstruit localement le `.deb` officiel de Claude Desktop publié par Anthropic
en un vrai paquet RPM, installable et désinstallable avec `dnf`.

## Pourquoi un script et pas un .rpm tout fait

Claude Desktop est propriétaire et ses conditions (Consumer Terms d'Anthropic)
n'accordent aucun droit de redistribution. Le RPM ne doit donc pas être publié :
chacun le reconstruit sur sa machine à partir du `.deb` téléchargé chez Anthropic.

## Installation rapide (dépôt dnf, mises à jour automatiques)

```bash
# Fedora 41+ (dnf5)
sudo dnf config-manager addrepo --from-repofile=https://premiumcpst.github.io/claude-desktop-rpm/claude-desktop.repo
# RHEL / Alma / Rocky 9+ (dnf4) : sudo dnf config-manager --add-repo <même URL>

sudo dnf install claude-desktop-builder
sudo claude-desktop-update                                # télécharge, reconstruit et installe Claude Desktop
sudo systemctl enable --now claude-desktop-update.timer   # optionnel : vérification quotidienne
```

Le dépôt ne contient que **claude-desktop-builder** (scripts sous licence MIT,
aucun code d'Anthropic) : la commande `claude-desktop-update`, ce script, le
.spec et un timer systemd. L'application elle-même est toujours téléchargée chez
Anthropic et reconstruite sur votre machine.

`claude-desktop-update --check` indique seulement si une mise à jour existe ;
`--force` reconstruit même à jour. Le build tourne sous l'utilisateur système
non privilégié `claude-desktop-builder` ; seul `dnf install` s'exécute en root.

## Utilisation manuelle (sans le dépôt)

```bash
sudo dnf install rpm-build binutils file xz curl gnupg2 desktop-file-utils
bash build-rpm.sh                  # télécharge la dernière version et construit le RPM dans ./build
sudo dnf install ./build/claude-desktop-*.rpm
```

Options utiles :

| Option | Effet |
|---|---|
| `--deb FICHIER` | utiliser un `.deb` déjà téléchargé depuis claude.ai/download |
| `--arch aarch64` | construire pour ARM64 (sinon l'architecture de la machine) |
| `--release N` | numéro de release RPM (pour reconstruire la même version) |
| `--outdir DIR` | dossier de sortie (défaut `./build`) |
| `--keep` | garder l'arbre de build pour inspection |
| `--nocheck` | sauter la validation du `.desktop` |
| `--nodeps` | seulement pour construire depuis une machine non RPM (Ubuntu avec l'outil `rpm`) |

Pour mettre à jour : relancer le script, puis `sudo dnf upgrade ./build/claude-desktop-*.rpm`.
Le paquet ne se met pas à jour tout seul.

## Téléchargement vérifié

Sans `--deb`, le script passe par le dépôt apt officiel
(`downloads.claude.ai/claude-desktop/apt/stable`) et vérifie toute la chaîne :
empreinte de la clé Anthropic (`31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`,
publiée sur support.claude.com), signature GPG de `InRelease`, SHA256 de l'index
`Packages`, puis SHA256 du `.deb`. Toute incohérence arrête le build.

## Ce que fait la conversion

- **Charge utile intacte** : `/usr/lib/claude-desktop` est copié tel quel, avec les
  modules natifs Linux (`@ant/claude-native`, `node-pty`) dont Claude Code a besoin.
  Le script vérifie que ce sont bien des ELF de la bonne architecture.
- **Dépendances** : les dépendances sur les bibliothèques système sont générées
  automatiquement par rpmbuild à partir des binaires (sonames), donc justes sur
  Fedora comme sur RHEL. Les bibliothèques embarquées par Electron (`libffmpeg.so`,
  `libEGL.so`, etc.) sont détectées et exclues, pour ne pas réclamer des paquets
  inexistants ni polluer les `Provides` du système. Les autres dépendances reprennent celles du `.deb` officiel (vérifiées sur la
  2.31226.1) avec les noms Fedora/RHEL : `gtk3`, `nss`, `libnotify`, `libsecret`,
  `libXtst`, `libdrm`, `mesa-libgbm`, `at-spi2-core`, `libuuid`, `xdg-utils`,
  `pipewire-libs` (partage d'écran sous Wayland) et `xdg-desktop-portal`.
  Backend de portail, corbeille, trousseau et icône de barre système sont en `Recommends` ;
  QEMU/KVM pour Cowork en `Suggests`.
- **Bureau** : le `.desktop` et les icônes hicolor d'origine sont repris et le
  `.desktop` est validé par `desktop-file-validate`. Un fichier AppStream
  (`/usr/share/metainfo`) est ajouté pour que GNOME Logiciels et Discover listent l'app.
- **Scripts post-install** : aucun. Sur Fedora ≥ 28 et RHEL ≥ 8, les caches
  d'icônes, la base `.desktop` et les types MIME sont rafraîchis par les
  *file triggers* du système. Le `postinst` Debian n'est pas repris : il sert au
  profil AppArmor d'Ubuntu (inutile sous SELinux) et à l'ajout du dépôt apt.
  Une copie des scripts Debian est déposée dans `build/debian-maintscripts-<version>/`
  pour relecture.
- **Sandbox Chromium** : `chrome-sandbox` reste setuid root (4755), vérifié après le build.
- **Versions** : `epoch:version-révision` Debian devient `Epoch`, `Version` et
  `Release` RPM, pour que les mises à jour se comparent correctement.
- Pas de debuginfo, pas de strip, pas de liens `/usr/lib/.build-id` (évite les
  conflits avec d'autres applis Electron).

## Publication du dépôt

À chaque push sur `main`, GitHub Actions (`.github/workflows/publish.yml`)
construit le paquet `claude-desktop-builder` dans un conteneur Fedora, génère
les métadonnées `createrepo_c` et publie le tout sur GitHub Pages. Pour une
nouvelle version des scripts, augmenter `Version` (ou `Release`) dans
`builder/claude-desktop-builder.spec` avant de pousser.

## Fichiers

- `build-rpm.sh` : téléchargement vérifié, extraction, contrôles, appel à rpmbuild.
  Seuls ce script et `claude-desktop.spec` sont nécessaires, dans le même dossier.
- `claude-desktop.spec` : spec RPM, paramétrée par le script.
- `builder/` : paquet `claude-desktop-builder` (spec, `claude-desktop-update`, service et
  timer systemd, utilisateur sysusers) et `make-srpm.sh`.
- `.github/workflows/publish.yml` : construction et publication du dépôt dnf.
- `LICENSE` : MIT, pour les scripts uniquement.
- `tests/make-fixture-deb.sh` : fabrique un faux `.deb` à la structure officielle.
- `tests/test-apt-chain.sh` : rejoue la chaîne de téléchargement contre un faux
  dépôt apt signé (option `--tamper` pour vérifier le rejet d'un `.deb` altéré).
