// SPDX-License-Identifier: GPL-2.0-only
/* Generic build: everything that differs from card to card is read at run time from
 * \GPU-UNLOCK\PROFILE.TXT, which the program writes itself on its first (read-only) "enrollment" boot.
 * Which cards are accepted is decided by the chip table in app.c (RTX 4090 verified; AD103/AD104/AD106 experimental). */
#pragma once
#include <Uefi.h>
#ifndef GU_GENERIC
#define GU_GENERIC 1
#endif
typedef struct {
  UINT32 segment, bus, device, function, subsystem, class_revision, bar0, bar_granularity, vram_mib, rom_bytes;
  char rom_sha256[65], prom_sha256[65];
  UINT32 board_id;       /* PCI vendor/device dword, e.g. 0x268410de for an RTX 4090 */
  UINT32 chip;           /* BOOT0 register value read at enrollment; later boots must read the same value */
  UINT32 trial_required; /* optional key: force the experimental trial flow on any card (can only make it stricter) */
  UINT32 experimental;   /* derived: the card is not in the verified tier, or trial_required is set */
  const char *name;      /* derived: marketing name from the chip table */
} GU_PROFILE;
extern GU_PROFILE GuProfile;
#define GU_BOARD_ID (GuProfile.board_id)
#define GU_BOARD_CHIP (GuProfile.chip)
#define GU_TARGET_PCI_ID (GuProfile.board_id)
#define GU_BAR_SIZE 0x1000000U
#define GU_SEGMENT (GuProfile.segment)
#define GU_BUS (GuProfile.bus)
#define GU_DEVICE (GuProfile.device)
#define GU_FUNCTION (GuProfile.function)
#define GU_BOARD_SUBSYSTEM (GuProfile.subsystem)
#define GU_CLASS_REVISION (GuProfile.class_revision)
#define GU_BAR0_CONFIG (GuProfile.bar0)
#define GU_BAR_BASE ((UINT64)GuProfile.bar0)
#define GU_BAR_GRANULARITY (GuProfile.bar_granularity)
#define GU_VRAM_MIB (GuProfile.vram_mib)
#define GU_ROM_BYTES (GuProfile.rom_bytes)
#define GU_ROM_SHA256 (GuProfile.rom_sha256)
#define GU_PROM_SHA256 (GuProfile.prom_sha256)
