#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <os/log.h>
#include <string.h>

#include "runtime/core/metal_handles_ios.h"

// ---------- Workaround for LiteRT Metal GPU delegate crash on iOS.
//
// Two problems in the prebuilt libLiteRtMetalAccelerator.dylib:
//
// 1. ARC bridge lifetime (LiteRT issue #6745):
//    The delegate bridges MTLCommandQueue to void* for C++. ARC releases the
//    ObjC object; the void* dangles.
//
//    Fix: swizzle [MTLDevice newCommandQueue] (and the WithMax variant) to
//    return ONE shared, ARC-retained command queue instead of creating a new
//    one per caller. Three benefits:
//      a) The bridged void* is backed by a long-lived object — no dangle.
//      b) Matches the single queue we inject into the LiteRT Environment via
//         LiteRtAddEnvironmentOptions; every caller sees the same handle.
//      c) Prevents the iOS 200-queue kernel cap (IOGPUCommandQueue) from being
//         hit by vision runs, samplers, or other Metal components that call
//         newCommandQueue directly. Metal allows unlimited concurrent command
//         buffers per queue, so sharing is safe.
//
// 2. Nil buffer in blit during tensor init:
//    InitializeExternalSharedConstantTensors calls WriteDataToBuffer for
//    every constant tensor. Under extreme memory pressure (~4.8 GB model),
//    the DESTINATION tensor buffer allocation can fail silently (returns nil).
//    WriteDataToBuffer doesn't check for nil — it creates a staging buffer,
//    then calls copyFromBuffer:nil which crashes inside the Metal driver
//    at copyBufferToBuffer when extracting the IOGPUMetalResource from nil.
//
//    Fix: Swizzle the blit encoder's copyFromBuffer: to:
//    a) Use direct memcpy when both buffers have valid shared-memory contents
//       (avoids GPU resource issues and staging buffer overhead)
//    b) Skip the operation entirely when destination is nil (no crash, but
//       affected tensors will be uninitialized — better than EXC_BAD_ACCESS)
//    c) Skip when source is nil (same logic)
// ---------------------------------------------------------------------------

// ---------- ARC-retained handles ----------
static id<MTLDevice> g_device = nil;
static id<MTLCommandQueue> g_queue = nil;

// ---------- Original IMPs ----------
static IMP g_orig_newCommandQueue = NULL;
static IMP g_orig_newCommandQueueWithMax = NULL;
static IMP g_orig_copyFromBuffer = NULL;

// ---------- Command queue swizzles (problem 1) ----------
//
// Both swizzles return the shared g_queue so every caller reuses a single,
// ARC-retained MTLCommandQueue. During ensureInitialized(), g_queue is nil
// while we create the discovery queue / the queue itself — fall through to
// the original IMP in that bootstrap window.
//
// Ownership: newCommandQueue is in the `new` family and returns a +1
// reference. We CFRetain g_queue before returning so each caller's ARC
// release balances, keeping g_queue alive for the lifetime of the process.

static id swizzled_newCommandQueue(id self, SEL _cmd) {
  if (g_queue) {
    CFRetain((__bridge CFTypeRef)g_queue);
    return g_queue;
  }
  return ((id (*)(id, SEL))g_orig_newCommandQueue)(self, _cmd);
}

static id swizzled_newCommandQueueWithMax(id self, SEL _cmd, NSUInteger count) {
  if (g_queue) {
    CFRetain((__bridge CFTypeRef)g_queue);
    return g_queue;
  }
  return ((id (*)(id, SEL, NSUInteger))g_orig_newCommandQueueWithMax)(
      self, _cmd, count);
}

// ---------- Blit encoder swizzle (problem 2) ----------

