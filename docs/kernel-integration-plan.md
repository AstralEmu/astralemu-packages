# Plan d'intégration des kernels ROCKNIX dans AstralEmu

Référence : tâche définie le 2026-04-26.
Status : exécuté. Ce document est conservé comme archive du raisonnement
et de la matrice de décision initiale. Quelques décisions ont évolué
pendant l'exécution (notamment : la source de patches handheld AMD a
basculé de "Valve linux-jupiter" — repo désormais inaccessible — vers
le patch handheld de `CachyOS/kernel-patches`, et le mapping firmware
vendor a été mis en attente). Les décisions effectivement livrées sont
toujours documentées dans `CHANGELOG.md`. Ne pas se baser sur les noms
de paquets / sources cités ici pour des modifications futures sans
recroiser avec l'état réel du code.

## Décision d'architecture

Trois kernels couvrent l'intégralité des devices ciblés, alignés sur les
`build_targets` existants (un kernel par target, pas par SoC). Le gain perf
provient de la baseline `-march` + des patches globaux (BORE, CachyOS) +
des patches downstream per-SoC obligatoires (drivers GPU notamment). Les
drivers SoC sont compilés en modules (`=m`) et chargés au runtime selon
le DTB (ARM) ou ACPI (x86), mais avec les patches kernel-tree appliqués.

| Kernel | build_target | Baseline -march | -mtune | Devices couverts |
|---|---|---|---|---|
| `kernel-arm64-legacy` | `arm64-legacy` | `armv8-a+crc+simd` | `cortex-a72` | Switch (Tegra X1, A57), RG35XX H/SP/Plus (H700, A53), RG ARC (S922x, A73), Odroid Go Super (S922x), Powkiddy V90/X55 (RK3566, A55), RG35XX original (RK3326, A35), Anbernic RG406 series (RK3576, A72) |
| `kernel-arm64-modern` | `arm64-modern` | `armv8.2-a+crypto+fp16+rcpc+dotprod` | `cortex-a76` | AYN Thor (sm8550, X3+A715), Retroid Pocket 6 (sm8550), Retroid Pocket 5 (sm8250, A77), Snapdragon 8 Gen 1/2/3 handhelds, Orange Pi 5 / Rock 5 (RK3588, A76), Raspberry Pi 5, sm6115 entry-level Snapdragon |
| `kernel-amd64` | `amd64` | `x86-64-v3` | générique | Steam Deck LCD (Van Gogh, znver2), Steam Deck OLED, ROG Ally / Ally X (Phoenix Z1/Z1E), Legion Go / Legion Go S, MSI Claw (Meteor Lake), GPD Win Mini/Max series, OneXPlayer series, AYANEO series, AYN Loki / Loki Max |

## Sources ROCKNIX à exploiter

Repo : `https://github.com/ROCKNIX/distribution`, branch `main`.

Recettes les plus complètes par famille (à partir desquelles on construit
la fusion). Chacune apporte ses patches downstream — on les unionne dans
le kernel fusionné de la famille correspondante.

- `arm64-legacy` : union des patches de
  - `packages/linux/tegra_x1/` (Switch, nvgpu downstream NVIDIA)
  - `packages/linux/s922x/` (Mali downstream Amlogic)
  - `packages/linux/rk3566/`, `rk3326/`, `rk3576/` (Mali Rockchip)
  - `packages/linux/h700/` (Mali Allwinner)
- `arm64-modern` : union des patches de
  - `packages/linux/rk3588/` (Mali-G610 Rockchip)
  - `packages/linux/sm8550/`, `sm8250/`, `sm6115/` (Adreno Qualcomm)
- `amd64` : `packages/linux/pc-amd-handheld/` (déjà multi-device chez
  ROCKNIX) + cherry-picks Valve linux-jupiter

Pour chaque source ROCKNIX prélevée, traçabilité commit dans le README
du package AstralEmu correspondant.

## Patches à appliquer

### Globaux (les trois kernels)
- BORE scheduler depuis `firelzrd/bore-scheduler` (autonome, applicable
  via `kernel-patches/bore/*.patch`)
- `CONFIG_HZ=1000` (tick rate jeu)
- `CONFIG_PREEMPT=y`, `CONFIG_PREEMPT_FULL=y` (latence basse)
- ThinLTO Clang quand la version kernel + clang le permet (kernel ≥ 6.x
  + clang ≥ 17 = OK)
