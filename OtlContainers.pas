﻿///<summary>Lock-free containers. Part of the OmniThreadLibrary project.</summary>
///<author>Primoz Gabrijelcic, GJ</author>
///<license>
///This software is distributed under the BSD license.
///
///Copyright (c) 2009 Primoz Gabrijelcic
///All rights reserved.
///
///Redistribution and use in source and binary forms, with or without modification,
///are permitted provided that the following conditions are met:
///- Redistributions of source code must retain the above copyright notice, this
///  list of conditions and the following disclaimer.
///- Redistributions in binary form must reproduce the above copyright notice,
///  this list of conditions and the following disclaimer in the documentation
///  and/or other materials provided with the distribution.
///- The name of the Primoz Gabrijelcic may not be used to endorse or promote
///  products derived from this software without specific prior written permission.
///
///THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
///ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
///WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
///DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
///ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
///(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
///LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
///ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
///(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
///SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
///</license>
///<remarks><para>
///   Author            : GJ, Primoz Gabrijelcic
///   Creation date     : 2008-07-13
///   Last modification : 2009-12-25
///   Version           : 2.0
///</para><para>
///   History:
///     2.0: 2009-12-25
///       - Implemented dynamically allocated, O(1) enqueue and dequeue, threadsafe,
///         microlocking queue. Class TOmniBaseCollection contains base implementation
///         while TOmniCollection adds notification support.
///     1.02: 2009-12-22
///       - TOmniContainerSubject moved into OtlContainerObserver because it will also be
///         used in OtlCollections.
///     1.01b: 2009-11-11
///       - [GJ] better fix for the initialization crash.
///     1.01a: 2009-11-10
///       - Bug fixed: Initialization code could crash with range check error.
///     1.01: 2008-10-26
///       - [GJ] Redesigned stack with better lock contention.
///       - [GJ] Totally redesigned queue, which is no longer based on stack and allows
///         multiple readers.
///</para></remarks>

{$WARN SYMBOL_PLATFORM OFF}

unit OtlContainers;

{$R-,O+,A8}

interface

uses
  Classes,
  DSiWin32,
  GpStuff,
  OtlCommon,
  OtlSync,
  OtlContainerObserver;

const
  CPartlyEmptyLoadFactor = 0.8; // When an element count drops below 80%, the container is considered 'partly empty'.
  CAlmostFullLoadFactor  = 0.9; // When an element count raises above 90%, the container is considered 'almost full'.

