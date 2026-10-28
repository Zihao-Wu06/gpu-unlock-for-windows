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
  EFI_HANDLE *h=NULL;UINTN n=0,found=0;
  EFI_STATUS s=Gu.bs->LocateHandleBuffer(ByProtocol,&FsGuid,NULL,&n,&h);
  if(EFI_ERROR(s))return s;
  if(!h||n>256){GuFree(h);return EFI_COMPROMISED_DATA;}
  for(UINTN i=0;i<n;i++) {
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs=NULL;EFI_FILE_PROTOCOL *root=NULL,*file=NULL;
    EFI_STATUS x=Gu.bs->HandleProtocol(h[i],&FsGuid,(VOID**)&fs);
    if(!EFI_ERROR(x)&&fs)x=fs->OpenVolume(fs,&root);
    if(EFI_ERROR(x)||!root){s=EFI_DEVICE_ERROR;break;}
    x=root->Open(root,&file,(CHAR16*)WindowsPath,EFI_FILE_MODE_READ,0);
    if(!EFI_ERROR(x)&&file) {
      UINT8 mz[2];UINTN bytes=2;EFI_STATUS y=file->Read(file,&bytes,mz);
      EFI_STATUS closed=file->Close(file);
      if(EFI_ERROR(y)||EFI_ERROR(closed)||bytes!=2||mz[0]!='M'||mz[1]!='Z')s=EFI_COMPROMISED_DATA;
      else {found++;WindowsVolume=h[i];}
    } else if(x!=EFI_NOT_FOUND)s=EFI_DEVICE_ERROR;
    x=root->Close(root);if(EFI_ERROR(x))s=x;
    if(EFI_ERROR(s))break;
  }
  GuFree(h);GuLog("Windows candidates=%zu status=%#llx\n",(size_t)found,(unsigned long long)s);
  if(EFI_ERROR(s))return s;
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
/* Local patch iteration 2 (RTX 4070 Ti handoff, 2026-10-28): RUN07 proved
   plain reconnect retries never produce a display on this board (20 attempts,
   ~10 s, GOP physical=0 throughout), and the stock log cannot distinguish
   "no GOP handle exists" from "a GOP handle exists but has no framebuffer
   set" (DisplayCheck skips framebuffer-less handles silently). The helpers
   below therefore (a) dump every GOP handle and the card's PCI ownership
   after the reconnect, and (b) inside the retry loop try the two standard
   firmware actions that complete a half-created GOP: SetMode(0) on a
   target GOP with no framebuffer, and connecting the GOP handles and the
   console-out handle the way the boot manager would. Diagnostics only log;
   the actions are ordinary boot-services calls. Pass criteria unchanged. */
