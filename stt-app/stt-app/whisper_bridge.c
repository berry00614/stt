#include "whisper_bridge.h"
#include <stdatomic.h>

// MARK: - Segment Callback Trampoline

void whisper_segment_callback_trampoline(struct whisper_context * ctx,
                                         struct whisper_state * state,
                                         int n_new,
                                         void * user_data) {
    // user_data is cast to the appropriate callback type + context.
    // The actual dispatch is handled by the callback stored at user_data.
    if (user_data == NULL) return;

    // The user_data pointer points to a struct:
    //   struct { void * callback; void * context; }
    // where callback is a function pointer matching the signature.
    void ** data = (void **)user_data;
    whisper_new_segment_callback cb = (whisper_new_segment_callback)(data[0]);
    void * cb_ctx = data[1];
    if (cb) {
        cb(ctx, state, n_new, cb_ctx);
    }
}

// MARK: - Abort Callback Trampoline

bool whisper_abort_callback_trampoline(void * user_data) {
    if (user_data == NULL) return false;
    // user_data points to a volatile bool (the abort flag).
    // Use atomic load so the WhisperEngine actor can set it from another thread.
    return ring_buffer_atomic_load((const volatile int *)user_data) != 0;
}

// MARK: - Atomic Helpers

void ring_buffer_atomic_store(volatile int * addr, int value) {
    atomic_store_explicit((_Atomic int *)addr, value, memory_order_release);
}

int ring_buffer_atomic_load(const volatile int * addr) {
    return atomic_load_explicit((_Atomic int *)addr, memory_order_acquire);
}