type
  {:Lock-free, single writer, single reader, size-limited stack.
  }
  IOmniStack = interface ['{F4C57327-18A0-44D6-B95D-2D51A0EF32B4}']
    procedure Empty;
    procedure Initialize(numElements, elementSize: integer);
    function  IsEmpty: boolean;
    function  IsFull: boolean;
    function  Pop(var value): boolean;
    function  Push(const value): boolean;
  end; { IOmniStack }

  {:Lock-free, single writer, single reader ring buffer.
  }
  IOmniQueue = interface ['{AE6454A2-CDB4-43EE-9F1B-5A7307593EE9}']
    function  Dequeue(var value): boolean;
    procedure Empty;
    function  Enqueue(const value): boolean;
    procedure Initialize(numElements, elementSize: integer);
    function  IsEmpty: boolean;
    function  IsFull: boolean;
  end; { IOmniQueue }

  PReferencedPtr = ^TReferencedPtr;
  TReferencedPtr = record
    PData    : pointer;
    Reference: cardinal;
  end; { TReferencedPtr }

  TReferencedPtrBuffer = array [0..MaxInt shr 4] of TReferencedPtr;

  POmniRingBuffer = ^TOmniRingBuffer;
  TOmniRingBuffer  = packed record
    FirstIn        : TReferencedPtr;
    LastIn         : TReferencedPtr;
    StartBuffer    : pointer;
    EndBuffer      : pointer;
    Buffer         : TReferencedPtrBuffer;
  end; { TOmniRingBuffer }

  POmniLinkedData = ^TOmniLinkedData;
  TOmniLinkedData = packed record
    Next: POmniLinkedData;
    Data: record end;           //user data, variable size
  end; { TOmniLinkedData }

  TOmniBaseStack = class abstract(TInterfacedObject, IOmniStack)
  strict private
    obsDataBuffer   : pointer;
    obsElementSize  : integer;
    obsNumElements  : integer;
    obsPublicChainP : PReferencedPtr;
    obsRecycleChainP: PReferencedPtr;
    class var obsIsInitialized: boolean;                //default is false
    class var obsTaskPopLoops : cardinal;
    class var obsTaskPushLoops: cardinal;
  strict protected
    procedure MeasureExecutionTimes;
    class function  PopLink(var chain: TReferencedPtr): POmniLinkedData; static;
    class procedure PushLink(const link: POmniLinkedData; var chain: TReferencedPtr); static;
  public
    destructor Destroy; override;
    procedure Empty;
    procedure Initialize(numElements, elementSize: integer); virtual;
    function  IsEmpty: boolean; inline;
    function  IsFull: boolean; inline;
    function  Pop(var value): boolean;
    function  Push(const value): boolean;
    property  ElementSize: integer read obsElementSize;
    property  NumElements: integer read obsNumElements;
  end; { TOmniBaseStack }

  TOmniStack = class(TOmniBaseStack)
  strict private
    osAlmostFullCount : integer;
    osContainerSubject: TOmniContainerSubject;
    osInStackCount    : TGp4AlignedInt;
    osPartlyEmptyCount: integer;
  public
    constructor Create(numElements, elementSize: integer;
      partlyEmptyLoadFactor: real = CPartlyEmptyLoadFactor;
      almostFullLoadFactor: real = CAlmostFullLoadFactor);
    destructor  Destroy; override;
    function Pop(var value): boolean;
    function Push(const value): boolean; 
    property ContainerSubject: TOmniContainerSubject read osContainerSubject;
  end; { TOmniStack }

  TOmniBaseQueue = class abstract(TInterfacedObject, IOmniQueue)
  strict private
    obqDataBuffer               : pointer;
    obqElementSize              : integer;
    obqNumElements              : integer;
    obqPublicRingBuffer         : POmniRingBuffer;
    obqRecycleRingBuffer        : POmniRingBuffer;
    class var obqTaskInsertLoops: cardinal;             //default is false
    class var obqTaskRemoveLoops: cardinal;
    class var obqIsInitialized  : boolean;
  strict protected
    class procedure InsertLink(const data: pointer; const ringBuffer: POmniRingBuffer);
      static;
    class function  RemoveLink(const ringBuffer: POmniRingBuffer): pointer; static;
    procedure MeasureExecutionTimes;
  public
    destructor Destroy; override;
    function  Dequeue(var value): boolean;
    procedure Empty;
    function  Enqueue(const value): boolean;
    procedure Initialize(numElements, elementSize: integer); virtual;
    function  IsEmpty: boolean;
    function  IsFull: boolean;
    property  ElementSize: integer read obqElementSize;
    property  NumElements: integer read obqNumElements;
  end; { TOmniBaseQueue }

  TOmniQueue = class(TOmniBaseQueue)
  strict private
    oqAlmostFullCount : integer;
    oqContainerSubject: TOmniContainerSubject;
    oqInQueueCount    : TGp4AlignedInt;
    oqPartlyEmptyCount: integer;
  public
    constructor Create(numElements, elementSize: integer;
      partlyEmptyLoadFactor: real = CPartlyEmptyLoadFactor;
      almostFullLoadFactor: real = CAlmostFullLoadFactor);
    destructor  Destroy; override;
    function  Dequeue(var value): boolean;
    function  Enqueue(const value): boolean;
    property  ContainerSubject: TOmniContainerSubject read oqContainerSubject;
  end; { TOmniQueue }

  TOmniCollectionTag = (tagFree, tagAllocating, tagAllocated, tagRemoving, tagRemoved,
    tagEndOfList, tagExtending, tagBlockPointer, tagDestroying
    {$IFDEF DEBUG}, tagStartOfList, tagSentinel{$ENDIF});

  TOmniTaggedValue = packed record
    Tag     : TOmniCollectionTag;
    Stuffing: word;
    Value   : TOmniValue;
    function CASTag(oldTag, newTag: TOmniCollectionTag): boolean;
  end; { TOmniTaggedValue }
  POmniTaggedValue = ^TOmniTaggedValue;

  ///<summary>Dynamically allocated, O(1) enqueue and dequeue, threadsafe, microlocking queue.</summary>
  TOmniBaseCollection = class
  strict private // keep 4-aligned
    obcCachedBlock: POmniTaggedValue;
    obcHeadPointer: POmniTaggedValue;
    obcTailPointer: POmniTaggedValue;
  strict private
    obcRemoveCount: TGp4AlignedInt;
  strict protected
    function  AllocateBlock: POmniTaggedValue;
    procedure EnterReader; 
    procedure LeaveReader; inline;
    procedure LeaveWriter; inline;
    procedure ReleaseBlock(lastSlot: POmniTaggedValue; forceFree: boolean = false);
    procedure EnterWriter; 
    procedure WaitForAllRemoved(const lastSlot: POmniTaggedValue);
  public
    constructor Create;
    destructor  Destroy; override;
    function  Dequeue: TOmniValue;
    procedure Enqueue(const value: TOmniValue);
    function  TryDequeue(var value: TOmniValue): boolean;
  end; { TOmniBaseCollection }

  TOmniCollection = class(TOmniBaseCollection)
  strict private
    ocContainerSubject: TOmniContainerSubject;
  public
    constructor Create;
    destructor  Destroy; override;
    function  Dequeue: TOmniValue;
    procedure Enqueue(const value: TOmniValue);
    function  TryDequeue(var value: TOmniValue): boolean;
    property ContainerSubject: TOmniContainerSubject read ocContainerSubject;
  end; { TOmniCollection }

implementation

uses
  Windows,
  SysUtils;

const
  CCollNumSlots = 4*1024 {$IFDEF DEBUG} - 3 {$ENDIF};
  CCollBlockSize = SizeOf(TOmniTaggedValue) * CCollNumSlots; //64 KB

{ TOmniBaseStack }

destructor TOmniBaseStack.Destroy;
begin
  FreeMem(obsPublicChainP);
  inherited;
end; { TOmniBaseStack.Destroy }

procedure TOmniBaseStack.Empty;
var
  linkedData: POmniLinkedData;
begin
  repeat
    linkedData := PopLink(obsPublicChainP^);
    if not assigned(linkedData) then
      break; //repeat
    PushLink(linkedData, obsRecycleChainP^);
  until false;
end; { TOmniBaseStack.Empty }

procedure TOmniBaseStack.Initialize(numElements, elementSize: integer);
var
  bufferElementSize: integer;
  currElement      : POmniLinkedData;
  iElement         : integer;
  nextElement      : POmniLinkedData;
begin
  Assert(SizeOf(cardinal) = SizeOf(pointer));
  Assert(numElements > 0);
  Assert(elementSize > 0);
  obsNumElements := numElements;
  //calculate element size, round up to next 4-aligned value
  obsElementSize := (elementSize + 3) AND NOT 3;
  //calculate buffer element size, round up to next 4-aligned value
  bufferElementSize := ((SizeOf(TOmniLinkedData) + obsElementSize) + 3) AND NOT 3;
  //calculate DataBuffer
  GetMem(obsDataBuffer, bufferElementSize * numElements + 2 * SizeOf(TReferencedPtr));
  if cardinal(obsDataBuffer) AND 7 <> 0 then
    raise Exception.Create('TOmniBaseContainer: obcBuffer is not 8-aligned');
  obsPublicChainP := obsDataBuffer;
  inc(cardinal(obsDataBuffer), SizeOf(TReferencedPtr));
  obsRecycleChainP := obsDataBuffer;
  inc(cardinal(obsDataBuffer), SizeOf(TReferencedPtr));
  //Format buffer to recycleChain, init obsRecycleChain and obsPublicChain.
  //At the beginning, all elements are linked into the recycle chain.
  obsRecycleChainP^.PData := obsDataBuffer;
  currElement := obsRecycleChainP^.PData;
  for iElement := 0 to obsNumElements - 2 do begin
    nextElement := POmniLinkedData(integer(currElement) + bufferElementSize);
    currElement.Next := nextElement;
    currElement := nextElement;
  end;
  currElement.Next := nil; // terminate the chain
  obsPublicChainP^.PData := nil;
  MeasureExecutionTimes;
