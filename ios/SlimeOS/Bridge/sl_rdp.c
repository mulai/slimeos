// FreeRDP session for the Swift app. Modelled on FreeRDP's Wayland client
// (client/Wayland/wlfreerdp.c): the connection and its event loop run on one
// thread; frames reach Swift through EndPaint; input is sent from the caller's
// thread (FreeRDP serialises writes to the transport).
#include "sl_rdp.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>

const uint16_t SL_PTR_MOVE = PTR_FLAGS_MOVE;
const uint16_t SL_PTR_BUTTON1 = PTR_FLAGS_BUTTON1;
const uint16_t SL_PTR_BUTTON2 = PTR_FLAGS_BUTTON2;
const uint16_t SL_PTR_DOWN = PTR_FLAGS_DOWN;
const uint16_t SL_PTR_WHEEL = PTR_FLAGS_WHEEL;
const uint16_t SL_PTR_WHEEL_NEGATIVE = PTR_FLAGS_WHEEL_NEGATIVE;

struct SLSession
{
	void* owner;
	sl_frame_cb on_frame;
	sl_state_cb on_state;
	rdpContext* context;
	pthread_t thread;
	bool thread_started;
	atomic_bool stop_requested; // the user closed it: not an error, no reconnect
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

static void send_frame(rdpContext* context, INT32 x, INT32 y, INT32 w, INT32 h)
{
	rdpGdi* gdi = context->gdi;
	SLSession* s = session_of(context);
	if (!gdi || !gdi->primary_buffer || !s->on_frame)
		return;
	s->on_frame(s->owner, gdi->primary_buffer, (int32_t)gdi->width, (int32_t)gdi->height,
	            (int32_t)gdi->stride, x, y, w, h);
}

static BOOL sl_end_paint(rdpContext* context)
{
	rdpGdi* gdi = context->gdi;
	if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
		return TRUE;
	HGDI_WND hwnd = gdi->primary->hdc->hwnd;
	if (!hwnd->invalid || hwnd->invalid->null)
		return TRUE;
	send_frame(context, hwnd->invalid->x, hwnd->invalid->y, hwnd->invalid->w, hwnd->invalid->h);
	hwnd->invalid->null = TRUE;
	hwnd->ninvalid = 0;
	return TRUE;
}

static BOOL sl_desktop_resize(rdpContext* context)
{
	rdpSettings* settings = context->settings;
	if (!gdi_resize(context->gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
	                freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight)))
		return FALSE;
	send_frame(context, 0, 0, (INT32)context->gdi->width, (INT32)context->gdi->height);
	return TRUE;
}

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

	s->on_state(s->owner, SL_STATE_CONNECTING, 0, 0);
	if (freerdp_connect(instance))
	{
		s->on_state(s->owner, SL_STATE_CONNECTED, 0, 0);
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
				if (!atomic_load(&s->stop_requested) && client_auto_reconnect_ex(instance, NULL))
					continue;
				break;
			}
		}
	}

	// After a stop the last error is just the abort (or whatever the abort
	// interrupted, e.g. ERRCONNECT_ACTIVATION_TIMEOUT): report a clean end.
	const bool stopped = atomic_load(&s->stop_requested);
	const uint32_t error = stopped ? 0 : freerdp_get_last_error(context);
	const uint32_t error_info = stopped ? 0 : freerdp_error_info(instance);
	freerdp_disconnect(instance);
	s->on_state(s->owner, SL_STATE_DISCONNECTED, error, error_info);
	return NULL;
}

SLSession* sl_session_new(void* owner, sl_frame_cb on_frame, sl_state_cb on_state)
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
	s->on_frame = on_frame;
	s->on_state = on_state;
	s->context = context;
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
	    freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, TRUE) &&
	    // Milestone 1 (LAN test): accept any certificate. The real app pins the
	    // first one it sees, like the Membrane's /cert:tofu.
	    freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, TRUE);
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