static void swizzled_copyFromBuffer(id self, SEL _cmd,
                                    id sourceBuffer,
                                    NSUInteger sourceOffset,
                                    id destinationBuffer,
                                    NSUInteger destinationOffset,
                                    NSUInteger size) {
  // Guard: if either buffer is nil, the Metal driver will crash trying to
  // extract the IOGPUMetalResource from a nil object (deref at +0x68).
  // Skip the operation entirely — an uninitialized tensor is better than
  // a guaranteed EXC_BAD_ACCESS.
  if (!sourceBuffer || !destinationBuffer) {
    os_log_error(OS_LOG_DEFAULT,
                 "LiteRtLm: copyFromBuffer skipped: "
                 "src=%p dst=%p size=%lu — nil buffer would crash",
                 sourceBuffer, destinationBuffer, (unsigned long)size);
    return;
  }

  // On iOS (unified memory / StorageModeShared), both buffers have CPU-
  // accessible contents pointers. Use direct memcpy instead of GPU blit
  // to avoid crashes from broken GPU resource handles (IOGPUMetalResource
  // can be NULL even when the ObjC wrapper and CPU mapping are valid).
  void *srcContents = [sourceBuffer contents];
  void *dstContents = [destinationBuffer contents];

  if (srcContents && dstContents) {
    memcpy((char *)dstContents + destinationOffset,
           (const char *)srcContents + sourceOffset,
           size);
    return;
  }

  // One or both contents pointers are invalid. Try the original blit as a
  // last resort — it may work if the GPU resources are valid.
  os_log(OS_LOG_DEFAULT,
         "LiteRtLm: copyFromBuffer original path: "
         "srcContents=%p dstContents=%p size=%lu",
         srcContents, dstContents, (unsigned long)size);
  ((void (*)(id, SEL, id, NSUInteger, id, NSUInteger, NSUInteger))
       g_orig_copyFromBuffer)(self, _cmd, sourceBuffer, sourceOffset,
                              destinationBuffer, destinationOffset, size);
}

// ---------- Initialization ----------

static void ensureInitialized(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    g_device = MTLCreateSystemDefaultDevice();
    if (!g_device) {
      os_log_error(OS_LOG_DEFAULT,
                   "LiteRtLm: MTLCreateSystemDefaultDevice nil");
      return;
    }

    Class devCls = object_getClass(g_device);

    // --- Command queue swizzles ---
    Method m1 = class_getInstanceMethod(devCls, @selector(newCommandQueue));
    if (m1) {
      g_orig_newCommandQueue = method_getImplementation(m1);
      method_setImplementation(m1, (IMP)swizzled_newCommandQueue);
    }
    Method m2 = class_getInstanceMethod(
        devCls, @selector(newCommandQueueWithMaxCommandBufferCount:));
    if (m2) {
      g_orig_newCommandQueueWithMax = method_getImplementation(m2);
      method_setImplementation(m2, (IMP)swizzled_newCommandQueueWithMax);
    }

    // --- Blit encoder swizzle ---
    // Create a throwaway blit encoder to discover the concrete class.
    id<MTLCommandQueue> tmpQ = [g_device newCommandQueue];
    if (tmpQ) {
      id<MTLCommandBuffer> tmpCB = [tmpQ commandBuffer];
      if (tmpCB) {
        id<MTLBlitCommandEncoder> tmpEnc = [tmpCB blitCommandEncoder];
        if (tmpEnc) {
          Class blitCls = object_getClass(tmpEnc);
          Method m4 = class_getInstanceMethod(blitCls,
              @selector(copyFromBuffer:sourceOffset:toBuffer:
                            destinationOffset:size:));
          if (m4) {
            g_orig_copyFromBuffer = method_getImplementation(m4);
            method_setImplementation(m4, (IMP)swizzled_copyFromBuffer);
          }
          [tmpEnc endEncoding];
        }
      }
    }

    g_queue = [g_device newCommandQueue];

    os_log(OS_LOG_DEFAULT,
           "LiteRtLm: Metal device: %{public}s, "
           "swizzles: queue=%{public}s/%{public}s blit=%{public}s",
           [[g_device name] UTF8String],
           m1 ? "yes" : "no", m2 ? "yes" : "no",
           g_orig_copyFromBuffer ? "yes" : "no");
  });
}

void *LiteRtLmGetMetalDevice(void) {
  ensureInitialized();
  return g_device ? (__bridge void *)g_device : NULL;
}

void *LiteRtLmGetMetalCommandQueue(void) {
  ensureInitialized();
  return g_queue ? (__bridge void *)g_queue : NULL;
}