end; { TOmniBaseStack.Initialize }

function TOmniBaseStack.IsEmpty: boolean;
begin
  Result := not assigned(obsPublicChainP^.PData);
end; { TOmniBaseStack.IsEmpty }

function TOmniBaseStack.IsFull: boolean;
begin
  Result := not assigned(obsRecycleChainP^.PData);
end; { TOmniBaseStack.IsFull }

procedure TOmniBaseStack.MeasureExecutionTimes;
const
  NumOfSamples = 10;
var
  TimeTestField: array [0..1] of array [1..NumOfSamples] of int64;

  function GetMinAndClear(routine, count: cardinal): int64;
  var
    m: cardinal;
    n: integer;
    x: integer;
  begin
    Result := 0;
    for m := 1 to count do begin
      x:= 1;
      for n:= 2 to NumOfSamples do
        if TimeTestField[routine, n] < TimeTestField[routine, x] then
          x := n;
      Inc(Result, TimeTestField[routine, x]);
      TimeTestField[routine, x] := MaxLongInt;
    end;
  end; { GetMinAndClear }

var
  affinity   : string;
  currElement: POmniLinkedData;
  n          : integer;

begin { TOmniBaseStack.MeasureExecutionTimes }
  if not obsIsInitialized then begin
    affinity := DSiGetThreadAffinity;
    DSiSetThreadAffinity(affinity[1]);
    try
      //Calculate  TaskPopDelay and TaskPushDelay counter values depend on CPU speed!!!}
      obsTaskPopLoops := 1;
      obsTaskPushLoops := 1;
      for n := 1 to NumOfSamples do begin
        DSiYield;
        //Measure RemoveLink rutine delay
        TimeTestField[0, n] := GetCPUTimeStamp;
        currElement := PopLink(obsRecycleChainP^);
        TimeTestField[0, n] := GetCPUTimeStamp - TimeTestField[0, n];
        //Measure InsertLink rutine delay
        TimeTestField[1, n] := GetCPUTimeStamp;
        PushLink(currElement, obsRecycleChainP^);
        TimeTestField[1, n] := GetCPUTimeStamp - TimeTestField[1, n];
      end;
      //Calculate first 4 minimum average for RemoveLink rutine
      obsTaskPopLoops := GetMinAndClear(0, 4) div 4;
      //Calculate first 4 minimum average for InsertLink rutine
      obsTaskPushLoops := GetMinAndClear(1, 4) div 4;
      obsIsInitialized := true;
    finally DSiSetThreadAffinity(affinity); end;
  end;
end;  { TOmniBaseStack.MeasureExecutionTimes }

function TOmniBaseStack.Pop(var value): boolean;
var
  linkedData: POmniLinkedData;
begin
  linkedData := PopLink(obsPublicChainP^);
  Result := assigned(linkedData);
  if not Result then
    Exit;
  Move(linkedData.Data, value, ElementSize);
  PushLink(linkedData, obsRecycleChainP^);
end; { TOmniBaseStack.Pop }

class function TOmniBaseStack.PopLink(var chain: TReferencedPtr): POmniLinkedData;
//nil << Link.Next << Link.Next << ... << Link.Next
//FILO buffer logic                         ^------ < chainHead
//Advanced stack PopLink model with idle/busy status bit
var
  AtStartReference: cardinal;
  CurrentReference: cardinal;
  TaskCounter     : cardinal;
  ThreadReference : cardinal;
label
  TryAgain;
begin
  ThreadReference := GetThreadId + 1;                           //Reference.bit0 := 1
  with chain do begin
TryAgain:
    TaskCounter := obsTaskPopLoops;
    AtStartReference := Reference OR 1;                         //Reference.bit0 := 1
    repeat
      CurrentReference := Reference;
      Dec(TaskCounter);
    until (TaskCounter = 0) or (CurrentReference AND 1 = 0);
    if (CurrentReference AND 1 <> 0) and (AtStartReference <> CurrentReference) or
       not CAS32(CurrentReference, ThreadReference, Reference)
    then
      goto TryAgain;
    //Reference is set...
    result := PData;
    //Empty test
    if result = nil then
      CAS32(ThreadReference, 0, Reference)            //Clear Reference if task own reference
    else
      if not CAS64(result, ThreadReference, result.Next, 0, chain) then
        goto TryAgain;
  end;
end; { TOmniBaseStack.PopLink }

function TOmniBaseStack.Push(const value): boolean;
var
  linkedData: POmniLinkedData;
begin
  linkedData := PopLink(obsRecycleChainP^);
  Result := assigned(linkedData);
  if not Result then
    Exit;
  Move(value, linkedData.Data, ElementSize);
  PushLink(linkedData, obsPublicChainP^);
end; { TOmniBaseStack.Push }

class procedure TOmniBaseStack.PushLink(const link: POmniLinkedData; var chain: TReferencedPtr);
//Advanced stack PushLink model with idle/busy status bit
var
  PMemData   : pointer;
  TaskCounter: cardinal;
begin
  with chain do begin
    for TaskCounter := 0 to obsTaskPushLoops do
      if (Reference AND 1 = 0) then
        break;
    repeat
      PMemData := PData;
      link.Next := PMemData;
    until CAS32(PMemData, link, PData);
  end;
