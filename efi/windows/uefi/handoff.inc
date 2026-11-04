/* Modified 2026-10-21: experimental AD103 32GB GA102-pair port; see PORT-NOTES.txt. */
/* Derived from the v0.3 handoff path exercised on this user's single AD103. */
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
static EFI_GUID FsGuid=EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID,LoadedGuid=EFI_LOADED_IMAGE_PROTOCOL_GUID;
static const CHAR16 WindowsPath[]=L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi";
static EFI_HANDLE WindowsImage,WindowsVolume;
static EFI_DEVICE_PATH_PROTOCOL *WindowsDevicePath;
static EFI_STATUS MakeWindowsPath(VOID) {
  EFI_DEVICE_PATH_PROTOCOL *base=NULL;
  EFI_STATUS s=Gu.bs->HandleProtocol(WindowsVolume,&PathGuid,(VOID**)&base);
  if(EFI_ERROR(s)||!base)return EFI_NOT_FOUND;
  UINTN off=0;BOOLEAN end=FALSE;
  for(UINTN i=0;i<128 && off<=4092;i++) {
    EFI_DEVICE_PATH_PROTOCOL *n=(VOID*)((UINT8*)base+off);
    UINTN len=n->Length[0]+((UINTN)n->Length[1]<<8);
    if(len<4||len>4096-off)return EFI_COMPROMISED_DATA;
    if(n->Type==END_DEVICE_PATH_TYPE) {
      if(n->SubType!=END_ENTIRE_DEVICE_PATH_SUBTYPE||len!=4)return EFI_UNSUPPORTED;
      end=TRUE;break;
    }
    off+=len;
  }
  if(!end)return EFI_COMPROMISED_DATA;
  UINTN node=4+sizeof(WindowsPath),total=off+node+4;
  UINT8 *b=GuAlloc(total);if(!b)return EFI_OUT_OF_RESOURCES;
  memcpy(b,base,off);b[off]=MEDIA_DEVICE_PATH;b[off+1]=MEDIA_FILEPATH_DP;
  b[off+2]=(UINT8)node;b[off+3]=(UINT8)(node>>8);memcpy(b+off+4,WindowsPath,sizeof(WindowsPath));
  b[off+node]=END_DEVICE_PATH_TYPE;b[off+node+1]=END_ENTIRE_DEVICE_PATH_SUBTYPE;b[off+node+2]=4;
  WindowsDevicePath=(VOID*)b;return EFI_SUCCESS;
}
static EFI_STATUS PreloadWindows(VOID) {
  EFI_HANDLE *h=NULL;UINTN n=0,found=0,skipped=0;
  EFI_STATUS s=Gu.bs->LocateHandleBuffer(ByProtocol,&FsGuid,NULL,&n,&h);
  if(EFI_ERROR(s))return s;
  if(!h||n>256){GuFree(h);return EFI_COMPROMISED_DATA;}
  for(UINTN i=0;i<n;i++) {
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs=NULL;EFI_FILE_PROTOCOL *root=NULL,*file=NULL;
    EFI_STATUS x=Gu.bs->HandleProtocol(h[i],&FsGuid,(VOID**)&fs);
    if(!EFI_ERROR(x)&&fs)x=fs->OpenVolume(fs,&root);
    /* A volume the firmware cannot open (an empty card reader, an unreadable file system) cannot hold a boot manager that
       LoadImage could start, and the Windows that runs on this PC boots from a volume the firmware can read. Such a volume is
       skipped and logged instead of ending the search; every volume that is readable is still checked as before. */
    if(EFI_ERROR(x)||!root) {
      GuLog("Windows volume %zu of %zu: handle=%#llx open_volume=%#llx; skipped\n",(size_t)(i+1),(size_t)n,(unsigned long long)(UINTN)h[i],(unsigned long long)x);
      skipped++;continue;
    }
    x=root->Open(root,&file,(CHAR16*)WindowsPath,EFI_FILE_MODE_READ,0);
    if(!EFI_ERROR(x)&&file) {
      UINT8 mz[2];UINTN bytes=2;EFI_STATUS y=file->Read(file,&bytes,mz);
      EFI_STATUS closed=file->Close(file);
      if(EFI_ERROR(y)||EFI_ERROR(closed)||bytes!=2||mz[0]!='M'||mz[1]!='Z')s=EFI_COMPROMISED_DATA;
      else {
        found++;WindowsVolume=h[i];
        GuLog("Windows volume %zu of %zu: handle=%#llx has the boot manager\n",(size_t)(i+1),(size_t)n,(unsigned long long)(UINTN)h[i]);
      }
    } else if(x!=EFI_NOT_FOUND) {
      GuLog("Windows volume %zu of %zu: handle=%#llx open_boot_manager=%#llx; skipped\n",(size_t)(i+1),(size_t)n,(unsigned long long)(UINTN)h[i],(unsigned long long)x);
      skipped++;
    }
    x=root->Close(root);if(EFI_ERROR(x))s=x;
    if(EFI_ERROR(s))break;
  }
  GuFree(h);GuLog("Windows candidates=%zu status=%#llx skipped_volumes=%zu\n",(size_t)found,(unsigned long long)s,(size_t)skipped);
  if(EFI_ERROR(s))return s;
  if(found>1)GuLogText("More than one volume has \\EFI\\Microsoft\\Boot\\bootmgfw.efi, so the program cannot tell which Windows to start. Unplug or remove the extra boot partition for the unlock.\n");
  if(found!=1)return found?EFI_NO_MAPPING:EFI_NOT_FOUND;
  s=MakeWindowsPath();if(EFI_ERROR(s))return s;
  s=Gu.bs->LoadImage(FALSE,Gu.image,WindowsDevicePath,NULL,0,&WindowsImage);
  GuLog("Windows LoadImage=%#llx\n",(unsigned long long)s);
  if(EFI_ERROR(s))return s;
  EFI_LOADED_IMAGE_PROTOCOL *li=NULL;
  s=Gu.bs->HandleProtocol(WindowsImage,&LoadedGuid,(VOID**)&li);
  if(EFI_ERROR(s)||!li||li->DeviceHandle!=WindowsVolume||li->ImageCodeType!=EfiLoaderCode)return EFI_COMPROMISED_DATA;
  return GuLogReady()?EFI_SUCCESS:EFI_DEVICE_ERROR;
}
static EFI_STATUS VerifySelectors(const char *phase) {
  UINT32 ss0=GuRead32(0x82381c),ss1=GuRead32(0x823820);
  UINT32 readout=GuRead32(0x823818);
  GuLog("%s SS0=0x%08x SS1=0x%08x\n",phase,ss0,ss1);
  GuLog("%s unlock_matched=%u; handoff checks GPU accessibility separately\n",phase,ss0==0x88888888 && ss1==8);
  GuLog("%s register_unlock_verified=%u readout1=%#x windows_driver_verified=0\n",
    phase,ss0==0x88888888 && ss1==8 && !(readout&0x07ffffffU),readout);
  return !Gu.fault && GuLogReady() && ss0!=0xffffffff && ss1!=0xffffffff &&
    ss0!=0xbadf5620 && ss1!=0xbadf5620 && readout!=0xffffffff &&
    (readout&0xffff0000U)!=0xbadf0000U?EFI_SUCCESS:EFI_DEVICE_ERROR;
}
/* After the driver reconnect some platform GOP drivers re-create the card's GOP with an invalid current mode (Mode == MaxMode)
   and no framebuffer, and nothing sets a mode afterwards (RTX 4070 Ti, issue #1; RTX 4080 on an ASUS Z790 board, issue #9).
   DisplayCheck() skips such a handle, so the handoff could never pass. The size of the card's display is remembered before the
   driver release; if the reconnected GOP of the card has no framebuffer, a mode of that size (mode 0 if none matches) is set once.
   The pass criteria are unchanged: DisplayCheck() still has to find exactly one GOP with a valid framebuffer on the card. */
