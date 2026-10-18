// A small C API over FreeRDP for the Swift app: one RDP session on its own
// thread, callbacks for frames, the mouse pointer and state, and input calls.
#ifndef SL_RDP_H
#define SL_RDP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SLSession SLSession;

typedef enum
{
	SL_STATE_CONNECTING = 0,
	SL_STATE_CONNECTED = 1,
	SL_STATE_DISCONNECTED = 2, // ended; error says why (0 = cleanly)
	// The picture on screen is from before a drop or a graphics reset: FreeRDP
	// is reconnecting, or waiting for the server's first real frame after it.
	SL_STATE_RECONNECTING = 3,
} SLState;

// Reported as DISCONNECTED's error when the server's certificate isn't the one
// pinned on first use (the Brain was reinstalled, or isn't the same computer).
#define SL_ERROR_CERTIFICATE_CHANGED 0x5100C001u

// On the session thread, while FreeRDP holds the frame: copy what you need
// before returning. buffer is BGRA (B, G, R, A bytes), stride bytes per row;
// x/y/w/h is the part that changed.
typedef void (*sl_frame_cb)(void* owner, const uint8_t* buffer, int32_t width, int32_t height,
                            int32_t stride, int32_t x, int32_t y, int32_t w, int32_t h);
// error: FreeRDP's last error (freerdp_get_last_error) or SL_ERROR_* for
// DISCONNECTED, else 0; error_info: the server's ERRINFO code.
typedef void (*sl_state_cb)(void* owner, SLState state, uint32_t error, uint32_t error_info);
// The server's pointer image, BGRA, premultiplied alpha; copy before returning.
// pixels == NULL and width == 0: hidden. width == -1: the default arrow.
typedef void (*sl_pointer_cb)(void* owner, const uint8_t* pixels, int32_t width, int32_t height,
                              int32_t hot_x, int32_t hot_y);
// The server moved the pointer (desktop coordinates).
typedef void (*sl_pointer_pos_cb)(void* owner, int32_t x, int32_t y);

typedef struct
{
	const char* host;
	uint16_t port;
	const char* username;
	const char* password;
	const char* domain;
	uint32_t width;
	uint32_t height;
	// Where FreeRDP keeps its files, including the pinned certificates
	// (known_hosts); must exist and be writable.
	const char* config_dir;
} SLConnectParams;

typedef struct
{
	sl_frame_cb on_frame;
	sl_state_cb on_state;
	sl_pointer_cb on_pointer;
	sl_pointer_pos_cb on_pointer_pos;
} SLCallbacks;

SLSession* sl_session_new(void* owner, const SLCallbacks* callbacks);
// Starts the session thread; false if it couldn't be set up.
bool sl_session_start(SLSession* session, const SLConnectParams* params);
// Asks the session to end; on_state(DISCONNECTED, 0) follows from its thread.
void sl_session_stop(SLSession* session);
// Waits for the session thread, then frees everything.
void sl_session_free(SLSession* session);

// Desktop coordinates. flags: FreeRDP's PTR_FLAGS_* (see the constants below).
void sl_send_mouse(SLSession* session, uint16_t flags, uint16_t x, uint16_t y);
void sl_send_unicode(SLSession* session, uint16_t code_unit);
void sl_send_scancode(SLSession* session, uint32_t rdp_scancode, bool down);

extern const uint16_t SL_PTR_MOVE;
extern const uint16_t SL_PTR_BUTTON1; // left
extern const uint16_t SL_PTR_BUTTON2; // right
extern const uint16_t SL_PTR_DOWN;
extern const uint16_t SL_PTR_WHEEL;
extern const uint16_t SL_PTR_WHEEL_NEGATIVE;

#ifdef __cplusplus
}
#endif

#endif