end; { TOmniBaseStack.PushLink }

{ TOmniStack }

constructor TOmniStack.Create(numElements, elementSize: integer; partlyEmptyLoadFactor,
  almostFullLoadFactor: real);
begin
  inherited Create;
  Initialize(numElements, elementSize);
  osContainerSubject := TOmniContainerSubject.Create;
  osInStackCount.Value := 0;
  osPartlyEmptyCount := Round(numElements * partlyEmptyLoadFactor);
  if osPartlyEmptyCount >= numElements then
    osPartlyEmptyCount := numElements - 1;
  osAlmostFullCount := Round(numElements * almostFullLoadFactor);
  if osAlmostFullCount >= numElements then
    osAlmostFullCount := numElements - 1;
end; { TOmniStack.Create }

destructor TOmniStack.Destroy;
begin
  FreeAndNil(osContainerSubject);
  inherited;
end; { TOmniStack.Destroy }

function TOmniStack.Pop(var value): boolean;
var
  countAfter: integer;
begin
  Result := inherited Pop(value);
  if Result then begin
    countAfter := osInStackCount.Decrement;  //' range check error??
    ContainerSubject.Notify(coiNotifyOnAllRemoves);
    if countAfter <= osPartlyEmptyCount then
      ContainerSubject.NotifyOnce(coiNotifyOnPartlyEmpty);
  end;
end; { TOmniStack.Pop }

function TOmniStack.Push(const value): boolean;
var
  countAfter : integer;
begin
  Result := inherited Push(value);
  if Result then begin
    countAfter := osInStackCount.Increment;
    ContainerSubject.Notify(coiNotifyOnAllInserts);
    if countAfter >= osAlmostFullCount then
      ContainerSubject.NotifyOnce(coiNotifyOnAlmostFull);
  end;
end; { TOmniStack.Push }

{ TOmniBaseQueue }

function TOmniBaseQueue.Dequeue(var value): boolean;
var
  Data: pointer;
begin
  Data := RemoveLink(obqPublicRingBuffer);
  Result := assigned(Data);
  if not Result then
    Exit;
  Move(Data^, value, ElementSize);
  InsertLink(Data, obqRecycleRingBuffer);
end; { TOmniBaseQueue.Dequeue }

destructor TOmniBaseQueue.Destroy;
begin
  FreeMem(obqDataBuffer);
  FreeMem(obqPublicRingBuffer);
  FreeMem(obqRecycleRingBuffer);
  inherited;
end; { TOmniBaseQueue.Destroy }

procedure TOmniBaseQueue.Empty;
var
  Data: pointer;
begin
  repeat
    Data := RemoveLink(obqPublicRingBuffer);
    if assigned(Data) then
      InsertLink(Data, obqRecycleRingBuffer)
    else
      break;
  until false;
end; { TOmniBaseQueue.Empty }

function TOmniBaseQueue.Enqueue(const value): boolean;
var
  Data: pointer;
begin
  Data := RemoveLink(obqRecycleRingBuffer);
  Result := assigned(Data);
  if not Result then
    Exit;
  Move(value, Data^, ElementSize);
  InsertLink(Data, obqPublicRingBuffer);
end; { TOmniBaseQueue.Enqueue }

procedure TOmniBaseQueue.Initialize(numElements, elementSize: integer);
var
  n             : integer;
  ringBufferSize: cardinal;
begin
  Assert(SizeOf(cardinal) = SizeOf(pointer));
  Assert(numElements > 0);
  Assert(elementSize > 0);
  obqNumElements := numElements;
  // calculate element size, round up to next 4-aligned value
  obqElementSize := (elementSize + 3) AND NOT 3;
  // allocate obqDataBuffer
  GetMem(obqDataBuffer, elementSize * numElements + elementSize);
  // allocate RingBuffers
  ringBufferSize := SizeOf(TReferencedPtr) * (numElements + 1) +
    SizeOf(TOmniRingBuffer) - SizeOf(TReferencedPtrBuffer);
  obqPublicRingBuffer := AllocMem(ringBufferSize);
  Assert(cardinal(obqPublicRingBuffer) mod 8 = 0,
    'TOmniBaseContainer: obcPublicRingBuffer is not 8-aligned');
  obqRecycleRingBuffer := AllocMem(ringBufferSize);
  Assert(cardinal(obqRecycleRingBuffer) mod 8 = 0,
    'TOmniBaseContainer: obcRecycleRingBuffer is not 8-aligned');
  // set obqPublicRingBuffer head
  obqPublicRingBuffer.FirstIn.PData := @obqPublicRingBuffer.Buffer[0];
  obqPublicRingBuffer.LastIn.PData := @obqPublicRingBuffer.Buffer[0];
  obqPublicRingBuffer.StartBuffer := @obqPublicRingBuffer.Buffer[0];
  obqPublicRingBuffer.EndBuffer := @obqPublicRingBuffer.Buffer[numElements];
  // set obqRecycleRingBuffer head
  obqRecycleRingBuffer.FirstIn.PData := @obqRecycleRingBuffer.Buffer[0];
  obqRecycleRingBuffer.LastIn.PData := @obqRecycleRingBuffer.Buffer[numElements];
  obqRecycleRingBuffer.StartBuffer := @obqRecycleRingBuffer.Buffer[0];
  obqRecycleRingBuffer.EndBuffer := @obqRecycleRingBuffer.Buffer[numElements];
  // format obqRecycleRingBuffer
  for n := 0 to numElements do
    obqRecycleRingBuffer.Buffer[n].PData := pointer(cardinal(obqDataBuffer) + cardinal(n * elementSize));
  MeasureExecutionTimes;
end; { TOmniBaseQueue.Initialize }

class procedure TOmniBaseQueue.InsertLink(const data: pointer; const ringBuffer:
  POmniRingBuffer);
