/* Modified 2026-10-24: profile-pinned RTX 4090 Windows preboot port.
 * Derived from TOTORONG/AD103_win_unlocker 51df9c17; GPL-2.0-only. */
/* Modified 2026-10-21: experimental AD103 32GB GA102-pair port; see PORT-NOTES.txt. */
#include "app.h"
#include "app_io.h"
#include "compat/compat.h"
#include "checks.h"
#include "sha256.h"
#include "prom_profile.h"
#include "ownership.h"
#include "state_checks.h"
#include "security.h"
#include "format.h"
#include <stdarg.h>
#include "vendor/unlock_610.h"
#include "vendor/gfw_eval.h"
#include <Protocol/GraphicsOutput.h>
#include <IndustryStandard/Acpi.h>
#include <Guid/GlobalVariable.h>
static EFI_GUID PciGuid=EFI_PCI_IO_PROTOCOL_GUID,GopGuid=EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID,
  PathGuid=EFI_DEVICE_PATH_PROTOCOL_GUID;
static EFI_SYSTEM_TABLE *Table;
static UINT32 InitialConfig[64];
static const char *Stage;
static BOOLEAN ExpectDetached;
static GU_RELEASE_OWNER PendingOwner;
static EFI_STATUS Step(EFI_STATUS Status) {
  GuLog("CHECK stage=%s status=%#llx\n",Stage,(unsigned long long)Status);
  return !GuLogReady() && !EFI_ERROR(Status)?EFI_DEVICE_ERROR:Status;
}
static VOID ConfigLog(const UINT32 *Config) {
  for(UINTN i=0;i<64;i+=4)GuLog("config[%02x]=%08x %08x %08x %08x\n",
    (unsigned)(i*4),Config[i],Config[i+1],Config[i+2],Config[i+3]);
}
static BOOLEAN DisplayCheck(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0,physical=0,matched=0;
  EFI_STATUS status=Gu.bs->LocateHandleBuffer(ByProtocol,&GopGuid,NULL,&count,&handles);
  if(status==EFI_NOT_FOUND && ExpectDetached)return GuLogReady();
  if(EFI_ERROR(status) || count>128 || (count && !handles)){if(handles)GuFree(handles);return FALSE;}
  for(UINTN i=0;i<count;i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *g=NULL;EFI_DEVICE_PATH_PROTOCOL *path=NULL;
    status=Gu.bs->HandleProtocol(handles[i],&GopGuid,(VOID **)&g);
    if(EFI_ERROR(status) || !g || !g->Mode){status=EFI_COMPROMISED_DATA;break;}
    if(!g->Mode->FrameBufferBase && !g->Mode->FrameBufferSize)continue;
    physical++;
    status=Gu.bs->HandleProtocol(handles[i],&PathGuid,(VOID **)&path);
    if(EFI_ERROR(status) || !path){status=EFI_UNSUPPORTED;break;}
    EFI_HANDLE parent=NULL;status=Gu.bs->LocateDevicePath(&PciGuid,&path,&parent);
    if(EFI_ERROR(status) || parent!=Gu.handle){status=EFI_UNSUPPORTED;break;}
    if(!g->Mode->Info || g->Mode->SizeOfInfo<sizeof(*g->Mode->Info) ||
       !g->Mode->FrameBufferSize || !g->Mode->Info->VerticalResolution ||
       !g->Mode->Info->HorizontalResolution || g->Mode->Info->PixelFormat>PixelBlueGreenRedReserved8BitPerColor ||
       g->Mode->Info->PixelsPerScanLine<g->Mode->Info->HorizontalResolution ||
       (UINT64)g->Mode->Info->PixelsPerScanLine*g->Mode->Info->VerticalResolution>g->Mode->FrameBufferSize/4) {
      status=EFI_COMPROMISED_DATA;break;
    }
    matched++;
  }
  GuFree(handles);
  GuLog("GOP physical=%zu target=%zu expect_detached=%u status=%#llx\n",(size_t)physical,(size_t)matched,
    ExpectDetached,(unsigned long long)status);
  return !EFI_ERROR(status) && physical==matched && matched==(ExpectDetached?0U:1U) && GuLogReady();
}
#include "handoff.inc"
static EFI_STATUS ReadConfig(UINT32 *Config) {
  for(UINTN i=0;i<64;i++)if(EFI_ERROR(GuConfigRead(EfiPciIoWidthUint32,(UINT32)i*4,&Config[i]))) {
    GuLog("PCI config read failed: offset=%#x valid_bytes=%u; snapshot incomplete\n",(unsigned)(i*4),(unsigned)(i*4));
    return EFI_DEVICE_ERROR;
  }
  return EFI_SUCCESS;
}
static EFI_STATUS ConfigCheck(BOOLEAN Save) {
  UINT32 config[64];GU_CAPS caps;UINTN segment,bus,device,function;
  EFI_STATUS status=Gu.pci->GetLocation(Gu.pci,&segment,&bus,&device,&function);
  GuLog("target location: status=%#llx\n",(unsigned long long)status);
  if(EFI_ERROR(status))return status;
  status=ReadConfig(config);if(EFI_ERROR(status))return status;
  BOOLEAN checked=GuCheckConfig(config,segment,bus,device,function,&caps);
  BOOLEAN valid=checked && config[2]==GU_CLASS_REVISION &&
    config[0x10/4]==GU_BAR0_CONFIG && !(config[(caps.pcie+8)/4]&0x00200000U);
  BOOLEAN same=Save || !memcmp(config,InitialConfig,sizeof(config));
  if(Save || !valid || !same)ConfigLog(config);
  GuLog("target BDF=%zu:%zu:%zu.%zu checks=%u pm=%#x pcie=%#x msi=%#x msix=%#x\n",
    (size_t)segment,(size_t)bus,(size_t)device,(size_t)function,checked,
    (unsigned)caps.pm,(unsigned)caps.pcie,(unsigned)caps.msi,(unsigned)caps.msix);
  if(!valid)return EFI_UNSUPPORTED;
  if(!same)return EFI_NOT_READY;
  if(Save)memcpy(InitialConfig,config,sizeof(config));
  Gu.pm_cap=caps.pm;Gu.pcie_cap=caps.pcie;Gu.pcie_version=caps.pcie_version;Gu.msi_cap=caps.msi;Gu.msix_cap=caps.msix;
  return EFI_SUCCESS;
}
static EFI_STATUS RestoreDecode(VOID) {
  UINT32 current[64],normalized[64],after[64];UINTN segment,bus,device,function;
  if(!Gu.pci || !Gu.owned || !Gu.armed || !Gu.display_ok || Gu.started || Gu.allocations ||
    Gu.dma_count || Gu.fault || Gu.retained)return EFI_ACCESS_DENIED;
  EFI_STATUS status=Gu.pci->GetLocation(Gu.pci,&segment,&bus,&device,&function);
  if(EFI_ERROR(status))return status;
  status=ReadConfig(current);if(EFI_ERROR(status))return status;
  GuLogText("config before decode restore (256 valid bytes):\n");ConfigLog(current);
  if(!GuTargetConfig(current,segment,bus,device,function))return EFI_UNSUPPORTED;
  UINT32 missing=InitialConfig[1]&~current[1]&3U;
  memcpy(normalized,current,sizeof(normalized));normalized[1]|=missing;
  /* Restore only cleared, previously enabled IO/MEM bits. Every other bit,
     including BME, status, BAR, ROM and PM/capability state must be unchanged. */
  if(memcmp(normalized,InitialConfig,sizeof(normalized))) {
    GuLogText("decode restore refused: config differs beyond cleared original IO/MEM bits\n");
    return EFI_UNSUPPORTED;
  }
  if(!missing){GuLogText("decode restore not needed\n");return EFI_SUCCESS;}
  if(!Gu.pci->Attributes)return EFI_UNSUPPORTED;
  UINT64 needed=(missing&1?EFI_PCI_IO_ATTRIBUTE_IO:0)|(missing&2?EFI_PCI_IO_ATTRIBUTE_MEMORY:0);
  UINT64 supported=0,attributes=0;
  status=Gu.pci->Attributes(Gu.pci,EfiPciIoAttributeOperationSupported,0,&supported);
  GuLog("decode supported attributes: status=%#llx mask=%#llx\n",(unsigned long long)status,(unsigned long long)supported);
  if(EFI_ERROR(status))return status;
  if((supported&needed)!=needed)return EFI_UNSUPPORTED;
  status=Gu.pci->Attributes(Gu.pci,EfiPciIoAttributeOperationGet,0,&attributes);
  GuLog("decode current attributes: status=%#llx mask=%#llx\n",(unsigned long long)status,(unsigned long long)attributes);
  if(EFI_ERROR(status))return status;
  GuLog("decode restore intent: saved_command=%#x current_command=%#x missing=%#x attributes=%#llx\n",
    InitialConfig[1]&0xffff,current[1]&0xffff,missing,(unsigned long long)needed);
  if(!GuLogReady() || Gu.fault)return EFI_DEVICE_ERROR;
  /* Never use EFI_PCI_DEVICE_ENABLE: it would also enable bus mastering. */
  EFI_STATUS enabled=Gu.pci->Attributes(Gu.pci,EfiPciIoAttributeOperationEnable,needed,NULL);
  GuLog("decode enable status=%#llx\n",(unsigned long long)enabled);
  if(!GuLogReady() || Gu.fault)return EFI_ERROR(enabled)?enabled:EFI_DEVICE_ERROR;
  /* Even an error may follow a partial hardware effect. Capture it if readable,
     but never turn an API error into success merely because readback matches. */
  status=ReadConfig(after);
  BOOLEAN matched=FALSE;
  if(!EFI_ERROR(status)) {
    GuLogText("config after decode restore (256 valid bytes):\n");ConfigLog(after);
    matched=!memcmp(after,InitialConfig,sizeof(after));GuLog("decode readback matched=%u\n",matched);
  }
  if(EFI_ERROR(enabled))return enabled;
  if(EFI_ERROR(status))return status;
  if(!GuLogReady() || Gu.fault)return EFI_DEVICE_ERROR;
  return matched?EFI_SUCCESS:EFI_COMPROMISED_DATA;
}
static EFI_STATUS FindTarget(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0,found=0;
  EFI_STATUS status=Gu.bs->LocateHandleBuffer(ByProtocol,&PciGuid,NULL,&count,&handles);
  GuLog("PCI enumeration: status=%#llx handles=%zu\n",(unsigned long long)status,(size_t)count);
  if(EFI_ERROR(status) || !handles || !count || count>256){if(handles)GuFree(handles);return EFI_NOT_FOUND;}
  for(UINTN i=0;i<count;i++) {
    EFI_PCI_IO_PROTOCOL *pci=NULL;UINT32 id=0;
    status=Gu.bs->HandleProtocol(handles[i],&PciGuid,(VOID **)&pci);
    if(!EFI_ERROR(status) && pci)status=pci->Pci.Read(pci,EfiPciIoWidthUint32,0,1,&id);
    if(EFI_ERROR(status) || !pci){GuLog("PCI scan failed: index=%zu status=%#llx\n",(size_t)i,(unsigned long long)status);status=EFI_DEVICE_ERROR;break;}
    if(id==GU_BOARD_ID){found++;Gu.handle=handles[i];Gu.pci=pci;}
  }
  GuFree(handles);GuLog("PCI target matches=%zu status=%#llx\n",(size_t)found,(unsigned long long)status);
  if(EFI_ERROR(status) || found!=1)return EFI_UNSUPPORTED;
  return ConfigCheck(TRUE);
}
static EFI_STATUS BarCheck(VOID) {
  EFI_ACPI_ADDRESS_SPACE_DESCRIPTOR *r=NULL;
  EFI_STATUS status=Gu.pci->GetBarAttributes(Gu.pci,0,NULL,(VOID **)&r);
  GuLog("bar0 query: status=%#llx\n",(unsigned long long)status);
  if(!EFI_ERROR(status)) {
    if(r && r->Desc==ACPI_ADDRESS_SPACE_DESCRIPTOR && r->Len==sizeof(*r)-3)
      GuLog("bar0 descriptor: type=%u granularity=%llu min=%#llx max=%#llx length=%#llx translation=%#llx\n",
        (unsigned)r->ResType,(unsigned long long)r->AddrSpaceGranularity,(unsigned long long)r->AddrRangeMin,
        (unsigned long long)r->AddrRangeMax,(unsigned long long)r->AddrLen,(unsigned long long)r->AddrTranslationOffset);
    if(!r || r->Desc!=ACPI_ADDRESS_SPACE_DESCRIPTOR || r->Len!=sizeof(*r)-3 || r->ResType!=0 ||
      r->AddrRangeMin!=GU_BAR_BASE || r->AddrLen!=GU_BAR_SIZE || r->AddrTranslationOffset ||
      /* UEFI describes an inclusive end; pinned EDK2 PciBusDxe instead returns
         PciBar.Alignment. Both representations describe this exact 16 MiB BAR. */
      (r->AddrRangeMax!=GU_BAR_BASE+GU_BAR_SIZE-1 && r->AddrRangeMax!=GU_BAR_SIZE-1) ||
      r->AddrSpaceGranularity!=GU_BAR_GRANULARITY || ((UINT8 *)(r+1))[0]!=ACPI_END_TAG_DESCRIPTOR)status=EFI_UNSUPPORTED;
    else {
      UINT8 *raw=(UINT8 *)r,sum=0;
      for(UINTN i=0;i<sizeof(*r)+2;i++)sum=(UINT8)(sum+raw[i]);
      if(raw[sizeof(*r)+1] && sum)status=EFI_COMPROMISED_DATA;
      else {Gu.bar_base=r->AddrRangeMin;Gu.bar_size=r->AddrLen;}
    }
  }
  if(r)GuFree(r);return status;
}
static EFI_STATUS ColdCheck(VOID) {
  UINT32 chip=GuRead32(0);GuLog("chip: actual=%#x expected=%#x\n",chip,GU_BOARD_CHIP);
  if(chip!=GU_BOARD_CHIP)return EFI_UNSUPPORTED;
  struct gpu_unlock_gfw_sample s={.config_ok=true,.plm=GuRead32(GU_GFW_PLM_OFFSET),
    .boot=GuRead32(GU_GFW_BOOT_OFFSET),.cpuctl=GuRead32(GU_GFW_CPUCTL_OFFSET)};
  UINT32 hi=GuRead32(0x1fa828),plm=GuRead32(GU_FEAT_PLM_OFFSET),ss0=GuRead32(GU_FEAT_SS0_OFFSET),ss1=GuRead32(GU_FEAT_SS1_OFFSET);
  GuLog("cold state: chip=%#x plm=%#x gfw=%#x/%#x/%#x WPR2_HI=%#x SS0=%#x SS1=%#x\n",
    GU_BOARD_CHIP,plm,s.plm,s.boot,s.cpuctl,hi,ss0,ss1);
  UINT32 wpr_cfg=GuRead32(0x1fa7cc),fbpa=GuRead32(0x9a0148),wpr=GuRead32(0x1fa7c4);
  GuLog("cold PLMs: WPR_CFG=%#x FBPA=%#x WPR=%#x FEAT=%#x\n",wpr_cfg,fbpa,wpr,plm);
  /* Diagnostic reads requested for RUN07 follow-up. The meaning/bit map of
     0x823b00 is unverified on AD103: do not decode it or write it.
     0x8403c4 is the reset-PLM candidate at the standard Falcon +0x3c4.
     Neither raw value is a new execution gate. Transport faults still latch. */
  UINT32 source_raw=GuRead32(0x823b00),reset_plm=GuRead32(0x8403c4);
  GuLog("cold diagnostic: reg=0x823b00 name=SOURCE_ENABLE_CANDIDATE_RAW value=%#x decoded=0\n",source_raw);
  GuLog("cold diagnostic: reg=0x8403c4 name=RESET_PLM_CANDIDATE_RAW value=%#x decoded=0\n",reset_plm);
  UINT32 vram=GuRead32(0x1183a4);
  /* RUN02 observed 32760 MiB on this pinned board/ROM. Do not round the
     value up: the transaction independently uses the actual FB size. */
  GuLog("VRAM register=%#x (%u MiB); must match board profile; layout uses actual register\n",vram,vram);
  if(Gu.fault || gpu_unlock_gfw_assess(&s) || hi>>4 || plm!=0xffffff8f ||
    /* Local change: SS1's low bits (override disabled) vary between boots, so only
       GuColdSelectors' bit-3-clear / <=7 rule applies, not the probe-time value. */
    !GuColdSelectors(ss0,ss1) || (vram!=GU_VRAM_MIB))return EFI_NOT_READY;
  return Gu.fault?EFI_DEVICE_ERROR:EFI_SUCCESS;
}
static VOID LogHash(const char *Name,const VOID *Data,UINTN Bytes) {
  static const char digits[]="0123456789abcdef";
  UINT8 digest[32];char hex[65];GuSha256(Data,Bytes,digest);
  for(UINTN i=0;i<32;i++){hex[2*i]=digits[digest[i]>>4];hex[2*i+1]=digits[digest[i]&15];}
  hex[64]=0;GuLog("%s bytes=%zu SHA256=%s\n",Name,(size_t)Bytes,hex);
}
static EFI_STATUS PromCheck(VOID) {
  if(!Gu.pci->RomImage || Gu.pci->RomSize!=GU_ROM_BYTES ||
     !GuHashMatches(Gu.pci->RomImage,GU_ROM_BYTES,GU_ROM_SHA256))return EFI_CRC_ERROR;
  VOID *prom=GuAlloc(1048576);if(!prom)return EFI_OUT_OF_RESOURCES;
  GuCopyFromIo(prom,(VOID *)(UINTN)(Gu.bar_base+GU_PROM_BAR_OFFSET),1048576);
  BOOLEAN good=!Gu.fault && GuHashMatches(prom,GU_PROM_VIEW_BYTES,GU_PROM_VIEW_SHA256);
  GuLog("PCI RomImage hash matched=1; PROM read width=32 io_fault=%u\n",(unsigned)Gu.fault);
  LogHash("live PROM",prom,1048576);
  LogHash("PROM verified view",prom,GU_PROM_VIEW_BYTES);
  GuLog("live PROM view hash matched=%u bar_offset=%#x bytes=%#x expected=%s\n",
    (unsigned)good,GU_PROM_BAR_OFFSET,GU_PROM_VIEW_BYTES,GU_PROM_VIEW_SHA256);
  if(!good) {
    UINT32 *p=prom;
    GuLog("PROM prefix: %08x %08x %08x %08x %08x %08x %08x %08x\n",p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7]);
    EFI_STATUS saved=GuSavePromDump(prom,1048576);
    GuLog("PROM.BIN save status=%#llx bytes=1048576 complete_read=%u; mismatch remains blocking\n",
      (unsigned long long)saved,(unsigned)!Gu.fault);
  }
  GuFree(prom);return good?EFI_SUCCESS:Gu.fault?EFI_DEVICE_ERROR:EFI_CRC_ERROR;
}
#ifdef GU_GENERIC
GU_PROFILE GuProfile;
static UINTN Fmt(char *Buffer,UINTN Size,const char *Format,...) {
  va_list args;va_start(args,Format);size_t n=GuFormatV(Buffer,Size,Format,args);va_end(args);
  return n>=Size?0:(UINTN)n;
}
static BOOLEAN StrEq(const char *A,const char *B) {while(*A && *A==*B){A++;B++;}return *A==*B;}
static BOOLEAN ParseNumber(const char *S,UINT32 *Out) {
  UINT64 v=0;UINTN digits=0;UINT32 base=10;
  if(S[0]=='0' && (S[1]=='x' || S[1]=='X')){base=16;S+=2;}
  for(;*S;S++) {
    UINT32 d;
    if(*S>='0' && *S<='9')d=(UINT32)(*S-'0');
    else if(base==16 && *S>='a' && *S<='f')d=(UINT32)(*S-'a'+10);
    else if(base==16 && *S>='A' && *S<='F')d=(UINT32)(*S-'A'+10);
    else return FALSE;
    v=v*base+d;if(v>0xffffffffULL)return FALSE;digits++;
  }
  *Out=(UINT32)v;return digits>0;
}
static BOOLEAN ParseSha(const char *S,char Out[65]) {
  UINTN n=0;
  for(;S[n];n++) {
    if(n>=64 || !((S[n]>='0' && S[n]<='9') || (S[n]>='a' && S[n]<='f')))return FALSE;
  }
  if(n!=64)return FALSE;
  for(UINTN i=0;i<64;i++)Out[i]=S[i];
  Out[64]=0;return TRUE;
}
typedef EFI_STATUS (*PairFn)(const char *Key,const char *Value,VOID *Context);
/* Strict "key=value" lines; '#' starts a comment line. Any malformed line is an error. */
static EFI_STATUS ForEachPair(char *Text,PairFn Fn,VOID *Context) {
  char *line=Text;
  while(*line) {
    char *end=line;while(*end && *end!='\n')end++;
    char *next=*end?end+1:end;*end=0;
    char *a=line;while(*a==' ' || *a=='\t')a++;
    char *b=a;while(*b)b++;
    while(b>a && (b[-1]=='\r' || b[-1]==' ' || b[-1]=='\t')){b--;*b=0;}
    if(*a && *a!='#') {
      char *eq=a;while(*eq && *eq!='=')eq++;
      if(*eq!='=')return EFI_COMPROMISED_DATA;
      *eq=0;
      char *ke=eq;while(ke>a && (ke[-1]==' ' || ke[-1]=='\t')){ke--;*ke=0;}
      char *v=eq+1;while(*v==' ' || *v=='\t')v++;
      EFI_STATUS s=Fn(a,v,Context);if(EFI_ERROR(s))return s;
    }
    line=next;
  }
  return EFI_SUCCESS;
}
/* Cards this program accepts. chipset is BOOT0 bits 28:20 (AD102 0x192, AD103 0x193, AD104 0x194); the full BOOT0 value is
 * recorded at enrollment and must read back identically on every later boot. vram_* bound the VRAM register (MiB).
 * Only the RTX 4090 is validated on hardware by this project (verified). The others follow the upstream evidence and
 * stay in the trial flow: nothing is written to the card until the user arms one trial and it succeeds. */