- schedutil + TEO + uclamp (PR ROCKNIX #2459)
- Tweaks MM/VM portables depuis `CachyOS/kernel-patches`, cherry-pick
  sélectif (les patches non-CPU-specific)
- Binder/ashmem/memfd activés pour préparer Waydroid

### x86_64 uniquement
- AutoFDO/Propeller depuis CachyOS (x86 only, profils dispos)
- AMD P-State EPP optimisé handheld (cherry-pick depuis Valve linux-jupiter)
- HDR patches (depuis Valve)
- jupiter-hw-support equivalents (capteurs, contrôles, fan curves)
- Function multi-versioning sur fonctions chaudes pour Van Gogh / Phoenix
  / Hawk Point / Strix Point quand applicable
- AMDGPU patches Valve (XGMI/SDMA tuning handheld)

### arm64 — patches GPU/SoC OBLIGATOIRES par device

Sans ces patches le device boote au mieux sans accélération, au pire
pas du tout. Toutes ces séries doivent être incluses dans le kernel
fusionné de la famille correspondante.

`kernel-arm64-legacy` :
- **Tegra X1 (Switch)** : nvgpu downstream NVIDIA (recette
  ROCKNIX `tegra_x1`). Sans nvgpu = pas de GPU → kernel inutilisable
  sur Switch. Driver propre tegra-drm en parallèle pour le KMS, mais
  rendering 3D passe par nvgpu blob+kernel.
- **Mali Bifrost / Midgard** (Allwinner H700, Amlogic S922x, Rockchip
  RK3326/RK3566) : driver panfrost upstream + cherry-picks
  ROCKNIX panfrost handheld tweaks
- **RK3576 spécifique** : patches Rockchip downstream pour le
  controller mémoire et DDR scaling
- **Quirks GPIO/I2C/SPI** par SoC pour les contrôles Anbernic /
  Powkiddy (depuis ROCKNIX devicetree overlays)

`kernel-arm64-modern` :
- **Adreno (Qualcomm sm6115/sm8250/sm8550)** : freedreno upstream +
  patches ROCKNIX/CAF downstream (vital pour Snapdragon 8 Gen 2)
- **Mali-G610 RK3588** : panthor (driver upstream Mali-G610) + cherry-
  picks ROCKNIX rk3588 GPU tweaks
- **Modem/RIL/audio Qualcomm** désactivés (pas pertinent handheld
  gaming) sauf l'audio path qui doit rester fonctionnel

### Toggles optionnels (régression possible)

Si un patch perf casse un device, il devient toggleable via une
nouvelle clé `kernel_patches_extra` dans `devices.yml`. Permet de
désactiver pour un device spécifique sans rebuild de tout le kernel
(les patches optionnels génèrent des sous-options sysctl ou cmdline,
le user choisit à l'installation).

### Exclus
- AutoFDO/Propeller sur ARM (pas de profils générés pour ARM)
- Patches CPU-specific cross-arch (AMD patches sur ARM, etc.)
- Tout patch qui régresse un device existant sans toggle

## Format intermédiaire `.pkg.tar` étendu

Le format actuel `meta/` + `root/` reste, avec ajouts pour kernels :

```
meta/
  name             = kernel-<target>
  version          = <upstream>+<short_hash>
  arch             = aarch64 | x86_64
  source_format    = deb
  source_distro    = ubuntu-lts
  kernel_version   = <upstream-X.Y.Z>      [nouveau]
  kernel_flavor    = <target>              [nouveau]
  modules_subpkg   = kernel-<target>-modules  [nouveau, ref vers sub-package]
  dtbs_subpkg      = astralemu-dtbs-<target>  [nouveau, ARM uniquement]
  scripts/postinst = update-initramfs / dracut / mkinitcpio (par distro)
  scripts/postrm   = idem
root/
  boot/vmlinuz-<ver>
  boot/System.map-<ver>
  boot/config-<ver>
  lib/modules/<ver>/...
  lib/firmware/...                       [si ROCKNIX en bundle]
  usr/lib/linux-image-<ver>/dtbs/        [ARM, déplacé dans le sub-package]
```

Sous-packages distincts produits par le même target :
- `kernel-<target>-modules` — gros, ~100-300 MB
- `astralemu-dtbs-<target>` — ARM uniquement, ~10-30 MB
- `astralemu-firmware-<vendor>` — Qualcomm/Rockchip/Allwinner/NVIDIA non
  libre, optionnel, gardé séparé pour respecter GPL stricte

## Postinst par distro

| Distro | Outil | Hook |
|---|---|---|
| Ubuntu/Debian (deb) | `update-initramfs -c -k <ver>` | `pkg-build-deb.sh` génère le postinst |
| Fedora (rpm) | `dracut --regenerate-all -f` | `pkg-build-rpm.sh` génère le scriptlet |
| Arch (pacman) | `mkinitcpio -p linux-<target>` | `pkg-build-pacman.sh` génère l'install |

Le runtime du contenu `meta/scripts/postinst` doit être traduit par
chaque builder de format. À implémenter dans `scripts/pkg-build-*.sh`.

## Découpage en jobs CI — multi-jobs systématique

GitHub Actions plafonne à **6 heures par job** (limite dur). Le
`BUILD_TIMEOUT` interne (5h30) qui était utilisé jusqu'ici est **à
supprimer définitivement** : c'était un pansement qui n'a jamais
empêché les jobs de planter au cap 6h sur les builds lourds. La bonne
réponse est de découper toute compile non-triviale en plusieurs jobs
qui rentrent **confortablement** sous 3h chacun, avec une marge
sécurité de 3h+ par rapport à la limite GH.

Pas de fallback "single-job avec timeout". Le split est la **stratégie
par défaut** pour tous les kernels — pas seulement arm64-legacy.

### Découpage standard pour chaque kernel

Chaque target kernel se décompose en 5 jobs orchestrés via le pattern
aggregator déjà en place pour `libretro-package`. Les sous-jobs partagent
un cache de source patchée + `.config` produit par le job `prep` en amont,
ce qui évite de redupliquer fetch+patches dans chaque sous-job.

```yaml
# packages.yml (extrait, par target kernel)
- id: kernel-<target>-prep
  build_time: 30      # clone + apply patches + savedefconfig
  artifact_type: kernel-prep
  depends_on: []

- id: kernel-<target>-image
  build_time: 60      # vmlinuz/bzImage + DTBs (ARM)
  artifact_type: kernel-image
  depends_on: [kernel-<target>-prep]

- id: kernel-<target>-modules-soc
  build_time: 120     # modules SoC: Tegra/Allwinner/Amlogic/Rockchip/Qualcomm
  artifact_type: kernel-modules
  depends_on: [kernel-<target>-prep]

- id: kernel-<target>-modules-generic
  build_time: 90      # modules génériques: net/usb/audio/fs/crypto/...
  artifact_type: kernel-modules
  depends_on: [kernel-<target>-prep]

- id: kernel-<target>
  build_time: 15      # aggregator: download all artifacts + emit final .pkg.tar
  is_aggregator: true
  depends_on:
    - kernel-<target>-image
    - kernel-<target>-modules-soc
    - kernel-<target>-modules-generic
```

Pour x86 (kernel-amd64), `modules-soc` devient `modules-platform`
(AMD GPU + AMD platform + jupiter-hw drivers + chipset Intel pour le
MSI Claw). La structure reste la même : prep → image → modules-{platform,
generic} → aggregator.

### Estimations cibles par sous-job (toutes < 3h)

| Sous-job | Phase | Temps native |
|---|---|---|
| `kernel-<target>-prep` | clone source + apply patches + savedefconfig | 20-30 min |
| `kernel-<target>-image` | compile vmlinuz/bzImage + DTBs | 30-60 min |
| `kernel-<target>-modules-soc` | compile modules SoC/platform | 60-120 min |
| `kernel-<target>-modules-generic` | compile modules génériques | 45-90 min |
| `kernel-<target>` (agg) | tar + sub-packages | 10-15 min |

Aucun sous-job ne s'approche de la limite 6h. Si un sous-job
borderline est observé en pratique, on le re-split (ex:
`modules-soc` en `modules-soc-arm` + `modules-soc-qcom` +
`modules-soc-rockchip`).

### Implémentation côté code

Le pattern aggregator avec `depends_on` + `is_aggregator: true` existe
déjà (cf. `libretro-package`). Chaque sous-job kernel suit la même
mécanique :

- `kernel-<target>-prep/build.sh` : fait fetch + apply patches + config,
  produit `tar cf prep.tar.zst` avec `src-tree/` + `.config`, le déclare
  via `artifact_type: kernel-prep` (nouveau type, à ajouter dans
  `build-chain.yml`).
- `kernel-<target>-{image,modules-soc,modules-generic}/build.sh` : étapes
  `download-artifact` du prep tar (via le pattern aggregator), puis
  exécute son sous-set de `make` :
  - `image` : `make Image dtbs` (ARM) ou `make bzImage` (x86)
  - `modules-soc` : `make M=drivers/gpu drivers/staging drivers/soc … modules`
    (liste précise par target définie dans le build.sh)
  - `modules-generic` : `make modules` après suppression du sous-tree
    déjà compilé par `modules-soc`, OU plus simple : compile tout puis
    n'upload que `lib/modules/<ver>/kernel/{net,fs,crypto,…}/`
- `kernel-<target>/build.sh` (aggregator) : download les 3 artifacts
  ci-dessus, merge dans `/tmp/pkg/root/`, génère `meta/`, emit-aliases,
  produit le `.pkg.tar` final + sub-packages (`kernel-modules-<target>`,
  `astralemu-dtbs-<target>`).

### Suppression du `BUILD_TIMEOUT` global

À faire dans le commit qui introduit le split multi-jobs :

- Retirer `BUILD_TIMEOUT` de `.github/workflows/build-emulators.yml`
  (ligne ~28).
- Retirer le passage `-e BUILD_TIMEOUT=...` dans `build-chain.yml`.
- Retirer la convention "écrire `timeout` dans `/workspace/build-status`
  + exit 0" dans tous les `build.sh` qui s'en servent (azahar-emu,
  dolphin-emu, duckstation, ppsspp, xemu).
- Le step Build de `build-chain.yml` n'a plus besoin du cas `TIMEOUT=true`
  — la GH Action elle-même cancelle au cap 6h, ce qui est traité comme
  un échec normal du job.

Avantage de la suppression : un job qui plante à 5h59 n'est plus
"silencieusement skipé via timeout=true sans marker". Soit le job
réussit en moins de 3h (split multi-jobs garantit cette enveloppe),
soit il fail explicitement (action de toi côté logs).

## Adaptation du pipeline CI

- `emu-deps-image` doit gagner : `bc bison flex libssl-dev libelf-dev
  cpio kmod rsync zstd device-tree-compiler libncurses-dev`. Bump
  `CACHE_KEY` v6 → v7 pour invalider l'image base.
- ccache reste pertinent pour kernel rebuilds incrémentaux (gain
  ~50% sur le 2e build) — clé dédiée par sous-job kernel pour ne pas
  qu'image et modules se marchent dessus.
- ARM64 : runners natifs `ubuntu-26.04-arm` (compile = 1.5-2× plus
  rapide que QEMU). Cross-compile depuis x86 envisageable mais nécessite
  toolchain `gcc-aarch64-linux-gnu` dans l'image base — pas une priorité
  vu que le multi-jobs garantit qu'on rentre dans 6h en natif.
- Cache de sources kernel : nouveau cache `kernel-source-<target>-<ver>`
  partagé entre `prep` et tous les sous-jobs aval pour éviter de
  re-cloner ~3 GB à chaque run.
- Cache de prep : `kernel-prep-<target>-<short_hash>` contenant la
  source patchée + `.config`, produit par `kernel-<target>-prep`,
  consommé par `image` / `modules-soc` / `modules-generic`.
- Nouveau `artifact_type: kernel-prep` dans `build-chain.yml` (à
  ajouter à côté de `pkg` et `cores`) pour gérer l'upload du tarball
  de prep entre sous-jobs.

## Création des packages

Pour chaque kernel :

```
packages/kernel-<target>/
  build.sh              # orchestre fetch + patches + config + make + emit
  build-image.sh        # sous-script si split: image + dtbs
  build-modules-soc.sh  # sous-script si split: modules SoC
  build-modules-gen.sh  # sous-script si split: modules génériques
  config/
    defconfig.<target>   # base + overrides
  patches/
    bore/*.patch
    cachyos/*.patch
    rocknix-cherry-picks/*.patch
    handheld-extras/*.patch  (x86)
    soc-downstream/                # arm
      tegra_x1/*.patch
      sunxi-h700/*.patch
      meson-s922x/*.patch
      rockchip-rk*/*.patch
      qcom-sm*/*.patch
  README.md             # source ROCKNIX commit, version, patches, GPL
```

`build.sh` séquence (mode mono-job) :
1. Clone source kernel à la version pinned (depuis le tracker
   `.trackers/kernel-<target>-version`)
2. Apply patches dans l'ordre :
   - `patches/bore/`
   - `patches/cachyos/`
   - `patches/soc-downstream/<all-soc>/` (ARM) ou `handheld-extras/` (x86)
   - `patches/rocknix-cherry-picks/`
3. Apply defconfig → savedefconfig pour validation
4. Build :
   - ARM : `make -j$(nproc) Image modules dtbs`
   - x86 : `make -j$(nproc) bzImage modules`
5. `make modules_install INSTALL_MOD_PATH=/tmp/pkg/root INSTALL_MOD_STRIP=1`
6. Copy `arch/$ARCH/boot/Image|bzImage` → `/tmp/pkg/root/boot/vmlinuz-<ver>`
7. Copy DTBs (ARM) → `/tmp/pkg/root/usr/lib/linux-image-<ver>/dtbs/`
8. Generate `meta/{name,version,arch,depends,scripts/postinst,...}`
9. `emit-aliases.sh` pour les Provides/Replaces (`kernel-<target>-l4t`,
   `-rpi4`, etc. selon `TARGET_DEVICES`)
10. tar `.pkg.tar` final (image+modules+dtbs si pas split)

Mode split (si BUILD_TIMEOUT > 4h30 mesuré) :
- `kernel-<target>-prep` : étapes 1-3 + tar du source-tree patché +
  `.config` → artifact `kernel-prep-<target>-<short>`
- `build-image.sh` (target = `kernel-<target>-image`) : restore prep
  artifact, `make Image dtbs`, upload artifact `kernel-image-<target>`
- `build-modules-{soc,gen}.sh` : idem, sous-set de modules ciblé
- `build.sh` (target = `kernel-<target>`, aggregator) : download
  image+modules artifacts, fusionne, emit meta, tar final

## Versioning

- `kernel-<target>` version = `<upstream>+ge<7chars>+<short_hash>`
  exemple : `6.12.4+ge736a04+a3f2b1c` où `ge736a04` est le commit
  upstream et `a3f2b1c` le hash de notre build (build.sh + patches
  + config) — bump automatique à chaque change comme pour
  libretro-package/perf-libs/setperf.
- `.trackers/kernel-<target>-version` stocke la version upstream
  (sortie de `make kernelversion`) pour propager les bumps mineurs.
- Conserver les anciennes versions sur gh-pages (pas de cleanup
  agressif des kernels — le user peut downgrader si régression).

## Intégration dans devices.yml

Pas de nouveau `build_target` à créer. Chaque device hardware reste sur
son `arm64-legacy` / `arm64-modern` / `amd64` actuel. Ajout d'un champ
optionnel `kernel_package` qui pointe vers `kernel-<target>` (non
bloquant si absent — le user installe manuellement le kernel quand il
en veut un).

```yaml
devices:
  - id: l4t
    name: "Nintendo Switch (Tegra X1)"
    build_target: arm64-legacy
    kernel_package: kernel-arm64-legacy   # nouveau, optionnel
    kernel_patches_extra: []              # nouveau, optionnel toggles
    power: 4
    sources:
      - id: l4t-debs
        ...
```

Nouveaux devices à lister sous `devices:` (mapping vers les 3
build_targets existants) :

| device id | build_target | name |
|---|---|---|
| ayn-thor | arm64-modern | AYN Thor (sm8550) |
| retroid-pocket-6 | arm64-modern | Retroid Pocket 6 (sm8550) |
| retroid-pocket-5 | arm64-modern | Retroid Pocket 5 (sm8250) |
| orange-pi-5 | arm64-modern | Orange Pi 5 / Rock 5 (rk3588) |
| anbernic-rg406 | arm64-legacy | Anbernic RG406 series (rk3576) |
| anbernic-rg35xx-h | arm64-legacy | Anbernic RG35XX H/SP/Plus (h700) |
| anbernic-rg-arc | arm64-legacy | Anbernic RG ARC (s922x) |
| odroid-go-super | arm64-legacy | Odroid Go Super (s922x) |
| powkiddy-rk3566 | arm64-legacy | Powkiddy V90/X55 (rk3566) |
| anbernic-rg35xx-orig | arm64-legacy | Anbernic RG35XX original (rk3326) |
| steam-deck-lcd | amd64 | Steam Deck LCD (Van Gogh) |
| steam-deck-oled | amd64 | Steam Deck OLED |
| rog-ally | amd64 | ASUS ROG Ally / Ally X (Phoenix) |
| legion-go | amd64 | Lenovo Legion Go / Legion Go S |
| msi-claw | amd64 | MSI Claw (Meteor Lake) |
| gpd-win | amd64 | GPD Win Mini / Max series |
| onexplayer | amd64 | OneXPlayer series |
| ayaneo | amd64 | AYANEO series |
| ayn-loki | amd64 | AYN Loki / Loki Max |

## Meta-package par device : `kernel-astralemu-<device>`

Un seul `apt install kernel-astralemu-l4t` (ou
`dnf install kernel-astralemu-l4t`) installe l'intégralité du bundle
device-specific produit par notre pipeline :

- le kernel via alias virtuel `kernel-<device>` → résout `kernel-<target>`
- les **modules kernel** via alias `kernel-<device>-modules` → résout
  `kernel-<target>-modules` (sub-package du build kernel — sans lui rien
  ne charge au boot)
- les DTBs (ARM uniquement) via alias `astralemu-dtbs-<device>`
  → résout `astralemu-dtbs-<target>`
- le firmware non-libre du SoC via `astralemu-firmware-<vendor>` (mappé
  par device : Tegra / Qualcomm / Rockchip / Allwinner / Amlogic /
  AMD-handheld / Intel-meteorlake)
- `setperf-<device>` (déjà publié, reste hardware-specific)
- `astralemu-deps-repo` (déjà existant — meta-package pour la config repo)

### Définition

Un nouveau dossier `packages/kernel-astralemu/` produit, par device, un
`.pkg.tar` minimal (zéro fichier dans `root/`) qui ne contient que la
liste des dépendances dans `meta/depends`. Le `pkg-build-deb.sh` actuel
gère déjà ce cas (paquet `Architecture: all` avec uniquement Depends).

```
packages/kernel-astralemu/
  build.sh                     # itère sur chaque device et émet un .pkg.tar par device
  templates/
    deps.<device>.txt          # liste des deps optionnelles per-device (firmware vendor)
  README.md
```

`build.sh` séquence :
1. Pour chaque device (filtré par `TARGET_DEVICES` en mode `per_device`,
   comme setperf) :
   - Génère `meta/name = kernel-astralemu-<device>`
   - Génère `meta/depends` :
     - `kernel-<device>`              (résolu via alias dans le kernel package)
     - `kernel-<device>-modules`      (alias dans le sub-package modules)
     - `astralemu-dtbs-<device>`      (alias dans dtbs sub-package, ARM uniquement)
     - `astralemu-firmware-<vendor>`  (mappé via templates/deps.<device>.txt)
     - `setperf-<device>`             (alias dans setperf, déjà en place)
     - `astralemu-deps-repo`          (config repo, déjà en place)
   - `arch = all` (paquet noarch sans binaires)
   - `version = 1.0.0+<short_hash>` (pattern hash-only avec hash bump)

### Mapping firmware par vendor

`templates/deps.<device>.txt` (un par device) liste les firmwares
vendor-specific à inclure :

| device | firmware deps |
|---|---|
| l4t | astralemu-firmware-tegra |
| anbernic-rg35xx-h | astralemu-firmware-allwinner |
| anbernic-rg-arc, odroid-go-super | astralemu-firmware-amlogic |
| powkiddy-rk3566, anbernic-rg35xx-orig, anbernic-rg406, orange-pi-5 | astralemu-firmware-rockchip |
| ayn-thor, retroid-pocket-{5,6}, sm6115-* | astralemu-firmware-qualcomm |
| steam-deck-*, rog-ally, legion-go, gpd-win, ayaneo, ayn-loki | astralemu-firmware-amd-handheld |
| msi-claw | astralemu-firmware-intel-meteorlake |

Si `templates/deps.<device>.txt` est absent → pas de dépendance
firmware ajoutée (cas de devices "stock" où le firmware mainline du
kernel suffit).

### Fanout via emit-aliases

Les alias virtuels `kernel-<device>`, `kernel-<device>-modules` et
`astralemu-dtbs-<device>` sont émis via `emit-aliases.sh` dans les
`build.sh` correspondants :

- `kernel-<target>/build.sh` → `emit-aliases.sh kernel <meta_dir>` →
  `Provides: kernel-l4t,kernel-rpi4,kernel-anbernic-rg35xx-h,…`
- `kernel-<target>-modules/build.sh` (sub-package) →
  `emit-aliases.sh kernel-modules <meta_dir>` →
  `Provides: kernel-modules-l4t,kernel-modules-rpi4,…`

Wait — emit-aliases prend `<basename>` et produit `<basename>-<device>`.
Donc pour `kernel-modules`, l'alias devient `kernel-modules-l4t`, pas
`kernel-l4t-modules`. Il faut aligner :

- soit appeler `emit-aliases.sh "kernel-${TARGET_ID}-modules"` mais ça
  produit `kernel-arm64-legacy-modules-l4t` ce qui n'est pas le pattern
  voulu.
- soit accepter que les alias soient `kernel-modules-l4t` et adapter
  les Depends du meta-package en conséquence.

**Décision** : adopter le pattern `<basename>-<device>` cohérent avec
le reste, soit `kernel-modules-<device>` pour les modules. Le
meta-package dépend de `kernel-modules-<device>`, pas de
`kernel-<device>-modules`. Pareil pour les DTBs : `dtbs-<device>` (ou
`astralemu-dtbs-<device>` avec basename `astralemu-dtbs`).

Récapitulatif des noms :

| Composant | Vrai nom (canonique) | Alias virtuel résolvable |
|---|---|---|
| Kernel | `kernel-<target>` | `kernel-<device>` |
| Kernel modules | `kernel-modules-<target>` | `kernel-modules-<device>` |
| DTBs | `astralemu-dtbs-<target>` | `astralemu-dtbs-<device>` |
| Firmware | `astralemu-firmware-<vendor>` | (pas d'alias device, partagé) |
| Setperf | `setperf` (avec PROVIDES per-device déjà) | `setperf-<device>` |
| Meta | `kernel-astralemu-<device>` (canonique direct) | (pas d'alias) |

### Statut `per_device`

Le meta-package est `per_device: true` dans `packages.yml` (comme
setperf). Il itère sur chaque device et émet un `.pkg.tar` par device
→ un `kernel-astralemu-<device>` par device hardware sur gh-pages.

```yaml
# packages.yml
- id: kernel-astralemu
  version_source: hash-only
  build_time: 2
  power_arm: 1
  power_amd: 1
  true_arm: true
  true_amd: true
  per_device: true
```

### Bénéfice user

```bash
# Avant (ce que le user devrait taper aujourd'hui pour un Switch)
sudo apt install kernel-arm64-legacy kernel-modules-arm64-legacy \
                 astralemu-dtbs-arm64-legacy astralemu-firmware-tegra \
                 setperf-l4t astralemu-deps-repo

# Après
sudo apt install kernel-astralemu-l4t
```

Et symétriquement :
- `kernel-astralemu-steam-deck-oled` installe kernel-amd64 +
  kernel-modules-amd64 + firmware AMD handheld + setperf-steam-deck-oled
- `kernel-astralemu-orange-pi-5` installe kernel-arm64-modern +
  kernel-modules-arm64-modern + DTBs RK3588 + firmware Rockchip

## Documentation à produire par kernel

`packages/kernel-<target>/README.md` :
- Source ROCKNIX (lien commit exact)
- Version kernel upstream
- Liste des patches ROCKNIX appliqués (par SoC pour ARM)
- Liste des patches AstralEmu ajoutés (BORE, CachyOS, etc.)
- Devices couverts (DTB / ACPI / quirks)
- Note GPL v2 + crédits ROCKNIX/Valve/upstream

`README.md` racine du repo : section "Kernels" listant les 3 packages
et leurs devices supportés.

`CHANGELOG.md` (à créer si absent) : entrée par device ajouté.

## Script `scripts/sync-rocknix-kernels.sh`

Fetch automatique des sources ROCKNIX :
- Clone shallow le repo `ROCKNIX/distribution`
- Pour chaque kernel-<target>, copie `packages/linux/<rocknix_recipe>/patches`
  vers `packages/kernel-<target>/patches/soc-downstream/<recipe>/`
- Met à jour la version pinned dans `.trackers/kernel-<target>-version`
  si ROCKNIX a bump
- Diff-friendly output pour review humaine avant commit

## Validation

- `make build-kernel-<target>` doit réussir sur Ubuntu 26.04 et
  Fedora 43 (matrice CI)
- Sur ARM, validation `dtc` des DTB compilés (pas de hardware physique
  requis)
- Sur x86, boot test sur QEMU avec un rootfs minimal pour valider que
  le bzImage démarre + chargement des modules essentiels
- CI matrice 3 kernels × 2 distros source + republish multi-target
  (apt/dnf) = ~6-12 builds kernels par run complet selon split

## Licence et attribution

- GPL v2 strict, conservation des `Copyright` et `Signed-off-by` dans
  tous les fichiers
- Aucun branding ROCKNIX (logo, nom, artwork)
- Mention dans le README package : `Based on ROCKNIX kernel recipe
  (https://github.com/ROCKNIX/distribution/tree/<commit>/packages/linux/<recipe>),
  GPL v2`
- Patches BORE / CachyOS / Valve : conserver leurs auteurs originaux
  dans le header de chaque `.patch`

## Découpage des commits (pour faciliter le review)

1. `Add kernel-amd64 package skeleton (build.sh, README, GPL note)`
2. `kernel-amd64: BORE scheduler patches`
3. `kernel-amd64: CachyOS portable patches`
4. `kernel-amd64: Valve/jupiter-hw + AMDGPU patches`
5. `kernel-amd64: defconfig + handheld extras`
6. `kernel-amd64: postinst hooks + sub-packages (modules, firmware)`
7. `Add kernel-arm64-modern package skeleton`
8. `kernel-arm64-modern: BORE + CachyOS portable patches`
9. `kernel-arm64-modern: Adreno (Qualcomm) downstream patches`
10. `kernel-arm64-modern: Mali-G610 (Rockchip) downstream patches`
11. `kernel-arm64-modern: defconfig + per-SoC DTBs`
12. `Add kernel-arm64-legacy package skeleton`
13. `kernel-arm64-legacy: Tegra X1 nvgpu downstream patches`
14. `kernel-arm64-legacy: Mali Bifrost/Midgard (Rockchip/Amlogic) patches`
15. `kernel-arm64-legacy: Allwinner H700 patches`
16. `kernel-arm64-legacy: split build (image + modules-soc + modules-gen + aggregator)` (si nécessaire)
17. `kernel-arm64-legacy: defconfig + per-SoC DTBs`
18. `pkg-build-{deb,rpm,pacman}.sh: per-distro postinst translation for kernels`
19. `scripts/sync-rocknix-kernels.sh helper`
20. `devices.yml: add AMD x86 handheld devices`
21. `devices.yml: add Snapdragon ARM handheld devices`
22. `devices.yml: add Rockchip ARM handheld devices`
23. `devices.yml: add Allwinner/Amlogic ARM handheld devices`
24. `Bump emu-deps-image CACHE_KEY v6 -> v7 with kernel build deps`
25. `Documentation: README + CHANGELOG kernel section`

## Pré-requis avant exécution

- [ ] Bump distros sources (Ubuntu 26.04 / Fedora 43) committé et CI verte
- [ ] Décision : runners natifs ARM ou cross-compile depuis x86 ?
      (par défaut : natif, cross-compile si on observe un dépassement
      de 5h30 sur arm64-legacy)
- [ ] CACHE_KEY emu-deps-base bumpé v6 → v7 avec les outils kernel
- [ ] Confirmation que la limite GH Actions reste à 6h en 2026
      (changements possibles côté GitHub à vérifier au moment de
      l'implémentation)
