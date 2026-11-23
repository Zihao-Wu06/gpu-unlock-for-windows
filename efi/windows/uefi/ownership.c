#include "ownership.h"
#include "runtime.h"
#include <Protocol/LoadedImage.h>
#include <Protocol/GraphicsOutput.h>
#include "sha256.h"
static EFI_GUID PciGuid=EFI_PCI_IO_PROTOCOL_GUID,
  PathGuid=EFI_DEVICE_PATH_PROTOCOL_GUID,GopGuid=EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID,
  BindingGuid=EFI_DRIVER_BINDING_PROTOCOL_GUID,LoadedGuid=EFI_LOADED_IMAGE_PROTOCOL_GUID;
typedef struct {EFI_GUID protocol;EFI_OPEN_PROTOCOL_INFORMATION_ENTRY entry;} OWNER_RECORD;
#define MAX_RECORDS 32
static BOOLEAN Passive(UINT32 A) {
  return A==EFI_OPEN_PROTOCOL_BY_HANDLE_PROTOCOL || A==EFI_OPEN_PROTOCOL_GET_PROTOCOL || A==EFI_OPEN_PROTOCOL_TEST_PROTOCOL;
}
/* Caller holds TPL_NOTIFY through the snapshot and, for Claim, acquisition. */
static EFI_STATUS Snapshot(OWNER_RECORD *Records,UINTN *Count) {
  EFI_GUID **protocols=NULL;UINTN protocol_count=0;BOOLEAN pci=FALSE;*Count=0;
  if(!Gu.bs->ProtocolsPerHandle)return EFI_UNSUPPORTED;
  EFI_STATUS status=Gu.bs->ProtocolsPerHandle(Gu.handle,&protocols,&protocol_count);
  if(!EFI_ERROR(status) && (!protocols || !protocol_count || protocol_count>32))status=EFI_COMPROMISED_DATA;
  for(UINTN i=0;!EFI_ERROR(status) && i<protocol_count;i++) {
    EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *entries=NULL;UINTN count=0;
    if(!protocols[i]){status=EFI_COMPROMISED_DATA;break;}
    if(!memcmp(protocols[i],&PciGuid,sizeof(PciGuid)))pci=TRUE;
    status=Gu.bs->OpenProtocolInformation(Gu.handle,protocols[i],&entries,&count);
    if(!EFI_ERROR(status) && (count>MAX_RECORDS-*Count || (count && !entries)))status=EFI_COMPROMISED_DATA;
    if(!EFI_ERROR(status))for(UINTN j=0;j<count;j++) {
      Records[*Count].protocol=*protocols[i];Records[*Count].entry=entries[j];(*Count)++;
    }
    if(entries && EFI_ERROR(Gu.bs->FreePool(entries)))status=EFI_DEVICE_ERROR;
  }
  if(protocols && EFI_ERROR(Gu.bs->FreePool(protocols)))status=EFI_DEVICE_ERROR;
  return !EFI_ERROR(status) && !pci?EFI_NOT_FOUND:status;
}
static VOID LogRecords(const OWNER_RECORD *Records,UINTN Count,EFI_STATUS Status) {
  GuLog("ownership: records=%zu exclusive=%u status=%#llx\n",(size_t)Count,Gu.owned,(unsigned long long)Status);
  for(UINTN i=0;i<Count;i++) {
    const EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *e=&Records[i].entry;
    GuLog("owner[%u] protocol=%08x attributes=%#x count=%u agent=%#llx controller=%#llx\n",
      (unsigned)i,Records[i].protocol.Data1,e->Attributes,e->OpenCount,
      (unsigned long long)(UINTN)e->AgentHandle,(unsigned long long)(UINTN)e->ControllerHandle);
  }
}
EFI_STATUS GuClaimController(VOID) {
  OWNER_RECORD records[MAX_RECORDS];UINTN count=0;
  EFI_TPL old=Gu.bs->RaiseTPL(TPL_NOTIFY);
  EFI_STATUS status=Snapshot(records,&count);
  if(!EFI_ERROR(status))for(UINTN i=0;i<count;i++)if(!Passive(records[i].entry.Attributes))status=EFI_ACCESS_DENIED;
  if(!EFI_ERROR(status)) {
    EFI_PCI_IO_PROTOCOL *pci=NULL;
    status=Gu.bs->OpenProtocol(Gu.handle,&PciGuid,(VOID **)&pci,Gu.image,NULL,EFI_OPEN_PROTOCOL_EXCLUSIVE);
    if(!EFI_ERROR(status)){Gu.owned=TRUE;if(pci!=Gu.pci)status=EFI_COMPROMISED_DATA;}
  }
  Gu.bs->RestoreTPL(old);LogRecords(records,count,status);return status;
}
static BOOLEAN ConsoleHandle(EFI_SYSTEM_TABLE *Table,EFI_HANDLE Handle) {
  return Handle && (Handle==Table->ConsoleOutHandle || Handle==Table->ConsoleInHandle || Handle==Table->StandardErrorHandle);
}
/* v0.4.1: permit only this driver's physical GOP children on the exact target.
 * A child record alone is insufficient: check GOP, geometry and PCI ancestry.
 * Hash its full bounded device path so final arming catches path replacement. */