typedef struct {UINT16 device;UINT16 chipset;const char *name;UINT32 vram_min,vram_max;BOOLEAN verified;} GU_CHIP;
static const GU_CHIP Chips[]={
  {0x2684,0x192,"GeForce RTX 4090",24512,24576,TRUE},
  {0x2704,0x193,"GeForce RTX 4080",16256,16384,FALSE},
  {0x2702,0x193,"GeForce RTX 4080 SUPER",16256,16384,FALSE},
  {0x2705,0x193,"GeForce RTX 4070 Ti SUPER",16256,16384,FALSE},
  {0x2689,0x192,"GeForce RTX 4070 Ti SUPER (AD102)",16256,16384,FALSE},
  {0x2782,0x194,"GeForce RTX 4070 Ti",12160,12288,FALSE},
  {0x2783,0x194,"GeForce RTX 4070 SUPER",12160,12288,FALSE},
  {0x2786,0x194,"GeForce RTX 4070",12160,12288,FALSE}
};
static const GU_CHIP *ChipForId(UINT32 Id) {
  if((Id&0xffffU)!=0x10deU)return NULL;
  for(UINTN i=0;i<sizeof(Chips)/sizeof(Chips[0]);i++)if(Chips[i].device==(UINT16)(Id>>16))return &Chips[i];
  return NULL;
}
/* Profile keys. Version 1 (RTX 4090 only) has the first 13; version 2 adds pci_id and chip. trial_required is optional. */
typedef struct {UINT32 seen,version;GU_PROFILE p;} PROFILE_CTX;
static EFI_STATUS ProfilePair(const char *K,const char *V,VOID *C) {
  PROFILE_CTX *x=C;
  static const char *const names[16]={"version","segment","bus","device","function","subsystem","class_revision",
    "bar0","bar_granularity","vram_mib","rom_bytes","rom_sha256","prom_sha256","pci_id","chip","trial_required"};
  UINT32 *dst[16]={&x->version,&x->p.segment,&x->p.bus,&x->p.device,&x->p.function,&x->p.subsystem,
    &x->p.class_revision,&x->p.bar0,&x->p.bar_granularity,&x->p.vram_mib,&x->p.rom_bytes,NULL,NULL,
    &x->p.board_id,&x->p.chip,&x->p.trial_required};
  for(UINTN i=0;i<16;i++) {
    if(!StrEq(K,names[i]))continue;
    if(x->seen&(1U<<i))return EFI_COMPROMISED_DATA;
    BOOLEAN ok=dst[i]?ParseNumber(V,dst[i]):ParseSha(V,i==11?x->p.rom_sha256:x->p.prom_sha256);
    if(!ok)return EFI_COMPROMISED_DATA;
    x->seen|=1U<<i;return EFI_SUCCESS;
  }
  return EFI_COMPROMISED_DATA;
}
/* Same plausibility rules the enrollment applies; a hand-edited or damaged file is rejected. */
static BOOLEAN ProfileValid(PROFILE_CTX *x) {
  GU_PROFILE *p=&x->p;
  UINT32 need=0x1fffU;
  if(x->version==2)need|=(1U<<13)|(1U<<14);
  else if(x->version==1) {
    if(x->seen&((1U<<13)|(1U<<14)))return FALSE;
    p->board_id=0x268410deU;p->chip=0x192000a1U;   /* version 1 files only ever described an RTX 4090 */
  } else return FALSE;
  if((x->seen&need)!=need || (x->seen&~(need|(1U<<15))))return FALSE;
  const GU_CHIP *c=ChipForId(p->board_id);
  if(!c || ((p->chip>>20)&0x1ffU)!=c->chipset || p->trial_required>1)return FALSE;
  if(!(p->segment<=0xffff && p->bus<=255 && p->device<=31 && p->function<=7 &&
    p->subsystem!=0 && p->subsystem!=0xffffffffU && (p->class_revision>>24)==3 &&
    p->bar0!=0 && !(p->bar0&0xffffffU) && (p->bar_granularity==32 || p->bar_granularity==64) &&
    p->vram_mib>=c->vram_min && p->vram_mib<=c->vram_max && p->rom_bytes>0 && p->rom_bytes<=16U*1048576U))return FALSE;
  p->experimental=(!c->verified || p->trial_required)?1U:0U;
  p->name=c->name;
  return TRUE;
}
static EFI_STATUS LoadProfile(VOID) {
  char buffer[2048];UINTN length=0;PROFILE_CTX ctx;
  memset(&ctx,0,sizeof(ctx));
  EFI_STATUS status=GuReadParentFile(L"PROFILE.TXT",buffer,sizeof(buffer),&length);
  if(EFI_ERROR(status))return status;
  status=ForEachPair(buffer,ProfilePair,&ctx);
  if(EFI_ERROR(status) || !ProfileValid(&ctx)){GuLogText("profile: PROFILE.TXT is malformed or implausible; delete it to enroll again\n");return EFI_COMPROMISED_DATA;}
  GuProfile=ctx.p;
  GuLog("profile: card=%s id=%#x chip=%#x tier=%s\n",GuProfile.name,GuProfile.board_id,GuProfile.chip,
    GuProfile.experimental?"experimental (trial flow)":"verified");
  GuLog("profile: bdf=%u:%u:%u.%u subsystem=%#x class_rev=%#x bar0=%#x vram=%u MiB rom_bytes=%u\n",
    GuProfile.segment,GuProfile.bus,GuProfile.device,GuProfile.function,GuProfile.subsystem,
    GuProfile.class_revision,GuProfile.bar0,GuProfile.vram_mib,GuProfile.rom_bytes);
  return EFI_SUCCESS;
}
static VOID Hex(const UINT8 Digest[32],char Out[65]) {
  static const char digits[]="0123456789abcdef";
  for(UINTN i=0;i<32;i++){Out[2*i]=digits[Digest[i]>>4];Out[2*i+1]=digits[Digest[i]&15];}
  Out[64]=0;
}
/* Enrollment boot: ONLY reads the card (config space, BAR0 registers, option ROM, PROM view) and writes
 * \GPU-UNLOCK\PROFILE.TXT on the program's own partition. No GPU write, no DMA, no driver release. */
