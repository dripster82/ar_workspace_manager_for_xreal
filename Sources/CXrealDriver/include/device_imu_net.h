#pragma once
//
// XREAL One / One Pro IMU over USB-ethernet (CDC-ECM) TCP transport.
//
// Unlike the Air series (whose IMU is a 64-byte HID report stream — see device_imu.{h,c}), the
// XREAL One series exposes head-tracking IMU as a TCP service on the glasses' built-in USB-ethernet
// link. The glasses appear as a link-local network peer (default 169.254.2.1) and stream fixed-size
// frames at ~1 kHz on port 52998. This module discovers that peer, parses the raw gyro/accelerometer
// out of each frame, and runs the SAME xioTechnologies Fusion AHRS used by the Air path, exposing
// the result through the identical device_imu_event_callback + device_imu_get_orientation() API so
// every downstream consumer (pose smoothing, prediction, drift correction, rendering) is reused
// unchanged.
//
// Requires "Ethernet" to be enabled in the glasses' developer/side menu (it is on by default on
// recent firmware). Verified against XREAL One Pro (USB 0x3318:0x0436).
//

#ifndef __cplusplus
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#else
#include <cstdint>
#include <cstddef>
#endif

// Shared error / event / quaternion types and device_imu_get_orientation() live in device_imu.h.
#include "device_imu.h"

#ifdef __cplusplus
extern "C"
{
#endif

#define DEVICE_IMU_NET_PORT 52998
#define DEVICE_IMU_NET_RECV_BUFFER 16384

	struct device_imu_net_t
	{
		uint16_t vendor_id;
		uint16_t product_id;

		int fd; // connected TCP socket, or -1
		char server_ip[64];

		uint64_t last_timestamp; // device timestamp (ns) of the previous frame
		bool have_last_timestamp;
		float temperature; // (in °C), best-effort

		void *ahrs;	  // FusionAhrs*
		void *offset; // FusionOffset* (continuous gyro-bias tracking, as on the Air path)

		device_imu_event_callback callback;

		// Heap-allocated recv accumulator (kept off the struct so the Swift-imported type stays
		// small — an inline array would import as a giant tuple).
		uint8_t *buf;
		size_t buf_len;
	};

	typedef struct device_imu_net_t device_imu_net_type;

	// True if XREAL glasses are plugged in AND a One-series IMU TCP server answers. Cheap-ish
	// (does a short connect probe); used to decide whether to take the network path.
	bool device_imu_net_available(void);

	device_imu_error_type device_imu_net_open(device_imu_net_type *device, device_imu_event_callback callback);

	// Polls the socket up to `timeout` ms, then decodes every complete frame received and fires the
	// callback once per frame (mirrors device_imu_read's contract).
	device_imu_error_type device_imu_net_read(device_imu_net_type *device, int timeout);

	device_imu_error_type device_imu_net_close(device_imu_net_type *device);

#ifdef __cplusplus
} // extern "C"
#endif
