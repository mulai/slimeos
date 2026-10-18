// FreeRDP session for the Swift app. Modelled on FreeRDP's Wayland client
// (client/Wayland/wlfreerdp.c): the connection and its event loop run on one
// thread; frames and the pointer reach Swift through callbacks from it; input
// is sent from the caller's thread (FreeRDP serialises writes to the transport).
#include "sl_rdp.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/codec/color.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>

const uint16_t SL_PTR_MOVE = PTR_FLAGS_MOVE;
const uint16_t SL_PTR_BUTTON1 = PTR_FLAGS_BUTTON1;
const uint16_t SL_PTR_BUTTON2 = PTR_FLAGS_BUTTON2;
const uint16_t SL_PTR_DOWN = PTR_FLAGS_DOWN;
const uint16_t SL_PTR_WHEEL = PTR_FLAGS_WHEEL;
const uint16_t SL_PTR_WHEEL_NEGATIVE = PTR_FLAGS_WHEEL_NEGATIVE;

// After a graphics reset Windows sends plain-black updates before its first
// real frame; they're held back (the old picture stays) for at most this long,
// so a desktop that really is black still shows. Same as the Android app's
// session-keep-last-frame.patch.
#define HOLD_BLACK_MAX_MS 10000

struct SLSession
{
	void* owner;
	SLCallbacks cb;
	rdpContext* context;
	pthread_t thread;
	bool thread_started;
	atomic_bool stop_requested; // the user closed it: not an error, no reconnect
	atomic_bool cert_changed;

	// Session thread only.
	SLState reported;
	bool has_picture;  // a frame went to Swift since the last size change
	bool reconnecting; // in client_auto_reconnect_ex
	bool holding;      // holding back black updates after a reset
	UINT64 hold_since;
	INT32 held_x0, held_y0, held_x1, held_y1; // held region; x1 <= x0: none
};

typedef struct
{
	rdpClientContext common;
	SLSession* session;
} slContext;

static SLSession* session_of(rdpContext* context)
{
	return ((slContext*)context)->session;
}

static void report(SLSession* s, SLState state, uint32_t error, uint32_t error_info)
{
	if (state == s->reported && state != SL_STATE_DISCONNECTED)
		return;
	s->reported = state;
	s->cb.on_state(s->owner, state, error, error_info);
}

static void update_state(SLSession* s)
{
	report(s, (s->reconnecting || s->holding) ? SL_STATE_RECONNECTING : SL_STATE_CONNECTED, 0, 0);
}

static void send_frame(rdpContext* context, INT32 x, INT32 y, INT32 w, INT32 h)
{
	rdpGdi* gdi = context->gdi;
	SLSession* s = session_of(context);
	if (!gdi || !gdi->primary_buffer || !s->cb.on_frame)
		return;
	s->has_picture = true;
	s->cb.on_frame(s->owner, gdi->primary_buffer, (int32_t)gdi->width, (int32_t)gdi->height,
	               (int32_t)gdi->stride, x, y, w, h);
}

// True if the region of the frame buffer looks plain black, sampled on a grid.
static bool looks_black(const rdpGdi* gdi, INT32 x, INT32 y, INT32 w, INT32 h)
{
	const INT32 steps = 24;
	for (INT32 i = 0; i < steps; i++)
	{
		const INT32 py = y + (h - 1) * i / (steps - 1);
		for (INT32 j = 0; j < steps; j++)
		{
			const INT32 px = x + (w - 1) * j / (steps - 1);
			const BYTE* p = gdi->primary_buffer + (size_t)py * gdi->stride + (size_t)px * 4;
			if (((p[0] | p[1] | p[2]) & 0xF0) != 0)
				return false;
		}
	}
	return true;
}