static VOID DumpGopHandles(const char *tag) {
  EFI_HANDLE *handles=NULL;UINTN count=0;
  EFI_STATUS status=Gu.bs->LocateHandleBuffer(ByProtocol,&GopGuid,NULL,&count,&handles);
  GuLog("GOPDIAG %s: locate_status=%#llx handles=%zu\n",tag,(unsigned long long)status,(size_t)(EFI_ERROR(status)?0:count));
  if(EFI_ERROR(status)||!handles||count>128){if(handles)GuFree(handles);return;}
  for(UINTN i=0;i<count;i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *g=NULL;EFI_DEVICE_PATH_PROTOCOL *path=NULL;EFI_HANDLE parent=NULL;UINTN target=0;
    EFI_STATUS hs=Gu.bs->HandleProtocol(handles[i],&GopGuid,(VOID **)&g);
    if(EFI_ERROR(hs)||!g){GuLog("GOPDIAG %s: [%zu] handle=%#llx gop_status=%#llx\n",tag,(size_t)i,(unsigned long long)(UINTN)handles[i],(unsigned long long)hs);continue;}
    if(!EFI_ERROR(Gu.bs->HandleProtocol(handles[i],&PathGuid,(VOID **)&path))&&path) {
      EFI_DEVICE_PATH_PROTOCOL *rest=path;
      if(!EFI_ERROR(Gu.bs->LocateDevicePath(&PciGuid,&rest,&parent)))target=(parent==Gu.handle);
    }
    if(!g->Mode){GuLog("GOPDIAG %s: [%zu] handle=%#llx target=%zu mode=NULL\n",tag,(size_t)i,(unsigned long long)(UINTN)handles[i],(size_t)target);continue;}
    GuLog("GOPDIAG %s: [%zu] handle=%#llx target=%zu max_mode=%u mode=%u fb_base=%#llx fb_size=%#llx hres=%u vres=%u\n",
      tag,(size_t)i,(unsigned long long)(UINTN)handles[i],(size_t)target,(unsigned)g->Mode->MaxMode,(unsigned)g->Mode->Mode,
      (unsigned long long)g->Mode->FrameBufferBase,(unsigned long long)g->Mode->FrameBufferSize,
      g->Mode->Info?(unsigned)g->Mode->Info->HorizontalResolution:0U,
      g->Mode->Info?(unsigned)g->Mode->Info->VerticalResolution:0U);
  }
  GuFree(handles);
}
static VOID DumpCardOwner(EFI_HANDLE Driver,const char *tag) {
  EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *entries=NULL;UINTN count=0,bydriver=0;
  EFI_STATUS status=Gu.bs->OpenProtocolInformation(Gu.handle,&PciGuid,&entries,&count);
  if(EFI_ERROR(status)||(count&&!entries)){GuLog("GOPDIAG %s: owner_status=%#llx\n",tag,(unsigned long long)status);return;}
  for(UINTN i=0;i<count;i++)if(entries[i].AgentHandle==Driver&&(entries[i].Attributes&EFI_OPEN_PROTOCOL_BY_DRIVER))bydriver++;
  GuLog("GOPDIAG %s: pci_entries=%zu driver_bound_by_driver=%zu\n",tag,(size_t)count,(size_t)bydriver);
  if(entries)Gu.bs->FreePool(entries);
}
static VOID TrySetModeOnTarget(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0;
  if(EFI_ERROR(Gu.bs->LocateHandleBuffer(ByProtocol,&GopGuid,NULL,&count,&handles))||!handles||count>128){if(handles)GuFree(handles);return;}
  for(UINTN i=0;i<count;i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *g=NULL;EFI_DEVICE_PATH_PROTOCOL *path=NULL;EFI_HANDLE parent=NULL;
    if(EFI_ERROR(Gu.bs->HandleProtocol(handles[i],&GopGuid,(VOID **)&g))||!g||!g->Mode)continue;
    if(g->Mode->FrameBufferBase||g->Mode->FrameBufferSize)continue;
    if(EFI_ERROR(Gu.bs->HandleProtocol(handles[i],&PathGuid,(VOID **)&path))||!path)continue;
    EFI_DEVICE_PATH_PROTOCOL *rest=path;
    if(EFI_ERROR(Gu.bs->LocateDevicePath(&PciGuid,&rest,&parent))||parent!=Gu.handle)continue;
    EFI_STATUS s=g->SetMode(g,0);
    GuLog("GOPDIAG setmode0: handle=%#llx status=%#llx fb_base=%#llx fb_size=%#llx\n",(unsigned long long)(UINTN)handles[i],(unsigned long long)s,
      (unsigned long long)(g->Mode?g->Mode->FrameBufferBase:0),(unsigned long long)(g->Mode?g->Mode->FrameBufferSize:0));
  }
  GuFree(handles);
}
static VOID TryConnectGopAndConsole(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0;
  if(!EFI_ERROR(Gu.bs->LocateHandleBuffer(ByProtocol,&GopGuid,NULL,&count,&handles))&&handles&&count<=128) {
    for(UINTN i=0;i<count;i++)Gu.bs->ConnectController(handles[i],NULL,NULL,TRUE);
    GuLog("GOPDIAG connect: gop_handles=%zu connected\n",(size_t)count);
  }
  if(handles)GuFree(handles);
  if(Table&&Table->ConsoleOutHandle) {
    EFI_STATUS s=Gu.bs->ConnectController(Table->ConsoleOutHandle,NULL,NULL,TRUE);
    GuLog("GOPDIAG connect: console_out status=%#llx\n",(unsigned long long)s);
  }
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
  /* Local patch (RTX 4070 Ti handoff, 2026-10-28; iteration 2): on this
     board/firmware no usable GOP display exists at the first check after
     ConnectController (RUN05/RUN06 stock: gave up immediately; RUN07 with
     plain retries: 20 attempts over ~10 s, still none). The loop below
     keeps the bounded retry and adds the iteration-2 diagnostics/actions
     above at fixed attempts (2 = SetMode, 3 = console connect, 4 = dump
     again) so the log attributes any change. The pass criteria are
     unchanged: DisplayCheck() must still find exactly one physical GOP on
     the target, and the PCI command/BAR and POST-GOP selector checks below
     still run before Windows is started. If no display appears within the
     bound, this still returns EFI_DEVICE_ERROR exactly as stock. */
  BOOLEAN display=DisplayCheck();
  if(!display){DumpGopHandles("after-reconnect");DumpCardOwner(Driver,"after-reconnect");}
  for(UINTN attempt=1;!display && attempt<=20;attempt++) {
    GuLog("GOP reconnect retry: attempt=%zu of 20; waiting 500 ms, reconnecting\n",(size_t)attempt);
    Gu.bs->Stall(500000);
    Gu.bs->ConnectController(Gu.handle,drivers,NULL,TRUE);
    if(attempt==2)TrySetModeOnTarget();
    if(attempt==3)TryConnectGopAndConsole();
    if(attempt==4){DumpGopHandles("after-actions");DumpCardOwner(Driver,"after-actions");}
    display=DisplayCheck();
  }
  if(!display){DumpGopHandles("final");return EFI_DEVICE_ERROR;}
  UINT16 command=0;UINT32 value=0;
  s=GuConfigRead(EfiPciIoWidthUint16,4,&command);
  if(EFI_ERROR(s)||command!=(UINT16)InitialConfig[1]||(command&4))return EFI_DEVICE_ERROR;
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