//FIFO buffer logic
//Insert link to queue model with idle/busy status bit
var
  AtStartReference: cardinal;
  CurrentLastIn   : PReferencedPtr;
  CurrentReference: cardinal;
  NewLastIn       : PReferencedPtr;
  TaskCounter     : cardinal;
  ThreadReference : cardinal;
label
  TryAgain;
begin
  ThreadReference := GetThreadId + 1;                           //Reference.bit0 := 1
  with ringBuffer^ do begin
TryAgain:
    TaskCounter := obqTaskInsertLoops;
    AtStartReference := LastIn.Reference OR 1;                  //Reference.bit0 := 1
    repeat
      CurrentReference := LastIn.Reference;
      Dec(TaskCounter);
    until (TaskCounter = 0) or (CurrentReference AND 1 = 0);
    if (CurrentReference AND 1 <> 0) and (AtStartReference <> CurrentReference) or
       not CAS32(CurrentReference, ThreadReference, LastIn.Reference)
    then
      goto TryAgain;
    //Reference is set...
    CurrentLastIn := LastIn.PData;
    CAS32(CurrentLastIn.Reference, ThreadReference, CurrentLastIn.Reference);
    if (ThreadReference <> LastIn.Reference) or
      not CAS64(CurrentLastIn.PData, ThreadReference, data, ThreadReference, CurrentLastIn^)
    then
      goto TryAgain;
    //Calculate ringBuffer next LastIn address
    NewLastIn := pointer(cardinal(CurrentLastIn) + SizeOf(TReferencedPtr));
    if cardinal(NewLastIn) > cardinal(EndBuffer) then
      NewLastIn := StartBuffer;
    //Try to exchange and clear Reference if task own reference
    if not CAS64(CurrentLastIn, ThreadReference, NewLastIn, 0, LastIn) then
      goto TryAgain;
  end;
end; { TOmniBaseQueue.InsertLink }

function TOmniBaseQueue.IsEmpty: boolean;
begin
  Result := (obqPublicRingBuffer.FirstIn.PData = obqPublicRingBuffer.LastIn.PData);
end; { TOmniBaseQueue.IsEmpty }

function TOmniBaseQueue.IsFull: boolean;
var
  NewLastIn: pointer;
begin
  NewLastIn := pointer(cardinal(obqPublicRingBuffer.LastIn.PData) + SizeOf(TReferencedPtr));
  if cardinal(NewLastIn) > cardinal(obqPublicRingBuffer.EndBuffer) then
    NewLastIn := obqPublicRingBuffer.StartBuffer;
  result := (cardinal(NewLastIn) = cardinal(obqPublicRingBuffer.LastIn.PData)) or
    (obqRecycleRingBuffer.FirstIn.PData = obqRecycleRingBuffer.LastIn.PData);
end; { TOmniBaseQueue.IsFull }

procedure TOmniBaseQueue.MeasureExecutionTimes;
const
  NumOfSamples = 10;
var
  TimeTestField: array [0..1] of array [1..NumOfSamples] of int64;

  function GetMinAndClear(routine, count: cardinal): int64;
  var
    m: cardinal;
    n: integer;
    x: integer;
  begin
    Result  := 0;
    for m := 1 to count do begin
      x:= 1;
      for n:= 2 to NumOfSamples do
        if TimeTestField[routine, n] < TimeTestField[routine, x] then
          x := n;
      Inc(Result, TimeTestField[routine, x]);
      TimeTestField[routine, x] := MaxLongInt;
    end;
  end; { GetMinAndClear }

var
  affinity   : string;
  currElement: pointer;
  n          : integer;

begin { TOmniBaseQueue.MeasureExecutionTimes }
  if not obqIsInitialized then begin
    affinity := DSiGetThreadAffinity;
    DSiSetThreadAffinity(affinity[1]);
    try
      //Calculate  TaskPopDelay and TaskPushDelay counter values depend on CPU speed!!!}
      obqTaskRemoveLoops := 1;
      obqTaskInsertLoops := 1;
      for n := 1 to NumOfSamples do  begin
        DSiYield;
        //Measure RemoveLink rutine delay
        TimeTestField[0, n] := GetCPUTimeStamp;
        currElement := RemoveLink(obqRecycleRingBuffer);
        TimeTestField[0, n] := GetCPUTimeStamp - TimeTestField[0, n];
        //Measure InsertLink rutine delay
        TimeTestField[1, n] := GetCPUTimeStamp;
        InsertLink(currElement, obqRecycleRingBuffer);
        TimeTestField[1, n] := GetCPUTimeStamp - TimeTestField[1, n];
      end;
      obqTaskRemoveLoops := GetMinAndClear(0, 4) div 4;
      obqTaskInsertLoops := GetMinAndClear(1, 4) div 4;
      obqIsInitialized := true;
    finally DSiSetThreadAffinity(affinity); end;
  end;
end; { TOmniBaseQueue.MeasureExecutionTimes }

class function TOmniBaseQueue.RemoveLink(const ringBuffer: POmniRingBuffer): pointer;
//FIFO buffer logic
//Remove link from queue model with idle/busy status bit
var
  AtStartReference      : cardinal;
  CurrentFirstIn        : pointer;
  CurrentReference      : cardinal;
  NewFirstIn            : pointer;
  Reference             : cardinal;
  TaskCounter           : cardinal;
label
  TryAgain;
begin
  Reference := GetThreadId + 1;                                 //Reference.bit0 := 1
  with ringBuffer^ do begin