static EFI_STATUS Enroll(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0,matches=0;UINT32 found_id=0;
  EFI_STATUS status=Gu.bs->LocateHandleBuffer(ByProtocol,&PciGuid,NULL,&count,&handles);
  if(!EFI_ERROR(status) && (!handles || !count || count>256))status=EFI_COMPROMISED_DATA;
  for(UINTN i=0;!EFI_ERROR(status) && i<count;i++) {
    EFI_PCI_IO_PROTOCOL *pci=NULL;UINT32 id=0;
    status=Gu.bs->HandleProtocol(handles[i],&PciGuid,(VOID **)&pci);
    if(!EFI_ERROR(status) && pci)status=pci->Pci.Read(pci,EfiPciIoWidthUint32,0,1,&id);
    else if(!EFI_ERROR(status))status=EFI_COMPROMISED_DATA;
    if(!EFI_ERROR(status) && ChipForId(id)){matches++;Gu.pci=pci;Gu.handle=handles[i];found_id=id;}
  }
  GuFree(handles);
  if(EFI_ERROR(status))return status;
  if(matches!=1){GuLog("enroll: need exactly one supported card (RTX 4090, 4080, 4080 SUPER, 4070 Ti SUPER, 4070 Ti, 4070 SUPER, 4070), found %zu\n",(size_t)matches);return EFI_UNSUPPORTED;}
  const GU_CHIP *chipinfo=ChipForId(found_id);
  GuLog("enroll: card=%s id=%#x tier=%s\n",chipinfo->name,found_id,chipinfo->verified?"verified":"experimental");
  UINT32 config[64];UINTN segment,bus,device,function;
  status=Gu.pci->GetLocation(Gu.pci,&segment,&bus,&device,&function);if(EFI_ERROR(status))return status;
  status=ReadConfig(config);if(EFI_ERROR(status))return status;
  if(config[0]!=found_id || (config[2]>>24)!=3 || (config[1]&6)!=2 || (config[3]&0x7f0000U) || (config[12]&1)) {
    GuLog("enroll: PCI state not suitable: id=%#x class=%#x command=%#x header=%#x rombar=%#x\n",config[0],config[2],config[1],config[3],config[12]);
    return EFI_UNSUPPORTED;
  }
  if(config[11]==0 || config[11]==0xffffffffU){GuLog("enroll: implausible PCI subsystem id %#x; not enrolling\n",config[11]);return EFI_UNSUPPORTED;}
  if((config[4]&0xfU) || !config[4] || (config[4]&0xffffffU)){GuLog("enroll: BAR0 is not a 16 MiB aligned 32-bit memory BAR (%#x)\n",config[4]);return EFI_UNSUPPORTED;}
  EFI_ACPI_ADDRESS_SPACE_DESCRIPTOR *bar=NULL;
  status=Gu.pci->GetBarAttributes(Gu.pci,0,NULL,(VOID **)&bar);
  if(EFI_ERROR(status))return status;
  if(!bar || bar->Desc!=ACPI_ADDRESS_SPACE_DESCRIPTOR || bar->Len!=sizeof(*bar)-3 || bar->ResType || bar->AddrTranslationOffset ||
     bar->AddrLen!=GU_BAR_SIZE || bar->AddrRangeMin!=config[4] || (bar->AddrSpaceGranularity!=32 && bar->AddrSpaceGranularity!=64)) {
    GuLogText("enroll: BAR0 descriptor does not match the expected 16 MiB window\n");GuFree(bar);return EFI_UNSUPPORTED;
  }
  UINT32 granularity=(UINT32)bar->AddrSpaceGranularity;
  Gu.bar_base=bar->AddrRangeMin;Gu.bar_size=bar->AddrLen;GuFree(bar);
  UINT32 chip=GuRead32(0),vram=GuRead32(0x1183a4),wpr2=GuRead32(0x1fa828),ss0=GuRead32(GU_FEAT_SS0_OFFSET),ss1=GuRead32(0x823820),plm=GuRead32(GU_FEAT_PLM_OFFSET);
  GuLog("enroll: chip=%#x vram=%u MiB wpr2_hi=%#x ss0=%#x ss1=%#x plm=%#x\n",chip,vram,wpr2,ss0,ss1,plm);
  if(Gu.fault || ((chip>>20)&0x1ffU)!=chipinfo->chipset){GuLog("enroll: chip id %#x does not match the %s (expected chipset %#x)\n",chip,chipinfo->name,chipinfo->chipset);return EFI_UNSUPPORTED;}
  if((wpr2>>4) || plm!=0xffffff8fU || !GuColdSelectors(ss0,ss1) || vram<chipinfo->vram_min || vram>chipinfo->vram_max) {
    GuLog("enroll: the card is not in the expected cold, locked state with %u-%u MiB of memory; not enrolling\n",chipinfo->vram_min,chipinfo->vram_max);return EFI_NOT_READY;
  }
  if(!Gu.pci->RomImage || !Gu.pci->RomSize || Gu.pci->RomSize>16U*1048576U){GuLogText("enroll: no usable option ROM image\n");return EFI_UNSUPPORTED;}
  const UINT8 *rom=Gu.pci->RomImage;
  if(rom[0]!=0x55 || rom[1]!=0xaa){GuLogText("enroll: option ROM has no 55AA signature\n");return EFI_UNSUPPORTED;}
  UINT8 digest[32];char rom_hex[65],prom_hex[65];
  GuSha256(Gu.pci->RomImage,(UINTN)Gu.pci->RomSize,digest);Hex(digest,rom_hex);
  UINT8 *prom=GuAlloc(GU_PROM_VIEW_BYTES),*again=GuAlloc(GU_PROM_VIEW_BYTES);
  if(!prom || !again){GuFree(prom);GuFree(again);return EFI_OUT_OF_RESOURCES;}
  GuCopyFromIo(prom,(VOID *)(UINTN)(Gu.bar_base+GU_PROM_BAR_OFFSET),GU_PROM_VIEW_BYTES);
  GuCopyFromIo(again,(VOID *)(UINTN)(Gu.bar_base+GU_PROM_BAR_OFFSET),GU_PROM_VIEW_BYTES);
  BOOLEAN stable=!Gu.fault && prom[0]==0x55 && prom[1]==0xaa && !memcmp(prom,again,GU_PROM_VIEW_BYTES);
  GuSha256(prom,GU_PROM_VIEW_BYTES,digest);Hex(digest,prom_hex);
  GuFree(prom);GuFree(again);
  if(!stable){GuLogText("enroll: PROM view unreadable or not stable between two reads\n");return EFI_DEVICE_ERROR;}
  /* A new profile starts again from the read-only step: AUTO.TXT / ARMED.TXT left over from an earlier profile (deleted by hand, or
     a different card) must not carry over. Refuse to enroll if they cannot be removed. */
  {
    CHAR16 *stale[2]={L"AUTO.TXT",L"ARMED.TXT"};
    for(UINTN i=0;i<2;i++) {
      EFI_STATUS d=GuDeleteParentFile(stale[i]);
      if(d==EFI_SUCCESS)GuLog("enroll: removed a stale %s from an earlier profile\n",i?"ARMED.TXT":"AUTO.TXT");
      else if(d!=EFI_NOT_FOUND){GuLog("enroll: could not remove a stale %s (%#llx); not enrolling\n",i?"ARMED.TXT":"AUTO.TXT",(unsigned long long)d);return EFI_DEVICE_ERROR;}
    }
  }
  char text[1024];
  UINTN n=Fmt(text,sizeof(text),
    "# Written by the generic GPU unlock preboot program on its enrollment boot. Delete this file to enroll again.\n"
    "version=2\nsegment=%u\nbus=%u\ndevice=%u\nfunction=%u\nsubsystem=%#x\nclass_revision=%#x\nbar0=%#x\nbar_granularity=%u\n"
    "vram_mib=%u\nrom_bytes=%u\nrom_sha256=%s\nprom_sha256=%s\npci_id=%#x\nchip=%#x\n",
    (unsigned)segment,(unsigned)bus,(unsigned)device,(unsigned)function,config[11],config[2],config[4],(unsigned)granularity,
    (unsigned)vram,(unsigned)Gu.pci->RomSize,rom_hex,prom_hex,found_id,chip);
  if(!n)return EFI_BUFFER_TOO_SMALL;
  status=GuSaveParentBlob(L"PROFILE.TXT",text,n);
  GuLog("enroll: PROFILE.TXT save status=%#llx bytes=%zu\n",(unsigned long long)status,(size_t)n);
  if(EFI_ERROR(status))return status;
  status=LoadProfile();  /* read it back through the same strict parser the unlock path uses */
  return status;
}
#endif
static EFI_STATUS Arm(VOID) {
#ifdef GU_AUTO
  /* No countdown (fixed at zero): the unlock starts at once. To skip it for one start, pick "Windows Boot Manager"
     in the firmware boot menu; to stop it for good, turn the switch OFF in Windows. */
  GuLogText("AUTO MODE: no countdown; the unlock starts now.\n");
  return GuLogReady()?EFI_SUCCESS:EFI_DEVICE_ERROR;
#endif
  if(!Table->ConIn || !Table->ConIn->Reset || !Table->ConIn->ReadKeyStroke)return EFI_UNSUPPORTED;
  EFI_STATUS status=Table->ConIn->Reset(Table->ConIn,FALSE);if(EFI_ERROR(status))return status;
  GuLogText("READY: experimental preboot port / Windows preloaded.\n");
  if(PendingOwner.agent)GuLogText("U will release the RTX firmware driver, restore verified access settings if needed, then attempt WPR_CFG -> FBPA -> WPR -> FEAT in ONE SEC2 launch, then SS0/SS1 if required gates pass; log mismatches and recover.\n");
  GuLogText("Press U once. One SEC2 fire containing four ordered PLM writes, then selectors/FLR/Windows on full success. The last frame may remain visible. Power OFF on STOP. Esc/30s cancels.\n");
  if(!GuLogReady())return EFI_DEVICE_ERROR;
  for(UINTN i=0;i<300;i++) {
    EFI_INPUT_KEY key;status=Table->ConIn->ReadKeyStroke(Table->ConIn,&key);
    if(!EFI_ERROR(status)) {
      if(key.ScanCode==0x17 || key.UnicodeChar==27)return EFI_ABORTED;
      if(key.UnicodeChar=='u' || key.UnicodeChar=='U')return EFI_SUCCESS;
    } else if(status!=EFI_NOT_READY)return status;
    GuStall(100000);
  }
  return EFI_TIMEOUT;
}
static VOID PausePreflightFailure(VOID) {
  if(GuScreenDetached || Gu.started || !Table->ConIn || !Table->ConIn->ReadKeyStroke)return;
#ifdef GU_AUTO
  GuConsole("Preflight stopped before unlock; continuing to Windows without it. See the newest RUNxx/REPORT.TXT.\n");
  Gu.bs->Stall(3000000);
  return;
#endif
  if(Table->ConIn->Reset)Table->ConIn->Reset(Table->ConIn,FALSE);
  GuConsole("Preflight stopped before unlock. See the FINAL stage above and REPORT.TXT.\n");
  GuConsole("Press Enter or Esc to return to firmware; automatic return in 60 seconds. U cannot start an attempt here.\n");
  for(UINTN i=0;i<600;i++) {
    EFI_INPUT_KEY key;EFI_STATUS s=Table->ConIn->ReadKeyStroke(Table->ConIn,&key);
    if(!EFI_ERROR(s) && (key.ScanCode==0x17 || key.UnicodeChar==27 || key.UnicodeChar=='\r'))break;
    if(EFI_ERROR(s) && s!=EFI_NOT_READY)break;
    Gu.bs->Stall(100000);
  }
}
static VOID Halt(VOID) {
  Gu.retained=TRUE;
  GuLogText("STOP: cleanup cannot be proven. Resources remain reserved.\nPOWER OFF using the physical power button; do not continue to Windows.\n");
  /* No ResetSystem, ExitBootServices, retry, protocol close or memory release. */
  for(;;)Gu.bs->Stall(1000000);
}
static VOID LogContainment(VOID) {
  /* Called only after any TPL_NOTIFY containment section has ended. */
  GuLog("BME containment: attribute_status=%#llx hardware_status=%#llx command=%#x cached=%#llx pending=%u\n",
    (unsigned long long)Gu.master_attribute_status,(unsigned long long)Gu.master_hardware_status,
    Gu.master_last_command,(unsigned long long)Gu.master_last_attributes,Gu.master_attributes_pending);
}
static VOID ReleaseHalt(EFI_STATUS Status,BOOLEAN Attempted) {
  /* A failed claim may follow interface removal/replacement during logging.
     Resolve, validate and clear BME without a callback window or stale access. */
  EFI_TPL old=Gu.bs->RaiseTPL(TPL_NOTIFY);
  EFI_STATUS refreshed=GuRefreshTargetPci();
  EFI_STATUS contained=EFI_ERROR(refreshed)?refreshed:GuClearMaster();
  Gu.bs->RestoreTPL(old);
  LogContainment();
  GuLog("FINAL status=%#llx stage=%s attempted=%u driver_release=1 clean=0 containment=%#llx pci_available=%u\n",
    (unsigned long long)Status,Stage,Attempted,(unsigned long long)contained,(unsigned)(Gu.pci!=NULL));
  Halt();
}
EFI_STATUS EFIAPI EfiMain(EFI_HANDLE Image,EFI_SYSTEM_TABLE *St) {
  if(!St || !St->BootServices || !St->RuntimeServices)return EFI_INVALID_PARAMETER;
  WindowsImage=NULL;WindowsVolume=NULL;WindowsDevicePath=NULL;GuScreenDetached=FALSE;ExpectDetached=FALSE;
  Table=St;GuInit(St->BootServices,NULL);Gu.image=Image;Gu.display_check=DisplayCheck;
  memset(&PendingOwner,0,sizeof(PendingOwner));
  Stage="usb-log";EFI_STATUS status=GuIoOpen(Image,St);BOOLEAN attempted=FALSE,release_attempted=FALSE;
  if(EFI_ERROR(status))goto finish;
  UINT8 secure=0xff;
  Stage="secure-boot";
  status=GuReadSecureBoot(St->RuntimeServices,&secure);
  GuLog("SECURITY SecureBoot=%u status=%#llx firmware_policy_unchanged=1\n",
    (unsigned)secure,(unsigned long long)status);
  status=Step(status);if(EFI_ERROR(status))goto finish;
  Stage="watchdog";status=Step(Gu.bs->SetWatchdogTimer(0,0,0,NULL));if(EFI_ERROR(status))goto finish;
#ifdef GU_GENERIC
  Stage="profile";status=LoadProfile();
  if(status==EFI_NOT_FOUND) {
    GuLogText("ENROLLMENT: no PROFILE.TXT yet. First the card is only READ and its profile saved (no GPU write).\n");
    Stage="enroll";status=Step(Enroll());
    if(EFI_ERROR(status))goto finish;
    if(GuProfile.experimental) {
      /* Read-only first boot for every card outside the verified tier. The unlock waits for an explicit trial. */
      GuLog("ENROLLED: PROFILE.TXT written and read back (%s, experimental). No unlock in this boot: nothing was written to the card. "
        "Arm one trial from Windows to try it.\n",GuProfile.name);
      Stage="enrolled-experimental";status=EFI_ABORTED;goto finish;
    }
    GuLogText("ENROLLED: PROFILE.TXT written and read back. Continuing with the normal unlock checks in this same boot.\n");
  } else {
    status=Step(status);if(EFI_ERROR(status))goto finish;
  }
  if(GuProfile.experimental) {
    /* Trial flow: the card is only touched when the user armed ONE trial (ARMED.TXT, consumed here before anything else can
       go wrong, so a hang never repeats) or after a verified trial was confirmed (AUTO.TXT, written by the Windows installer). */
    Stage="trial-gate";
    BOOLEAN auto_on=GuParentFileExists(L"AUTO.TXT"),armed=GuParentFileExists(L"ARMED.TXT");
    GuLog("EXPERIMENTAL CARD: %s auto_confirmed=%u trial_armed=%u\n",GuProfile.name,(unsigned)auto_on,(unsigned)armed);
    if(!auto_on && !armed) {
      GuLogText("WAIT: no trial armed and auto-unlock not confirmed. Nothing is written to the card; starting Windows.\n");
      status=EFI_ABORTED;goto finish;
    }
    if(!auto_on) {
      status=GuDeleteParentFile(L"ARMED.TXT");
      GuLog("TRIAL RUN: ARMED.TXT consumed status=%#llx. One unlock attempt follows; if it fails nothing repeats.\n",(unsigned long long)status);
      if(EFI_ERROR(status))goto finish;
    } else GuLogText("AUTO: unlock confirmed by an earlier verified trial.\n");
  }
#endif
  Stage="target";status=Step(FindTarget());if(EFI_ERROR(status))goto finish;
  Stage="display";Gu.display_ok=DisplayCheck();status=Step(Gu.display_ok?EFI_SUCCESS:EFI_UNSUPPORTED);if(EFI_ERROR(status))goto finish;
  Stage="ownership";status=GuClaimController();
  if(status==EFI_ACCESS_DENIED) {
    status=GuFindReleaseOwner(St,&PendingOwner,TRUE);
    if(!EFI_ERROR(status))GuLogText("Exclusive ownership deferred until manual U and explicit driver release.\n");
  }
  if(!EFI_ERROR(status) && !PendingOwner.agent)status=EFI_UNSUPPORTED;
  status=Step(status);if(EFI_ERROR(status))goto finish;
  Stage="config-recheck";status=Step(ConfigCheck(FALSE));if(EFI_ERROR(status))goto finish;
  Stage="bar0";status=Step(BarCheck());if(EFI_ERROR(status))goto finish;
  Stage="cold-state";status=Step(ColdCheck());if(EFI_ERROR(status))goto finish;
  Stage="prom";status=Step(PromCheck());if(EFI_ERROR(status))goto finish;
  Stage="assets";status=Step(GuLoadAssets());if(EFI_ERROR(status))goto finish;
  Stage="windows-preload";status=Step(PreloadWindows());if(EFI_ERROR(status))goto finish;
  Stage="arming";status=Step(Arm());if(EFI_ERROR(status))goto finish;
  Stage="armed-config";status=Step(ConfigCheck(FALSE));if(EFI_ERROR(status))goto finish;
  Stage="armed-display";Gu.display_ok=DisplayCheck();status=Step(Gu.display_ok?EFI_SUCCESS:EFI_UNSUPPORTED);if(EFI_ERROR(status))goto finish;
  Stage="armed-cold-state";status=Step(ColdCheck());if(EFI_ERROR(status))goto finish;
  if(PendingOwner.agent) {
    GU_RELEASE_OWNER current;
    Stage="owner-recheck";
    GuLogText("Manual U confirmed: release RTX firmware driver once, then revalidate.\n");
    if(!GuLogReady()){status=EFI_DEVICE_ERROR;goto finish;}
    /* Durable intent precedes the last owner snapshot. No file IO between a
       successful final comparison and DisconnectController. */
    status=GuFindReleaseOwner(St,&current,FALSE);
    if(!EFI_ERROR(status) && !GuSameReleaseOwner(&PendingOwner,&current))status=EFI_ABORTED;
    if(EFI_ERROR(status)){status=Step(status);goto finish;}
    EFI_PCI_IO_PROTOCOL *prior=Gu.pci;
    Stage="driver-release";release_attempted=TRUE;Gu.armed=TRUE;Gu.pci=NULL;
    GuScreenDetached=TRUE;ExpectDetached=TRUE;
    EFI_STATUS released=Gu.bs->DisconnectController(Gu.handle,current.agent,NULL);
    EFI_TPL refresh_tpl=Gu.bs->RaiseTPL(TPL_NOTIFY);
    EFI_STATUS refreshed=GuRefreshTargetPci();
    Gu.bs->RestoreTPL(refresh_tpl);
    GuLog("driver release: status=%#llx refresh=%#llx same_pci=%u\n",
      (unsigned long long)released,(unsigned long long)refreshed,(unsigned)(Gu.pci==prior));
    status=Step(EFI_ERROR(released)?released:EFI_ERROR(refreshed)?refreshed:Gu.pci!=prior?EFI_COMPROMISED_DATA:EFI_SUCCESS);
    if(EFI_ERROR(status))goto finish;
    Stage="ownership-after-release";status=Step(GuClaimController());if(EFI_ERROR(status))goto finish;
    Stage="display-after-release";Gu.display_ok=DisplayCheck();status=Step(Gu.display_ok?EFI_SUCCESS:EFI_UNSUPPORTED);if(EFI_ERROR(status))goto finish;
    Stage="decode-after-release";status=Step(RestoreDecode());if(EFI_ERROR(status))goto finish;
    Stage="config-after-release";status=Step(ConfigCheck(FALSE));if(EFI_ERROR(status))goto finish;
    Stage="bar0-after-release";status=Step(BarCheck());if(EFI_ERROR(status))goto finish;
    Stage="cold-after-release";status=Step(ColdCheck());if(EFI_ERROR(status))goto finish;
    Stage="prom-after-release";status=Step(PromCheck());if(EFI_ERROR(status))goto finish;
  }
  GuLogText("ARMED: one transaction is starting. Do not reset or remove the USB.\n");
  if(!GuLogReady()){status=EFI_DEVICE_ERROR;goto finish;}
  Stage="transaction";Gu.armed=TRUE;attempted=TRUE;
  UINT64 mask=0xffffffffULL;
  struct pci_dev device={.dev={.dma_mask=&mask,.coherent_dma_mask=0xffffffffULL},.pm_cap=Gu.pm_cap,.refs=1};
  struct gpu_unlock_610_shared shared={0};
  int result=gpu_unlock_610_load_shared(&device,&shared);
  if(!result)result=gpu_unlock_610_unlock(&device,&shared);
  /* Also covers failures before GuStarted, including BME-enable readback. */
  EFI_STATUS contained=GuClearMaster();
  LogContainment();
  GuLog("transaction result=%d containment=%#llx started=%u quiesced=%u fault=%u retained=%u maps=%u FLR=%u\n",
    result,(unsigned long long)contained,Gu.started,Gu.quiesced,Gu.fault,Gu.retained,Gu.dma_count,Gu.flrs);
  if(EFI_ERROR(contained) || !GuSafeToReturn() || Gu.allocations || (Gu.started && result))Halt();
  gpu_unlock_610_release_shared(&shared);Gu.armed=FALSE;
  status=result?EFI_DEVICE_ERROR:EFI_SUCCESS;
finish:
  if(!EFI_ERROR(status) && attempted && release_attempted) {
    Stage="post-unlock-handoff";status=RestoreDisplayForWindows(PendingOwner.agent);
  }
  if(release_attempted && (EFI_ERROR(status) || Gu.fault))ReleaseHalt(status,attempted);
  if(attempted && !GuSafeToReturn())Halt();
  if(GuLogReady())GuLog("FINAL status=%#llx stage=%s attempted=%u driver_release=%u clean=%u\n",(unsigned long long)status,Stage,attempted,release_attempted,GuSafeToReturn());
  else GuConsole("Preflight or logging failed; no new attempt will start.\n");
  if(!GuLogReady()){status=EFI_DEVICE_ERROR;if(release_attempted)ReleaseHalt(status,attempted);if(Gu.started)Halt();}
  if(attempted && !GuSafeToReturn())Halt();
  EFI_STATUS closed=GuIoClose();
  if(EFI_ERROR(closed)){if(release_attempted)ReleaseHalt(closed,attempted);if(Gu.started)Halt();status=closed;}
  if(Gu.owned) {
    closed=Gu.bs->CloseProtocol(Gu.handle,&PciGuid,Image,NULL);
    if(EFI_ERROR(closed)){if(release_attempted)ReleaseHalt(closed,attempted);if(Gu.started)Halt();status=closed;}else Gu.owned=FALSE;
  }
  GuReleaseAssets();
  if(!EFI_ERROR(status) && attempted) {
    GuConsole("GPU restored after FLR and GOP reconnect; selector outcome logged. Starting Windows.\n");
    UINTN bytes=0;CHAR16 *data=NULL;
    status=Gu.bs->StartImage(WindowsImage,&bytes,&data);
    if(data)GuFree(data);
    /* Returning after a hardware attempt could permit accidental rerun. */
    GuScreenDetached=TRUE;Halt();
  }
  else GuConsole("Attempt cancelled or rejected. Returning without another attempt.\n");
  if(WindowsImage)Gu.bs->UnloadImage(WindowsImage);
  GuFree(WindowsDevicePath);WindowsDevicePath=NULL;
  if(EFI_ERROR(status) && status!=EFI_ABORTED && status!=EFI_TIMEOUT && !release_attempted)PausePreflightFailure();
  return status;
}