static BOOL sl_end_paint(rdpContext* context)
{
	rdpGdi* gdi = context->gdi;
	if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
		return TRUE;
	HGDI_WND hwnd = gdi->primary->hdc->hwnd;
	if (!hwnd->invalid || hwnd->invalid->null)
		return TRUE;

	SLSession* s = session_of(context);
	INT32 x0 = hwnd->invalid->x, y0 = hwnd->invalid->y;
	INT32 x1 = x0 + hwnd->invalid->w, y1 = y0 + hwnd->invalid->h;
	x0 = MAX(x0, 0);
	y0 = MAX(y0, 0);
	x1 = MIN(x1, (INT32)gdi->width);
	y1 = MIN(y1, (INT32)gdi->height);
	hwnd->invalid->null = TRUE;
	hwnd->ninvalid = 0;
	if (x1 <= x0 || y1 <= y0)
		return TRUE;

	if (s->holding)
	{
		if (s->held_x1 <= s->held_x0)
		{
			s->held_x0 = x0, s->held_y0 = y0, s->held_x1 = x1, s->held_y1 = y1;
		}
		else
		{
			s->held_x0 = MIN(s->held_x0, x0), s->held_y0 = MIN(s->held_y0, y0);
			s->held_x1 = MAX(s->held_x1, x1), s->held_y1 = MAX(s->held_y1, y1);
		}
		if (GetTickCount64() - s->hold_since < HOLD_BLACK_MAX_MS &&
		    looks_black(gdi, x0, y0, x1 - x0, y1 - y0))
			return TRUE;
		// Something real arrived: everything held goes out at once.
		x0 = s->held_x0, y0 = s->held_y0, x1 = s->held_x1, y1 = s->held_y1;
		s->holding = false;
		update_state(s);
	}
	send_frame(context, x0, y0, x1 - x0, y1 - y0);
	return TRUE;
}

static BOOL sl_desktop_resize(rdpContext* context)
{
	rdpSettings* settings = context->settings;
	SLSession* s = session_of(context);
	const UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
	const UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
	const bool same_size = context->gdi && (UINT32)context->gdi->width == w &&
	                       (UINT32)context->gdi->height == h;
	if (!gdi_resize(context->gdi, w, h))
		return FALSE;
	if (same_size && s->has_picture)
	{
		// A GFX reconnect resets graphics at the same size: keep the picture
		// on screen instead of sending the blank buffer.
		s->holding = true;
		s->hold_since = GetTickCount64();
		s->held_x0 = s->held_x1 = 0;
		update_state(s);
		return TRUE;
	}
	s->holding = false;
	send_frame(context, 0, 0, (INT32)context->gdi->width, (INT32)context->gdi->height);
	update_state(s);
	return TRUE;
}

// MARK: Pointer

static BOOL sl_pointer_new(rdpContext* context, rdpPointer* pointer)
{
	WINPR_UNUSED(context);
	WINPR_UNUSED(pointer);
	return TRUE; // converted when it's set
}

static void sl_pointer_free(rdpContext* context, rdpPointer* pointer)
{
	WINPR_UNUSED(context);
	WINPR_UNUSED(pointer);
}

static BOOL sl_pointer_set(rdpContext* context, rdpPointer* pointer)
{
	SLSession* s = session_of(context);
	if (!s->cb.on_pointer || !context->gdi || pointer->width == 0 || pointer->height == 0)
		return TRUE;
	const size_t stride = (size_t)pointer->width * 4;
	BYTE* pixels = calloc(pointer->height, stride);
	if (!pixels)
		return FALSE;
	if (freerdp_image_copy_from_pointer_data(pixels, PIXEL_FORMAT_BGRA32, (UINT32)stride, 0, 0,
	                                         pointer->width, pointer->height, pointer->xorMaskData,
	                                         pointer->lengthXorMask, pointer->andMaskData,
	                                         pointer->lengthAndMask, pointer->xorBpp,
	                                         &context->gdi->palette))
	{
		// Core Graphics wants premultiplied alpha.
		for (size_t i = 0; i < stride * pointer->height; i += 4)
		{
			const unsigned a = pixels[i + 3];
			pixels[i] = (BYTE)(pixels[i] * a / 255);
			pixels[i + 1] = (BYTE)(pixels[i + 1] * a / 255);
			pixels[i + 2] = (BYTE)(pixels[i + 2] * a / 255);
		}
		s->cb.on_pointer(s->owner, pixels, (int32_t)pointer->width, (int32_t)pointer->height,
		                 (int32_t)pointer->xPos, (int32_t)pointer->yPos);
	}
	free(pixels);
	return TRUE;
}

static BOOL sl_pointer_set_null(rdpContext* context)
{
	SLSession* s = session_of(context);
	if (s->cb.on_pointer)
		s->cb.on_pointer(s->owner, NULL, 0, 0, 0, 0);
	return TRUE;
}

static BOOL sl_pointer_set_default(rdpContext* context)
{
	SLSession* s = session_of(context);
	if (s->cb.on_pointer)
		s->cb.on_pointer(s->owner, NULL, -1, 0, 0, 0);
	return TRUE;
}

