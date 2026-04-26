# Tegra X1 / Nintendo Switch — recherches kernel

Dossier de recherche compilé le 2026-04-26 pour préparer un éventuel
PoC futur de port mainline 6.x sur Tegra X1. La décision pour la
première itération AstralEmu est documentée à la fin.

## Hardware en jeu

- **SoC** : NVIDIA Tegra X1 (T210 / Erista) — sortie 2015
- **CPU** : 4× Cortex-A57 + 4× Cortex-A53 (big.LITTLE désactivé sur Switch)
- **GPU** : Maxwell GM20B (256 cores CUDA)
- **Variante T210B01** ("Mariko") : Switch v2/Lite/OLED, mêmes drivers
- **Devices visés par AstralEmu** : Nintendo Switch (mode handheld /
  docked) — abandonné côté Nintendo, communauté CFW Hekate active

## Écosystème kernel disponible

### NVIDIA officiel

| Distribution | Kernel | Statut Tegra X1 |
|---|---|---|
| L4T 32.x | 4.9 | **Dernière version pour T210**. EOL janvier 2024 |
| L4T 35.x (Jetson Linux 35) | 5.10 | **Pas porté sur T210**, Xavier/Orin only |
| L4T 36.x | 5.15 | **Pas porté sur T210**, Orin only |

