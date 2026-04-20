#ifndef LITERT_LM_RUNTIME_CORE_METAL_HANDLES_IOS_H_
#define LITERT_LM_RUNTIME_CORE_METAL_HANDLES_IOS_H_

#ifdef __cplusplus
extern "C" {
#endif

// Returns a retained MTLDevice, or NULL if Metal is unavailable.
void* LiteRtLmGetMetalDevice(void);
// Returns a retained MTLCommandQueue, or NULL if Metal is unavailable.
void* LiteRtLmGetMetalCommandQueue(void);

#ifdef __cplusplus
}
#endif

#endif  // LITERT_LM_RUNTIME_CORE_METAL_HANDLES_IOS_H_