static BOOL sl_pointer_set_position(rdpContext* context, UINT32 x, UINT32 y)
{
	SLSession* s = session_of(context);
	if (s->cb.on_pointer_pos)
		s->cb.on_pointer_pos(s->owner, (int32_t)x, (int32_t)y);
	return TRUE;
}

// MARK: Certificates: trust on first use, like the Membrane's /cert:tofu.
// FreeRDP keeps what was accepted in known_hosts under FreeRDP_ConfigPath.

static DWORD sl_verify_certificate(freerdp* instance, const char* host, UINT16 port,
                                   const char* common_name, const char* subject,
                                   const char* issuer, const char* fingerprint, DWORD flags)
{
	WINPR_UNUSED(instance);
	WINPR_UNUSED(host);
	WINPR_UNUSED(port);
	WINPR_UNUSED(common_name);
	WINPR_UNUSED(subject);
	WINPR_UNUSED(issuer);
	WINPR_UNUSED(fingerprint);
	WINPR_UNUSED(flags);
	return 1; // first time: accept and remember
}

static DWORD sl_verify_changed_certificate(freerdp* instance, const char* host, UINT16 port,
                                           const char* common_name, const char* subject,
                                           const char* issuer, const char* new_fingerprint,
                                           const char* old_subject, const char* old_issuer,
                                           const char* old_fingerprint, DWORD flags)
{
	WINPR_UNUSED(host);
	WINPR_UNUSED(port);
	WINPR_UNUSED(common_name);
	WINPR_UNUSED(subject);
	WINPR_UNUSED(issuer);
	WINPR_UNUSED(new_fingerprint);
	WINPR_UNUSED(old_subject);
	WINPR_UNUSED(old_issuer);
	WINPR_UNUSED(old_fingerprint);
	WINPR_UNUSED(flags);
	atomic_store(&session_of(instance->context)->cert_changed, true);
	return 0; // a different computer answered at this address: refuse
}

// MARK: Connection

static BOOL sl_pre_connect(freerdp* instance)
{
	rdpSettings* settings = instance->context->settings;
	if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_IOS))
		return FALSE;
	if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_UNSPECIFIED))
		return FALSE;
	// The common handlers wire up the graphics pipeline (rdpgfx) and friends.
	if (PubSub_SubscribeChannelConnected(instance->context->pubSub,
	                                     freerdp_client_OnChannelConnectedEventHandler) < 0)
		return FALSE;
	if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub,
	                                        freerdp_client_OnChannelDisconnectedEventHandler) < 0)
		return FALSE;
	return TRUE;
}

static BOOL sl_post_connect(freerdp* instance)
{
	if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
		return FALSE;
	rdpPointer pointer = { 0 };
	pointer.size = sizeof(pointer);
	pointer.New = sl_pointer_new;
	pointer.Free = sl_pointer_free;
	pointer.Set = sl_pointer_set;
	pointer.SetNull = sl_pointer_set_null;
	pointer.SetDefault = sl_pointer_set_default;
	pointer.SetPosition = sl_pointer_set_position;
	graphics_register_pointer(instance->context->graphics, &pointer);
	instance->context->update->EndPaint = sl_end_paint;
	instance->context->update->DesktopResize = sl_desktop_resize;
	return TRUE;
}

static void sl_post_disconnect(freerdp* instance)
{
	gdi_free(instance);
}

static BOOL sl_client_new(freerdp* instance, rdpContext* context)
{
	WINPR_UNUSED(context);
	instance->PreConnect = sl_pre_connect;
	instance->PostConnect = sl_post_connect;
	instance->PostDisconnect = sl_post_disconnect;
	instance->VerifyCertificateEx = sl_verify_certificate;
	instance->VerifyChangedCertificateEx = sl_verify_changed_certificate;
	return TRUE;
}

static int sl_client_start(rdpContext* context)
{
	WINPR_UNUSED(context);
	return 0;
}