NVIDIA a volontairement arrêté le support T210 (Jetson Nano EOL'd 2024).
Aucun successeur kernel n'est prévu côté NVIDIA pour cette génération.

### Communauté Switch (Switchroot et forks)

Tous les forks descendent de `CTCaer/switch-l4t-kernel-4.9` (kernel 4.9,
patches Switchroot/Switchroot pour BCM4356 wifi, audio Realtek,
joycon-hid, DVFS spécifique Switch).

| Repo | Last code commit | Kernel | Notes |
|---|---|---|---|
| `CTCaer/switch-l4t-kernel-4.9` | 2024-03-08 | 4.9 | Référence historique, 53★, **inactif >2 ans** |
| `theofficialgman/switch-l4t-kernel-4.9` | 2024-09-26 | 4.9 | Lié à `theofficialgman/l4t-debs` ; **inactif >1 an** |
| **`NaGaa95/switch-l4t-kernel-4.9`** | **2026-04-01** | 4.9 | **Seul fork actif** ; tweaks GPU/thermal/voltage 2025-10, "erista support" 2026-04 |
| `aomsin2526/switch-l4t-kernel-4.9` | 2023-08-23 (code), 2026-01-31 (sync only) | 4.9 | Inactif côté code |
| `DigiJLinux/switch-l4t-kernel-6.1` | **2023-08** (last code) | 6.1 | **Tentative de port mainline → abandonnée**. Les commits 2025 sont juste des README updates. Dépend de overlays externes (`nvidia/`, `nvgpu/`, `nvgpu-next/`, `nvidia-t23x/`) qui ne sont pas dans le repo |

### Mainline Linux upstream

- `arch/arm64/boot/dts/nvidia/tegra210.dtsi` : DTB pour T210 (boot OK)
- `drivers/gpu/drm/tegra/` : KMS/display upstream (fonctionne sur Switch)
- `drivers/gpu/drm/nouveau/` : driver libre Maxwell GM20B
  - **3D acceleration limité** : ~10-30% des perfs vs nvgpu blob
  - Manque le firmware GM20B en mode signed (NVIDIA blob)
  - Suffisant pour 8/16-bit / Mednafen, **insuffisant pour PSP/N64
    plein écran ou émulateurs PS2+ via Vulkan**
- `drivers/usb/`, `drivers/mmc/`, `drivers/iio/` : majoritairement
  upstream, fonctionnels

Le projet **grate** (reverse-engineered Tegra GPU) cible surtout
Tegra K1 (Kepler) et n'a pas avancé significativement sur Maxwell GM20B.

### Forks community mainline

| Repo | Kernel | Statut |
|---|---|---|
| `hexdump0815/linux-mainline-tegra-x1-kernel` | 5.16 | **Abandonné déc. 2022** |
| `postmarketOS nintendo-nx` | 4.16 | Port WIP, kernel panic au boot. Pas de package officiel. |
| `NVIDIA/tegra-nouveau-rootfs` | mainline | Manifest Arch ARM rootfs, juste un proof-of-concept, pas un kernel |
| Pixel C upstream port | 6.x | Pixel C utilise T210 mais a son propre BSP, pas reusable directement pour Switch |

**Aucun port mainline 6.x n'est complet et fonctionnel pour Switch
en 2026-04**.

## Pourquoi le port 4.9 → 6.x est non trivial

### APIs kernel changées entre 4.9 (2016) et 6.x (2022+)

- `device_node` → `fwnode_handle` API
- DMA framework refactor (DMA-BUF moderne)
- PWM, regulator, clk, PHY frameworks tous refactorés
- cgroup v1 → cgroup v2
- IRQ subsystem refactor
- BPF, io_uring, mémoire compressée, schedutil → tout new

### Code downstream NVIDIA volumineux

- **nvgpu** (driver GPU 3D Maxwell GM20B) : ~500k lignes C, écrit
  contre kernel 4.9 APIs, jamais porté upstream pour T210 par NVIDIA.
- `host1x` downstream : version étendue vs upstream
- Tegra-specific : `t210-fuse`, `t210-pmc`, `t210-dvfs`, `t210-emc` —
  drivers EMC scaling spécifiques au T210
- BPMP firmware interface : différente entre 4.9 et 6.x

### Tentatives passées

- DigiJLinux 2023 : ~6 mois de travail, abandonné — kernel boote partiellement,
  GPU 3D non fonctionnel
- Switchroot officiel : aucun effort de port en cours
- NVIDIA officiel : non, T210 EOL'd

### Estimation effort

- Boot minimal sur 6.x sans GPU 3D : 2-4 semaines kernel dev
- + driver GPU 3D nvgpu porté : 2-3 mois
- + WiFi BCM4356 / audio / joycon-hid backports : 2-4 semaines
- + tweaks DVFS Switch-specific : 1-2 semaines
- **Total : ~3-6 mois temps plein un dev kernel senior**

## Userspace L4T fourni par théofficialgman/l4t-debs

Snapshot du repo (2026-04-26) :

### Essentiels hardware Switch — à conserver dans le mirror filtré
- `nvidia-bsp-32-3` (BSP)
- `nvidia-l4t-3d-core` (GPU 3D blob, dépend du kernel L4T)
- `nvidia-l4t-ccp-t210ref` (T210 platform code)
- `nvidia-l4t-configs`
- `nvidia-l4t-core`
- `nvidia-l4t-cuda`
- `nvidia-l4t-firmware`
- `nvidia-l4t-init`
- `cuda-cudart` (CUDA runtime — peut servir certaines émulations)
- `cuda-license`
- `joycond` (Joy-Con bluetooth daemon)
- `libffi` (rebuild custom Switch)
- `xorg-server`, `xserver-xorg-input-joystick`, `xserver-xorg-input-libinput`
- `switch-dconf-customizations`, `switch-dock-handler`,
  `switch-joystick-mouse`, `switch-sddm-rule`, `switch-touch-rules`

### Hors scope handheld emu — à exclure du mirror
- `chromium-browser` (rien à voir avec hardware Switch)
- `switch-flatpak` (le user installe son flatpak comme il veut)
- `yt-dlp` (générique, pas Switch-specific)
- `libwidevinecmd0` (DRM Netflix proprio)

L'utilisateur AstralEmu installera ce qu'il veut côté apps via le repo
général ; le mirror Switch ne fournit que le strict nécessaire au
fonctionnement matériel.

## Décision pour la première itération AstralEmu

| Composant | Source | Format AstralEmu |
|---|---|---|
| **Kernel Switch** | `NaGaa95/switch-l4t-kernel-4.9` (compilé par notre pipeline) | Nouveau target dédié `kernel-tegra-x1` |
| **Modules + DTBs Switch** | Idem (du build NaGaa95) | sub-packages `kernel-modules-tegra-x1`, `astralemu-dtbs-tegra-x1` |
| **Firmware Maxwell GM20B + binary blobs** | Mirror filtré `theofficialgman/l4t-debs` (whitelist) | sub-package `astralemu-firmware-tegra` (binaire NVIDIA, séparé pour respecter GPL) |
| **Userspace nvidia-l4t-** + xorg + joycond | Mirror filtré `theofficialgman/l4t-debs` | source mirror dans `devices.yml` (déjà en place, à ajuster avec whitelist) |
| **BORE / CachyOS** | **Non applicable** (kernel 4.9 incompatible) | Décision documentée |

### Conséquences

- Le `kernel-tegra-x1` devient **un 4ème target kernel** dans
  AstralEmu, distinct de `kernel-arm64-{legacy,modern,amd64}` qui
  ciblent kernel 6.x.
- Le `kernel-tegra-x1/build.sh` clone NaGaa95 et compile contre kernel
  4.9 — pas de patches BORE/CachyOS appliqués.
- Le mirror de `l4t-debs` ajoute une **whitelist** dans `devices.yml`
  pour éviter de republier les paquets hors-scope.

## Pistes pour le PoC futur

Quand on s'attaquera au port mainline 6.x :

1. **Partir de DigiJLinux** (kernel 6.1, mid-port) plutôt que de zéro
   - Reprendre les overlays `nvidia/`, `nvgpu/`, `nvgpu-next/` qu'il
     pointait
   - Identifier ce qui boote vs ce qui ne boote pas
2. **Tester nouveau (driver libre) en alternative** pour les usages
   où PSP/N64 perf n'est pas critique
3. **Backporter les drivers Switch (BCM4356, audio, joycon-hid)** sur
   6.x si pas déjà upstream
4. **Suivre l'éventuel travail de Switchroot** sur leur GitLab privé —
   parfois des branches non publiques existent
5. **Aligner sur la version LTS du kernel-arm64-legacy** (6.6 LTS
   probablement) pour partager BORE/CachyOS et la maintenance ROCKNIX
6. **Évaluer l'option "mainline + nouveau"** comme fallback "léger"
   pour les users qui préfèrent un kernel récent au prix de perfs GPU
   moindres

## Sources

- [CTCaer/switch-l4t-kernel-4.9](https://github.com/CTCaer/switch-l4t-kernel-4.9)
- [NaGaa95/switch-l4t-kernel-4.9](https://github.com/NaGaa95/switch-l4t-kernel-4.9)
- [DigiJLinux/switch-l4t-kernel-6.1](https://github.com/DigiJLinux/switch-l4t-kernel-6.1)
- [hexdump0815/linux-mainline-tegra-x1-kernel](https://github.com/hexdump0815/linux-mainline-tegra-x1-kernel)
- [theofficialgman/l4t-debs](https://github.com/theofficialgman/l4t-debs)
- [Switchroot wiki — L4T Linux Distributions](https://wiki.switchroot.org/wiki/linux/linux-distributions)
- [postmarketOS Nintendo Switch (nintendo-nx) wiki](https://wiki.postmarketos.org/wiki/Nintendo_Switch_(nintendo-nx))
- [grate-driver / postmarketOS Tegra mainline article](https://tuxphones.com/nvidia-tegra-mainline-linux-grate-postmarketos/)
- [NVIDIA L4T 32 R28.3.1 release page](https://developer.nvidia.com/embedded/linux-tegra-r2831)
- [NVIDIA Jetson Linux 35.x docs](https://docs.nvidia.com/jetson/l4t/Tegra%20Linux%20Driver%20Package%20Development%20Guide/kernel_custom.html)