TryAgain:
    TaskCounter := obqTaskRemoveLoops;
    AtStartReference := FirstIn.Reference OR 1;                 //Reference.bit0 := 1
    repeat
      CurrentReference := FirstIn.Reference;
      Dec(TaskCounter);
    until (TaskCounter = 0) or (CurrentReference AND 1 = 0);
    if (CurrentReference AND 1 <> 0) and (AtStartReference <> CurrentReference) or
      not CAS32(CurrentReference, Reference, FirstIn.Reference)
    then
      goto TryAgain;
    //Reference is set...
    CurrentFirstIn := FirstIn.PData;
    //Empty test
    if CurrentFirstIn = LastIn.PData then begin
      //Clear Reference if task own reference
      CAS32(Reference, 0, FirstIn.Reference);
      Result := nil;
      Exit;
    end;
    //Load Result
    Result := PReferencedPtr(FirstIn.PData).PData;
    //Calculate ringBuffer next FirstIn address
    NewFirstIn := pointer(cardinal(CurrentFirstIn) + SizeOf(TReferencedPtr));
    if cardinal(NewFirstIn) > cardinal(EndBuffer) then
      NewFirstIn := StartBuffer;
    //Try to exchange and clear Reference if task own reference
    if not CAS64(CurrentFirstIn, Reference, NewFirstIn, 0, FirstIn) then
      goto TryAgain;
  end;
end; { TOmniBaseQueue.RemoveLink }

{ TOmniQueue }

constructor TOmniQueue.Create(numElements, elementSize: integer; partlyEmptyLoadFactor,
  almostFullLoadFactor: real);
begin
  inherited Create;
  oqContainerSubject := TOmniContainerSubject.Create;
  oqInQueueCount.Value := 0;
  oqPartlyEmptyCount := Round(numElements * partlyEmptyLoadFactor);
  if oqPartlyEmptyCount >= numElements then
    oqPartlyEmptyCount := numElements - 1;
  oqAlmostFullCount := Round(numElements * almostFullLoadFactor);
  if oqAlmostFullCount >= numElements then
    oqAlmostFullCount := numElements - 1;
  Initialize(numElements, elementSize);
end; { TOmniQueue.Create }

destructor TOmniQueue.Destroy;
begin
  FreeAndNil(oqContainerSubject);
  inherited;
end; { TOmniQueue.Destroy }

function TOmniQueue.Dequeue(var value): boolean;
var
  countAfter: integer;
begin
  Result := inherited Dequeue(value);
  if Result then begin
    countAfter := oqInQueueCount.Decrement;
    ContainerSubject.Notify(coiNotifyOnAllRemoves);
    if countAfter <= oqPartlyEmptyCount then
      ContainerSubject.NotifyOnce(coiNotifyOnPartlyEmpty);
  end;
end; { TOmniQueue.Dequeue }

function TOmniQueue.Enqueue(const value): boolean;
var
  countAfter: integer;
begin
  Result := inherited Enqueue(value);
  if Result then begin
    countAfter := oqInQueueCount.Increment;
    ContainerSubject.Notify(coiNotifyOnAllInserts);
    if countAfter >= oqAlmostFullCount then
      ContainerSubject.NotifyOnce(coiNotifyOnAlmostFull);
  end;
end; { TOmniQueue.Enqueue }

(*
TOmniCollection
===============

slot contains:
  tag = 1 byte
  2 bytes left empty
  TOmniValue = 13 bytes
tags are 4-aligned

tags:
  tagFree
  tagAllocating
  tagAllocated
  tagRemoving
  tagRemoved
  tagEndOfList
  tagExtending
  tagBlockPointer
  tagDestroying

Enqueue:
  readlock GC
  repeat
    fetch tag from current tail
    if tag = tagFree and CAS(tag, tagAllocating) then
      break
    if tag = tagEndOfList and CAS(tag, tagExtending) then
      break
    yield
  forever
  if tag = tagFree then
    increment tail
    store (tagAllocated, value) into locked slot
  else
    allocate and initialize new block
      last entry has tagEndOfList tag, others have tagFree
    set tail to new block's slot 1
    store (tagAllocated, value) into new block's slot 0
    store (tagBlockPointer, pointer to new block) into locked slot
  leave GC

Dequeue:
  readlock GC
  repeat
    fetch tag from current head
    if tag = tagFree then
      return Empty
    if tag = tagAllocated and CAS(tag, tagRemoving) then
      break
    if tag = tagBlockPointer and CAS(tag, tagDestroying) then
    yield
  forever
  if tag = tagAllocated then
    increment head
    get value
    store tagRemoved
  else
    if first slot in new block is allocated
      set head to new block's slot 1
      get value
    else
      set head to new block
    leave GC
    writelock GC
    release original block
    leave GC
    exit

  leave GC
*)

{ TOmniTaggedValue }

function TOmniTaggedValue.CASTag(oldTag, newTag: TOmniCollectionTag): boolean;
var
  newValue: DWORD;
  oldValue: DWORD;
begin
  oldValue := PDWORD(@Tag)^ AND $FFFFFF00 OR DWORD(ORD(oldTag));
  newValue := oldValue AND $FFFFFF00 OR DWORD(Ord(newTag));
  {$IFDEF Debug} Assert(cardinal(@Tag) mod 4 = 0); {$ENDIF}
  Result := CAS32(oldValue, newValue, Tag);
end; { TOmniTaggedValue.CASTag }

{ TOmniBaseCollection }

constructor TOmniBaseCollection.Create;
begin
  inherited;
  Assert(cardinal(obcHeadPointer) mod 4 = 0);
  Assert(cardinal(obcTailPointer) mod 4 = 0);
  Assert(cardinal(obcCachedBlock) mod 4 = 0);
  obcHeadPointer := AllocateBlock;
  obcTailPointer := obcHeadPointer;
end; { TOmniBaseCollection.Create }

function TOmniBaseCollection.Dequeue: TOmniValue;
begin
  if not TryDequeue(Result) then
    raise Exception.Create('TOmniBaseCollection.Dequeue: Message queue is empty');
end; { TOmniBaseCollection.Dequeue }

destructor TOmniBaseCollection.Destroy;
var
  pBlock: POmniTaggedValue;
begin
  while assigned(obcHeadPointer) do begin
    if obcHeadPointer.Tag in [tagBlockPointer, tagEndOfList] then begin
      pBlock := obcHeadPointer;
      obcHeadPointer := POmniTaggedValue(obcHeadPointer.Value.AsPointer);
      ReleaseBlock(pBlock, true);
    end
    else
      Inc(obcHeadPointer);
  end;
  if assigned(obcCachedBlock) then
    FreeMem(obcCachedBlock);
  inherited;