static void* session_thread(void* arg)
{
	SLSession* s = arg;
	rdpContext* context = s->context;
	freerdp* instance = context->instance;

	report(s, SL_STATE_CONNECTING, 0, 0);
	if (freerdp_connect(instance))
	{
		update_state(s);
		HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
		while (!freerdp_shall_disconnect_context(context))
		{
			DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
			if (count == 0)
				break;
			if (WaitForMultipleObjects(count, handles, FALSE, 250) == WAIT_FAILED)
				break;
			if (atomic_load(&s->stop_requested))
				break;
			if (!freerdp_check_event_handles(context))
			{
				if (atomic_load(&s->stop_requested))
					break;
				s->reconnecting = true;
				update_state(s);
				const BOOL back = client_auto_reconnect_ex(instance, NULL);
				s->reconnecting = false;
				if (!back)
					break;
				update_state(s);
			}
		}
	}

	// After a stop the last error is just the abort (or whatever the abort
	// interrupted, e.g. ERRCONNECT_ACTIVATION_TIMEOUT): report a clean end.
	const bool stopped = atomic_load(&s->stop_requested);
	uint32_t error = stopped ? 0 : freerdp_get_last_error(context);
	const uint32_t error_info = stopped ? 0 : freerdp_error_info(instance);
	if (!stopped && atomic_load(&s->cert_changed))
		error = SL_ERROR_CERTIFICATE_CHANGED;
	freerdp_disconnect(instance);
	report(s, SL_STATE_DISCONNECTED, error, error_info);
	return NULL;
}

SLSession* sl_session_new(void* owner, const SLCallbacks* callbacks)
{
	RDP_CLIENT_ENTRY_POINTS entry = { 0 };
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry.ContextSize = sizeof(slContext);
	entry.ClientNew = sl_client_new;
	entry.ClientStart = sl_client_start;
	entry.ClientStop = freerdp_client_common_stop;

	rdpContext* context = freerdp_client_context_new(&entry);
	if (!context)
		return NULL;
	SLSession* s = calloc(1, sizeof(SLSession));
	if (!s)
	{
		freerdp_client_context_free(context);
		return NULL;
	}
	s->owner = owner;
	s->cb = *callbacks;
	s->context = context;
	s->reported = (SLState)-1;
	((slContext*)context)->session = s;
	return s;
}

bool sl_session_start(SLSession* s, const SLConnectParams* p)
{
	rdpSettings* settings = s->context->settings;
	const bool ok =
	    freerdp_settings_set_string(settings, FreeRDP_ServerHostname, p->host) &&
	    freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, p->port ? p->port : 3389) &&
	    freerdp_settings_set_string(settings, FreeRDP_Username, p->username) &&
	    freerdp_settings_set_string(settings, FreeRDP_Password, p->password) &&
	    (!p->domain || !*p->domain ||
	     freerdp_settings_set_string(settings, FreeRDP_Domain, p->domain)) &&
	    freerdp_settings_set_string(settings, FreeRDP_ConfigPath, p->config_dir) &&
	    freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, p->width) &&
	    freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, p->height) &&
	    freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
	    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
	    freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE) &&
	    freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, TRUE) &&
	    freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE) &&
	    freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, TRUE) &&
	    freerdp_set_connection_type(settings, CONNECTION_TYPE_AUTODETECT) &&
	    freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, TRUE) &&
	    freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, TRUE);
	if (!ok)
		return false;
	if (freerdp_client_start(s->context) != 0)
		return false;
	if (pthread_create(&s->thread, NULL, session_thread, s) != 0)
		return false;
	s->thread_started = true;
	return true;
}

void sl_session_stop(SLSession* s)
{
	if (!s || !s->context)
		return;
	atomic_store(&s->stop_requested, true);
	freerdp_abort_connect_context(s->context);
}

void sl_session_free(SLSession* s)
{
	if (!s)
		return;
	sl_session_stop(s);
	if (s->thread_started)
		pthread_join(s->thread, NULL);
	freerdp_client_stop(s->context);
	freerdp_client_context_free(s->context);
	free(s);
}

void sl_send_mouse(SLSession* s, uint16_t flags, uint16_t x, uint16_t y)
{
	if (s && s->context && s->context->input)
		freerdp_input_send_mouse_event(s->context->input, flags, x, y);
}

void sl_send_unicode(SLSession* s, uint16_t code_unit)
{
	if (!s || !s->context || !s->context->input)
		return;
	freerdp_input_send_unicode_keyboard_event(s->context->input, 0, code_unit);
	freerdp_input_send_unicode_keyboard_event(s->context->input, KBD_FLAGS_RELEASE, code_unit);
}

void sl_send_scancode(SLSession* s, uint32_t rdp_scancode, bool down)
{
	if (s && s->context && s->context->input)
		freerdp_input_send_keyboard_event_ex(s->context->input, down, FALSE, rdp_scancode);
}