static EFI_STATUS DisplayChild(const OWNER_RECORD *Record,GU_RELEASE_OWNER *Owner) {
  const EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *e=&Record->entry;
  if(e->Attributes!=EFI_OPEN_PROTOCOL_BY_CHILD_CONTROLLER || e->AgentHandle!=Owner->agent ||
     e->OpenCount!=1 || !e->ControllerHandle || e->ControllerHandle==Gu.handle ||
     e->ControllerHandle==Gu.image || Owner->child_count>=GU_MAX_DISPLAY_CHILDREN ||
     (memcmp(&Record->protocol,&PciGuid,sizeof(PciGuid)) &&
      memcmp(&Record->protocol,&PathGuid,sizeof(PathGuid))))return EFI_ACCESS_DENIED;
  EFI_GRAPHICS_OUTPUT_PROTOCOL *gop=NULL;EFI_DEVICE_PATH_PROTOCOL *path=NULL;
  EFI_STATUS status=Gu.bs->HandleProtocol(e->ControllerHandle,&GopGuid,(VOID **)&gop);
  if(EFI_ERROR(status) || !gop || !gop->Mode)return EFI_UNSUPPORTED;
  EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *m=gop->Mode;
  if(!m->Info || m->SizeOfInfo<sizeof(*m->Info) || !m->FrameBufferBase || !m->FrameBufferSize ||
     !m->Info->HorizontalResolution || !m->Info->VerticalResolution ||
     m->Info->PixelFormat>PixelBlueGreenRedReserved8BitPerColor ||
     m->Info->PixelsPerScanLine<m->Info->HorizontalResolution ||
     (UINT64)m->Info->PixelsPerScanLine*m->Info->VerticalResolution>m->FrameBufferSize/4)return EFI_UNSUPPORTED;
  status=Gu.bs->HandleProtocol(e->ControllerHandle,&PathGuid,(VOID **)&path);
  if(EFI_ERROR(status) || !path || !Gu.bs->LocateDevicePath)return EFI_UNSUPPORTED;
  UINTN bytes=0;BOOLEAN end=FALSE;
  for(UINTN i=0;i<128 && bytes<=4092;i++) {
    EFI_DEVICE_PATH_PROTOCOL *node=(VOID *)((UINT8 *)path+bytes);
    UINTN length=node->Length[0]+((UINTN)node->Length[1]<<8);
    if(length<4 || length>4096-bytes)return EFI_COMPROMISED_DATA;
    bytes+=length;
    if(node->Type==END_DEVICE_PATH_TYPE) {
      if(node->SubType!=END_ENTIRE_DEVICE_PATH_SUBTYPE || length!=4)return EFI_UNSUPPORTED;
      end=TRUE;break;
    }
  }
  if(!end)return EFI_COMPROMISED_DATA;
  EFI_DEVICE_PATH_PROTOCOL *remaining=path;EFI_HANDLE parent=NULL;
  status=Gu.bs->LocateDevicePath(&PciGuid,&remaining,&parent);
  if(EFI_ERROR(status) || parent!=Gu.handle)return EFI_ACCESS_DENIED;
  for(UINTN i=0;i<Owner->child_count;i++)
    if(Owner->children[i].handle==e->ControllerHandle &&
       !memcmp(&Owner->children[i].protocol,&Record->protocol,sizeof(EFI_GUID)))return EFI_COMPROMISED_DATA;
  GU_DISPLAY_CHILD *child=&Owner->children[Owner->child_count++];
  child->handle=e->ControllerHandle;child->protocol=Record->protocol;child->gop=gop;
  child->framebuffer=m->FrameBufferBase;child->framebuffer_size=m->FrameBufferSize;
  GuSha256(path,bytes,child->path_sha256);
  return EFI_SUCCESS;
}
/* A display output of the target driver that carries no live display state
 * (a port the firmware enumerated but never lit: no GOP, no mode, or no
 * framebuffer behind it) has nothing to preserve and is no obstacle to
 * release. Permit it only when it proves the same identity and PCI ancestry
 * DisplayChild demands of a live GOP child; a child with a live framebuffer
 * that failed DisplayChild's stricter checks is still refused. Tolerated
 * children are not recorded, so owner comparisons stay exact. */
