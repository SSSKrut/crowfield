#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

#include "gdextension_interface.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

namespace {
constexpr char trace_path_env[] = "CROWFIELD_NATIVE_INPUT_PATH";
constexpr char gameplay_env[] = "CROWFIELD_NATIVE_INPUT_GAMEPLAY";
constexpr size_t buffer_size = 16 * 1024;

FILE *trace_file = nullptr;
id monitor = nil;
NSTimer *flush_timer = nil;
char pending[buffer_size];
size_t pending_size = 0;
unsigned dropped = 0;

long long usec(NSTimeInterval seconds) {
	return std::llround(seconds * 1000000.0);
}

long long uptime_usec() {
	return usec(NSProcessInfo.processInfo.systemUptime);
}

const char *action_for_key(unsigned short key) {
	switch (key) {
		case kVK_ANSI_W: return "move_forward";
		case kVK_ANSI_S: return "move_back";
		case kVK_ANSI_A: return "move_left";
		case kVK_ANSI_D: return "move_right";
		default: return nullptr;
	}
}

void flush_trace() {
	if (!trace_file) {
		return;
	}
	if (pending_size > 0) {
		std::fwrite(pending, 1, pending_size, trace_file);
		pending_size = 0;
	}
	if (dropped > 0) {
		std::fprintf(trace_file,
				"{\"type\":\"native_records_dropped\",\"count\":%u,\"uptime_usec\":%lld}\n",
				dropped, uptime_usec());
		dropped = 0;
	}
	std::fflush(trace_file);
}

bool is_active_game_window(NSEvent *event) {
	NSWindow *key_window = NSApp.keyWindow;
	return NSApp.isActive && key_window && (!event.window || event.window == key_window);
}

NSEvent *observe(NSEvent *event, bool in_game_window) {
	if (!trace_file || !in_game_window) {
		return event;
	}
	const char *action = action_for_key(event.keyCode);
	const char *gameplay = std::getenv(gameplay_env);
	if (!action || !gameplay || std::strcmp(gameplay, "1") != 0) {
		return event;
	}
	const long long received = uptime_usec();
	const long long occurred = usec(event.timestamp);
	char line[256];
	const int count = std::snprintf(line, sizeof(line),
			"{\"type\":\"native_movement_key\",\"action\":\"%s\",\"pressed\":%s,\"repeat\":%s,"
			"\"event_uptime_usec\":%lld,\"received_uptime_usec\":%lld,\"age_usec\":%lld}\n",
			action, event.type == NSEventTypeKeyDown ? "true" : "false", event.isARepeat ? "true" : "false",
			occurred, received, received - occurred);
	if (count > 0 && static_cast<size_t>(count) < sizeof(line) &&
			pending_size + static_cast<size_t>(count) <= sizeof(pending)) {
		std::memcpy(pending + pending_size, line, count);
		pending_size += count;
	} else {
		++dropped;
	}
	// A local monitor sees only events delivered to this process. Returning
	// the original event preserves AppKit and Godot input handling.
	return event;
}

void initialize(void *, GDExtensionInitializationLevel level) {
	if (level != GDEXTENSION_INITIALIZATION_SCENE) {
		return;
	}
	@autoreleasepool {
		const char *path = std::getenv(trace_path_env);
		if (!path || !path[0] || !NSThread.isMainThread) {
			return;
		}
		const int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
		if (fd < 0) {
			return;
		}
		trace_file = fdopen(fd, "w");
		if (!trace_file) {
			close(fd);
			return;
		}
		if (NSApp) {
			monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp
														 handler:^NSEvent *(NSEvent *event) {
				return observe(event, is_active_game_window(event));
			}];
		}
		const long long monotonic = uptime_usec();
		const long long wall = usec(NSDate.date.timeIntervalSince1970);
		std::fprintf(trace_file,
				"{\"type\":\"native_start\",\"wall_unix_usec\":%lld,\"uptime_usec\":%lld,\"status\":\"%s\"}\n",
				wall, monotonic, monitor ? "active" : (NSApp ? "monitor_unavailable" : "no_appkit"));
		flush_trace();
		if (monitor) {
			flush_timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *) {
				flush_trace();
			}];
			[NSRunLoop.mainRunLoop addTimer:flush_timer forMode:NSRunLoopCommonModes];
		}
	}
}

void deinitialize(void *, GDExtensionInitializationLevel level) {
	if (level != GDEXTENSION_INITIALIZATION_SCENE || !trace_file) {
		return;
	}
	@autoreleasepool {
		[flush_timer invalidate];
		flush_timer = nil;
		if (monitor) {
			[NSEvent removeMonitor:monitor];
			monitor = nil;
		}
		flush_trace();
		std::fprintf(trace_file, "{\"type\":\"native_end\",\"uptime_usec\":%lld}\n", uptime_usec());
		std::fclose(trace_file);
		trace_file = nullptr;
	}
}
} // namespace

extern "C" GDExtensionBool crowfield_native_input_init(
		GDExtensionInterfaceGetProcAddress, GDExtensionClassLibraryPtr, GDExtensionInitialization *init) {
	init->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	init->userdata = nullptr;
	init->initialize = initialize;
	init->deinitialize = deinitialize;
	return true;
}