end; { TOmniBaseCollection.Destroy }

function TOmniBaseCollection.AllocateBlock: POmniTaggedValue;
var
  cached: POmniTaggedValue;
  pEOL  : POmniTaggedValue;
begin
  cached := obcCachedBlock;
  if assigned(cached) and CAS32(cached, nil, obcCachedBlock) then begin
    {$IFDEF DEBUG}NumReusedAlloc.Increment;{$ENDIF DEBUG}
    Result := cached;
    ZeroMemory(Result, CCollBlockSize {$IFDEF DEBUG} + 3*SizeOf(TOmniTaggedValue){$ENDIF});
  end
  else begin
    {$IFDEF DEBUG}NumTrueAlloc.Increment;{$ENDIF DEBUG}
    Result := AllocMem(CCollBlockSize {$IFDEF DEBUG} + 3*SizeOf(TOmniTaggedValue){$ENDIF});
  end;
  Assert(Ord(tagFree) = 0);
  {$IFDEF DEBUG}
  Assert(Result^.Tag = tagFree);
  Result^.Tag := tagSentinel;
  Inc(Result);
  Assert(Result^.Tag = tagFree);
  Result^.Tag := tagStartOfList;
  Inc(Result, CCollNumSlots + 1);
  Assert(Result^.Tag = tagFree);    
  Result^.Tag := tagSentinel;
  Dec(Result, CCollNumSlots);
  {$ENDIF}
  pEOL := Result;
  Inc(pEOL, CCollNumSlots - 1);
  {$IFDEF DEBUG} Assert(Result^.Tag = tagFree); {$ENDIF}
  pEOL^.tag := tagEndOfList;
end; { TOmniBaseCollection.AllocateBlock }

procedure TOmniBaseCollection.Enqueue(const value: TOmniValue);
var
  extension: POmniTaggedValue;
  tag      : TOmniCollectionTag;
  tail     : POmniTaggedValue;
begin
  EnterReader;
  repeat
    tail := obcTailPointer;
    tag := tail^.tag;
    if tag = tagFree then begin
      if tail^.CASTag(tag, tagAllocating) then
        break //repeat
      {$IFDEF DEBUG}else LoopEnqFree.Increment; {$ENDIF}
    end
    else if tag = tagEndOfList then begin
      if tail^.CASTag(tag, tagExtending) then
        break //repeat
      {$IFDEF DEBUG}else LoopEnqEOL.Increment; {$ENDIF}
    end
    else if tag = tagExtending then begin
      {$IFDEF DEBUG} LoopEnqExtending.Increment; {$ENDIF}
      DSIYield;
    end
    else begin
      {$IFDEF DEBUG} LoopEnqOther.Increment; {$ENDIF}
      asm pause; end;
    end;
  until false;
  {$IFDEF DEBUG} Assert(tail = ocTailPointer); {$ENDIF}
  if tag = tagFree then begin // enqueueing
    Inc(obcTailPointer); // release the lock
    tail^.Value := value; // this works because the slot was initialized to zero when allocating
    {$IFDEF DEBUG} tail^.Stuffing := GetCurrentThreadID AND $FFFF; {$ENDIF}
    {$IFNDEF DEBUG} tail^.Tag := tagAllocated; {$ELSE} Assert(tail^.CASTag(tagAllocating, tagAllocated)); {$ENDIF}
  end
  else begin // allocating memory
    {$IFDEF DEBUG} Assert(tag = tagEndOfList); {$ENDIF}
    extension := AllocateBlock;
    Inc(extension);             // skip allocated slot
    obcTailPointer := extension; // release the lock
    Dec(extension);
    {$IFDEF DEBUG} // create backlink
    Dec(extension);
    extension^.Value.AsPointer := tail;
    Inc(extension);
    {$ENDIF}
    {$IFNDEF DEBUG} extension^.Tag := tagAllocated; {$ELSE} Assert(extension^.CASTag(tagFree, tagAllocated)); {$ENDIF}
    extension^.Value := value;  // this works because the slot was initialized to zero when allocating
    tail^.Value := extension;
    {$IFNDEF DEBUG} tail^.Tag := tagBlockPointer; {$ELSE} Assert(tail^.CASTag(tagExtending, tagBlockPointer)); {$ENDIF DEBUG}
  end;
  LeaveReader;
end; { TOmniBaseCollection.Enqueue }

procedure TOmniBaseCollection.EnterReader;
var
  value: integer;
begin
  repeat
    value := obcRemoveCount.Value;
    if value >= 0 then
      if obcRemoveCount.CAS(value, value + 1) then
        break
    else 
      DSiYield; // let the GC do its work
  until false;
end; { TOmniBaseCollection.EnterReader }

procedure TOmniBaseCollection.EnterWriter;
begin
  while not ((obcRemoveCount.Value = 0) and (obcRemoveCount.CAS(0, -1))) do
    asm pause; end;
end; { TOmniBaseCollection.EnterWriter }

procedure TOmniBaseCollection.LeaveReader;
begin
  obcRemoveCount.Decrement;
end; { TOmniBaseCollection.LeaveReader }

procedure TOmniBaseCollection.LeaveWriter;
begin
  obcRemoveCount.Value := 0;
end; { TOmniBaseCollection.LeaveWriter }

procedure TOmniBaseCollection.ReleaseBlock(lastSlot: POmniTaggedValue; forceFree: boolean);
begin
  {$IFDEF DEBUG}
  Inc(lastSlot);
  Assert(lastSlot^.Tag = tagSentinel);
  Dec(lastSlot);
  {$ENDIF}
  Dec(lastSlot, CCollNumSlots - 1);
  {$IFDEF DEBUG}
  Dec(lastSlot);
  Assert(lastSlot^.Tag = tagStartOfList);
  Dec(lastSlot);
  Assert(lastSlot^.Tag = tagSentinel);
  {$ENDIF};
  if forceFree or assigned(obcCachedBlock) or (not CAS32(nil, lastSlot, obcCachedBlock)) then
    FreeMem(lastSlot);