static EFI_STATUS DisplayChildNoGop(const OWNER_RECORD *Record,GU_RELEASE_OWNER *Owner) {
  const EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *e=&Record->entry;
  if(e->Attributes!=EFI_OPEN_PROTOCOL_BY_CHILD_CONTROLLER || e->AgentHandle!=Owner->agent ||
     e->OpenCount!=1 || !e->ControllerHandle || e->ControllerHandle==Gu.handle ||
     e->ControllerHandle==Gu.image ||
     (memcmp(&Record->protocol,&PciGuid,sizeof(PciGuid)) &&
      memcmp(&Record->protocol,&PathGuid,sizeof(PathGuid))))return EFI_ACCESS_DENIED;
  EFI_GRAPHICS_OUTPUT_PROTOCOL *gop=NULL;
  EFI_STATUS status=Gu.bs->HandleProtocol(e->ControllerHandle,&GopGuid,(VOID **)&gop);
  if(!EFI_ERROR(status) && gop && gop->Mode && gop->Mode->FrameBufferBase && gop->Mode->FrameBufferSize)
    return EFI_UNSUPPORTED;
  EFI_DEVICE_PATH_PROTOCOL *path=NULL;
  status=Gu.bs->HandleProtocol(e->ControllerHandle,&PathGuid,(VOID **)&path);
  if(EFI_ERROR(status) || !path || !Gu.bs->LocateDevicePath)return EFI_UNSUPPORTED;
  UINTN bytes=0;BOOLEAN end=FALSE;
  for(UINTN i=0;i<128 && bytes<=4092;i++) {
    EFI_DEVICE_PATH_PROTOCOL *node=(VOID *)((UINT8 *)path+bytes);
    UINTN length=node->Length[0]+((UINTN)node->Length[1]<<8);
    if(length<4 || length>4096-bytes)return EFI_COMPROMISED_DATA;
    bytes+=length;
    if(node->Type==END_DEVICE_PATH_TYPE) {
      if(node->SubType!=END_ENTIRE_DEVICE_PATH_SUBTYPE || length!=4)return EFI_UNSUPPORTED;
      end=TRUE;break;
    }
  }
  if(!end)return EFI_COMPROMISED_DATA;
  EFI_DEVICE_PATH_PROTOCOL *remaining=path;EFI_HANDLE parent=NULL;
  status=Gu.bs->LocateDevicePath(&PciGuid,&remaining,&parent);
  if(EFI_ERROR(status) || parent!=Gu.handle)return EFI_ACCESS_DENIED;
  return EFI_SUCCESS;
}
EFI_STATUS GuFindReleaseOwner(EFI_SYSTEM_TABLE *Table,GU_RELEASE_OWNER *Owner,BOOLEAN Log) {
  OWNER_RECORD records[MAX_RECORDS];UINTN count=0,drivers=0;memset(Owner,0,sizeof(*Owner));
  if(!Gu.bs->DisconnectController || Gu.owned)return EFI_UNSUPPORTED;
  EFI_TPL old=Gu.bs->RaiseTPL(TPL_NOTIFY);
  EFI_STATUS status=Snapshot(records,&count);
  Gu.bs->RestoreTPL(old);if(Log)LogRecords(records,count,status);
  if(EFI_ERROR(status))return status;
  for(UINTN i=0;i<count;i++) {
    const EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *e=&records[i].entry;
    if(!memcmp(&records[i].protocol,&PciGuid,sizeof(PciGuid)) && e->Attributes==EFI_OPEN_PROTOCOL_BY_DRIVER) {
      if(!e->AgentHandle || e->ControllerHandle!=Gu.handle || e->OpenCount!=1)return EFI_ACCESS_DENIED;
      Owner->agent=e->AgentHandle;drivers++;
    }
  }
  if(drivers!=1 || Owner->agent==Gu.image || Owner->agent==Gu.handle || ConsoleHandle(Table,Owner->agent))return EFI_ACCESS_DENIED;
  for(UINTN i=0;i<count;i++) {
    const EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *e=&records[i].entry;
    if(Passive(e->Attributes))continue;
    if(e->Attributes==EFI_OPEN_PROTOCOL_BY_CHILD_CONTROLLER) {
      status=DisplayChild(&records[i],Owner);
      if(Log)GuLog("display child: record=%u handle=%#llx agent=%#llx status=%#llx\n",
        (unsigned)i,(unsigned long long)(UINTN)e->ControllerHandle,
        (unsigned long long)(UINTN)e->AgentHandle,(unsigned long long)status);
      if(status==EFI_UNSUPPORTED) {
        EFI_STATUS empty=DisplayChildNoGop(&records[i],Owner);
        if(Log)GuLog("display child no-gop check: record=%u handle=%#llx status=%#llx\n",
          (unsigned)i,(unsigned long long)(UINTN)e->ControllerHandle,(unsigned long long)empty);
        if(!EFI_ERROR(empty))status=EFI_SUCCESS;
      }
      if(EFI_ERROR(status))return status;
      continue;
    }
    if(e->Attributes!=EFI_OPEN_PROTOCOL_BY_DRIVER || e->AgentHandle!=Owner->agent ||
       e->ControllerHandle!=Gu.handle || e->OpenCount!=1) {
      if(Log)GuLog("release refused: different owner or unsupported open at record %u\n",(unsigned)i);
      return EFI_ACCESS_DENIED;
    }
  }
  EFI_DRIVER_BINDING_PROTOCOL *binding=NULL;EFI_LOADED_IMAGE_PROTOCOL *image=NULL;
  status=Gu.bs->HandleProtocol(Owner->agent,&BindingGuid,(VOID **)&binding);
  if(EFI_ERROR(status) || !binding || binding->DriverBindingHandle!=Owner->agent || !binding->Stop ||
    !binding->ImageHandle || binding->ImageHandle==Gu.image)return EFI_UNSUPPORTED;
  status=Gu.bs->HandleProtocol(binding->ImageHandle,&LoadedGuid,(VOID **)&image);
  if(EFI_ERROR(status) || !image)return EFI_UNSUPPORTED;
  if(Log)GuLog("release candidate: agent=%#llx image=%#llx source=%#llx base=%#llx bytes=%llu version=%#x code_type=%u children=%zu\n",
    (unsigned long long)(UINTN)Owner->agent,(unsigned long long)(UINTN)binding->ImageHandle,
    (unsigned long long)(UINTN)image->DeviceHandle,(unsigned long long)(UINTN)image->ImageBase,
    (unsigned long long)image->ImageSize,binding->Version,(unsigned)image->ImageCodeType,(size_t)Owner->child_count);
  if(!image->ImageBase || !image->ImageSize || image->ImageSize>64U*1024U*1024U || image->ImageCodeType!=EfiBootServicesCode)return EFI_UNSUPPORTED;
  Owner->image=binding->ImageHandle;Owner->base=image->ImageBase;Owner->size=image->ImageSize;
  Owner->version=binding->Version;Owner->stop=binding->Stop;return EFI_SUCCESS;
}
BOOLEAN GuSameReleaseOwner(const GU_RELEASE_OWNER *A,const GU_RELEASE_OWNER *B) {
  if(A->agent!=B->agent || A->image!=B->image || A->base!=B->base || A->size!=B->size ||
    A->version!=B->version || A->stop!=B->stop || A->child_count!=B->child_count)return FALSE;
  /* Snapshot iteration order is not an identity; compare complete record sets. */
  for(UINTN i=0;i<A->child_count;i++) {
    BOOLEAN match=FALSE;
    for(UINTN j=0;j<B->child_count;j++)
      if(!memcmp(&A->children[i],&B->children[j],sizeof(GU_DISPLAY_CHILD)))match=TRUE;
    if(!match)return FALSE;
  }
  return TRUE;
}
EFI_STATUS GuRefreshTargetPci(VOID) {
  EFI_PCI_IO_PROTOCOL *fresh=NULL;UINTN segment,bus,device,function;UINT32 config[64]={0};
  Gu.pci=NULL;
  EFI_STATUS status=Gu.bs->HandleProtocol(Gu.handle,&PciGuid,(VOID **)&fresh);
  if(EFI_ERROR(status) || !fresh || !fresh->GetLocation || !fresh->Pci.Read || !fresh->Pci.Write)return EFI_NOT_FOUND;
  status=fresh->GetLocation(fresh,&segment,&bus,&device,&function);if(EFI_ERROR(status))return status;
  const UINT32 offsets[]={0,8,12,44};
  for(UINTN i=0;i<4;i++) {
    status=fresh->Pci.Read(fresh,EfiPciIoWidthUint32,offsets[i],1,&config[offsets[i]/4]);if(EFI_ERROR(status))return status;
  }
  if(!GuTargetConfig(config,segment,bus,device,function))return EFI_UNSUPPORTED;
  Gu.pci=fresh;return EFI_SUCCESS;
}