static UINT32 PriorGopWidth,PriorGopHeight;
static BOOLEAN TargetGop(EFI_HANDLE Handle,EFI_GRAPHICS_OUTPUT_PROTOCOL **Gop) {
  EFI_GRAPHICS_OUTPUT_PROTOCOL *g=NULL;EFI_DEVICE_PATH_PROTOCOL *path=NULL;EFI_HANDLE parent=NULL;
  if(EFI_ERROR(Gu.bs->HandleProtocol(Handle,&GopGuid,(VOID **)&g))||!g||!g->Mode)return FALSE;
  if(EFI_ERROR(Gu.bs->HandleProtocol(Handle,&PathGuid,(VOID **)&path))||!path)return FALSE;
  if(EFI_ERROR(Gu.bs->LocateDevicePath(&PciGuid,&path,&parent))||parent!=Gu.handle)return FALSE;
  *Gop=g;return TRUE;
}
/* Silent on purpose: it runs before the driver release, where no file IO may be added. */
static VOID RememberTargetGop(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0;
  if(EFI_ERROR(Gu.bs->LocateHandleBuffer(ByProtocol,&GopGuid,NULL,&count,&handles))||!handles||count>128){if(handles)GuFree(handles);return;}
  for(UINTN i=0;i<count;i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *g=NULL;
    if(!TargetGop(handles[i],&g)||!g->Mode->Info||g->Mode->SizeOfInfo<sizeof(*g->Mode->Info))continue;
    if(!g->Mode->FrameBufferBase||!g->Mode->FrameBufferSize)continue;
    PriorGopWidth=g->Mode->Info->HorizontalResolution;PriorGopHeight=g->Mode->Info->VerticalResolution;break;
  }
  GuFree(handles);
}
static VOID SetModeOnReconnectedGop(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0;
  if(EFI_ERROR(Gu.bs->LocateHandleBuffer(ByProtocol,&GopGuid,NULL,&count,&handles))||!handles||count>128){if(handles)GuFree(handles);return;}
  for(UINTN i=0;i<count;i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *g=NULL;UINT32 mode=0;
    if(!TargetGop(handles[i],&g)||g->Mode->FrameBufferBase||g->Mode->FrameBufferSize)continue;
    GuLog("GOP reconnect: the card's GOP has no framebuffer (mode %u of %u); prior display %ux%u\n",
      (unsigned)g->Mode->Mode,(unsigned)g->Mode->MaxMode,(unsigned)PriorGopWidth,(unsigned)PriorGopHeight);
    if(PriorGopWidth&&PriorGopHeight)for(UINT32 m=0;m<g->Mode->MaxMode&&m<256;m++) {
      EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info=NULL;UINTN size=0;BOOLEAN match=FALSE;
      if(EFI_ERROR(g->QueryMode(g,m,&size,&info))||!info)continue;
      match=size>=sizeof(*info)&&info->HorizontalResolution==PriorGopWidth&&info->VerticalResolution==PriorGopHeight&&
        info->PixelFormat<=PixelBlueGreenRedReserved8BitPerColor;
      Gu.bs->FreePool(info);
      if(match){mode=m;break;}
    }
    EFI_STATUS s=g->SetMode(g,mode);
    GuLog("GOP reconnect: SetMode(%u) status=%#llx fb_base=%#llx fb_size=%#llx\n",(unsigned)mode,(unsigned long long)s,
      (unsigned long long)(g->Mode?g->Mode->FrameBufferBase:0),(unsigned long long)(g->Mode?g->Mode->FrameBufferSize:0));
  }
  GuFree(handles);
}
static EFI_STATUS RestoreDisplayForWindows(EFI_HANDLE Driver) {
  if(!WindowsImage || !Driver || !GuScreenDetached || !GuSafeToReturn() || !Gu.quiesced ||
     Gu.flrs!=1 || Gu.allocations || Gu.dma_count || !Gu.owned || Gu.fault)return EFI_NOT_READY;
  EFI_STATUS s=VerifySelectors("POST-FLR");if(EFI_ERROR(s))return s;
  GuLogText("stage=before_GOP_reconnect; transaction quiesced, DMA released, PCI restored\n");
  if(!GuLogReady())return EFI_DEVICE_ERROR;
  s=Gu.bs->CloseProtocol(Gu.handle,&PciGuid,Gu.image,NULL);if(EFI_ERROR(s))return s;
  Gu.owned=FALSE;
  EFI_HANDLE drivers[2]={Driver,NULL};
  s=Gu.bs->ConnectController(Gu.handle,drivers,NULL,TRUE);
  GuLog("ConnectController status=%#llx\n",(unsigned long long)s);
  if(EFI_ERROR(s))return s;
  s=GuRefreshTargetPci();if(EFI_ERROR(s))return s;
  ExpectDetached=FALSE;
  BOOLEAN display=DisplayCheck();
  if(!display){SetModeOnReconnectedGop();display=DisplayCheck();}
  if(!display)return EFI_DEVICE_ERROR;
  UINT16 command=0;UINT32 value=0;
  s=GuConfigRead(EfiPciIoWidthUint16,4,&command);
  /* GOP may re-enable I/O decode (bit 0); all other command bits must match */
  if(EFI_ERROR(s)||(command&0xfffe)!=((UINT16)InitialConfig[1]&0xfffe)||(command&4))return EFI_DEVICE_ERROR;
  for(UINT32 offset=0x10;offset<=0x24;offset+=4) {
    s=GuConfigRead(EfiPciIoWidthUint32,offset,&value);
    if(EFI_ERROR(s)||value!=InitialConfig[offset/4])return EFI_DEVICE_ERROR;
  }
  s=VerifySelectors("POST-GOP");if(EFI_ERROR(s))return s;
  GuLogText("stage=before_StartImage; POST-GOP selectors and PCI BAR/command verified\n");
  if(!GuLogReady())return EFI_DEVICE_ERROR;
  GuScreenDetached=FALSE;
  return EFI_SUCCESS;
}