end; { TOmniBaseCollection.ReleaseBlock }

function TOmniBaseCollection.TryDequeue(var value: TOmniValue): boolean;
var
  head: POmniTaggedValue;
  next: POmniTaggedValue;
  tag : TOmniCollectionTag;
begin
  Result := true;
  EnterReader;
  repeat
    head := obcHeadPointer;
    tag := head^.Tag;
    if tag = tagFree then begin
      Result := false;
      break; //repeat
    end
    else if tag = tagAllocated then begin
      if head^.CASTag(tag, tagRemoving) then
        break //repeat
      {$IFDEF DEBUG}else LoopDeqAllocated.Increment; {$ENDIF}
    end
    else if tag = tagBlockPointer then begin
      if head^.CASTag(tag, tagDestroying) then
        break //repeat
      {$IFDEF DEBUG}else LoopDeqAllocated.Increment; {$ENDIF}
    end
    else begin
      {$IFDEF DEBUG} LoopDeqOther.Increment; {$ENDIF}
      DSiYield;
    end;
  until false;
  if Result then begin // dequeueing
    if tag = tagAllocated then begin
      Inc(obcHeadPointer); // release the lock
      value := head^.Value;
      if value.IsInterface then begin
        head^.Value.AsInterface._Release;
        head^.Value.RawZero;
      end;
      {$IFNDEF DEBUG} head^.Tag := tagRemoved; {$ELSE} Assert(head^.CASTag(tagRemoving, tagRemoved)); {$ENDIF}
    end
    else begin // releasing memory
      {$IFDEF DEBUG} Assert(tag = tagBlockPointer); {$ENDIF}
      next := POmniTaggedValue(head^.Value.AsPointer);
      if next^.Tag <> tagAllocated then begin
        {$IFDEF DEBUG} Assert(next^.Tag = tagFree); {$ENDIF}
        obcHeadPointer := next; // release the lock
      end
      else begin
        Inc(next);
        obcHeadPointer := next; // release the lock
        Dec(next);
        value := next^.Value;
        if value.IsInterface then begin
          next^.Value.AsInterface._Release;
          next^.Value.RawZero;
        end;
        {$IFNDEF DEBUG} next^.Tag := tagRemoved; {$ELSE} Assert(next^.CASTag(tagAllocated, tagRemoved)); {$ENDIF DEBUG}
      end;
      // At this moment, another thread may still be dequeueing from one of the previous
      // slots and memory should not yet be released!
      LeaveReader;
      EnterWriter;
      ReleaseBlock(head);
      LeaveWriter;
      Exit;
    end;
  end;
  LeaveReader;
end; { TOmniBaseCollection.TryDequeue }

procedure TOmniBaseCollection.WaitForAllRemoved(const lastSlot: POmniTaggedValue);
var
  firstRemoving: POmniTaggedValue;
  scan         : POmniTaggedValue;
  sentinel     : POmniTaggedValue;
begin
  {$IFDEF Debug}
  Assert(assigned(lastSlot));
  Assert(lastSlot^.Tag in [tagEndOfList, tagDestroying]);
  {$ENDIF Debug}
  sentinel := lastSlot;
  Dec(sentinel, CCollNumSlots - 1);
  repeat
    firstRemoving := nil;
    scan := lastSlot;
    Dec(scan);
    repeat
      {$IFDEF DEBUG} Assert(scan^.Tag in [tagRemoving, tagRemoved]); {$ENDIF}
      if scan^.Tag = tagRemoving then
        firstRemoving := scan;
      if scan = sentinel then
        break;
      Dec(scan);
    until false;
    sentinel := firstRemoving;
    if assigned(firstRemoving) then
      asm pause; end
    else
      break; //repeat
  until false;
end; { TOmniBaseCollection.WaitForAllRemoved }

{ initialization }

procedure InitializeTimingInfo;
var
  queue: TOmniBaseQueue;
  stack: TOmniBaseStack;
begin
  stack := TOmniBaseStack.Create;
  stack.Initialize(10, 4); // enough for initialization
  FreeAndNil(stack);
  queue := TOmniBaseQueue.Create;
  queue.Initialize(10, 4); // enough for initialization
  FreeAndNil(queue);
end; { InitializeTimingInfo }

{ TOmniCollection }

constructor TOmniCollection.Create;
begin
  inherited Create;
  ocContainerSubject := TOmniContainerSubject.Create;
end; { TOmniCollection.Create }

destructor TOmniCollection.Destroy;
begin
  FreeAndNil(ocContainerSubject);
  inherited;
end; { TOmniCollection.Destroy }

function TOmniCollection.Dequeue: TOmniValue;
begin
  Result := inherited Dequeue;
  ContainerSubject.Notify(coiNotifyOnAllRemoves);
end; { TOmniCollection.Dequeue }

procedure TOmniCollection.Enqueue(const value: TOmniValue);
begin
  inherited Enqueue(value);
  ContainerSubject.Notify(coiNotifyOnAllInserts);
end; { TOmniCollection.Enqueue }

function TOmniCollection.TryDequeue(var value: TOmniValue): boolean;
begin
  Result := TryDequeue(value);
  if Result then
    ContainerSubject.Notify(coiNotifyOnAllRemoves);
end; { TOmniCollection.TryDequeue }

initialization
  Assert(SizeOf(TOmniValue) = 13);
  Assert(SizeOf(TOmniTaggedValue) = 16);
  Assert(SizeOf(pointer) = SizeOf(cardinal));
  Assert(CCollBlockSize = (65536 {$IFDEF DEBUG} - 3*SizeOf(TOmniTaggedValue){$ENDIF}));
  InitializeTimingInfo;
end.

