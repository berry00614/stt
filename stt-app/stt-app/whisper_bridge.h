#ifndef WHISPER_BRIDGE_H
#define WHISPER_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

// Expose whisper.cpp C API to Swift
#include "whisper.h"

// MARK: - Callback Trampolines
//
// Swift closures cannot be used as C function pointers directly.
// These trampoline functions provide C-callable wrappers that forward
// to Swift-side callbacks via user_data pointers.

/// Trampoline for whisper_new_segment_callback.
/// user_data is expected to be a pointer to a struct containing the Swift callback context.
void whisper_segment_callback_trampoline(struct whisper_context * ctx,
                                         struct whisper_state * state,
                                         int n_new,
                                         void * user_data);

/// Trampoline for ggml_abort_callback (used as whisper's abort_callback).
/// user_data is expected to be a pointer to a volatile bool (the abort flag).
bool whisper_abort_callback_trampoline(void * user_data);

// MARK: - Atomic Helpers for Ring Buffer
//
// These thin wrappers around C11 atomics are used by the Swift AudioRingBuffer.
// Swift cannot call C11 atomic operations directly.

void ring_buffer_atomic_store(volatile int * addr, int value);
int  ring_buffer_atomic_load(const volatile int * addr);

#endif /* WHISPER_BRIDGE_H */
