//
// XREAL One / One Pro IMU over USB-ethernet (CDC-ECM) TCP transport.
// See device_imu_net.h for the high-level description.
//

#include "device_imu_net.h"
#include "device_imu.h"
#include "hid_ids.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>

#include <libkern/OSByteOrder.h>

#include <Fusion/Fusion.h>

#ifndef NDEBUG
#define net_imu_log(...) fprintf(stderr, "device_imu_net: " __VA_ARGS__)
#else
#define net_imu_log(...) ((void)0)
#endif

// --- Wire format -------------------------------------------------------------------------------
// Fixed-size frames, header-delimited, ~1 kHz. Confirmed by live capture from XREAL One Pro and by
// two independent community drivers (SamiMitwalli/One-Pro-IMU-Retriever-Demo, rohitsangwan01/
// xreal_one_driver). Layout (offsets from the start of the header):
//   [0]  6-byte header           28 36 00 00 00 80
//   [14] uint64 timestamp (ns, little-endian)
//   [34] float32[3] gyroscope    (little-endian)
//   [46] float32[3] accelerometer in m/s^2 (little-endian; |a| ~= 9.81 at rest)
//   [70] float32   temperature   (best-effort)
//   ...  trailer / device-internal fields we don't use
#define ONE_FRAME_LEN 134
#define ONE_TS_OFFSET 14
#define ONE_GYRO_OFFSET 34
#define ONE_ACCEL_OFFSET 46
#define ONE_TEMP_OFFSET 70

static const uint8_t ONE_HEADER[6] = {0x28, 0x36, 0x00, 0x00, 0x00, 0x80};

#define GRAVITY_MS2 9.806f
#define SAMPLE_RATE 1000

// --- Sensor -> Fusion-frame mapping ------------------------------------------------------------
// The Fusion AHRS is fed in the SAME body frame the Air path produces, so the Swift remap in
// IMUService.handleUpdate (which converts Fusion output -> render world) is reused verbatim. That
// frame is: X = forward (roll axis), Y = lateral/ear axis (pitch axis), Z = vertical (yaw axis).
//
// The One Pro IMU labels its raw axes (per the community drivers) as gx=pitch-rate, gy=yaw-rate,
// gz=roll-rate, i.e. raw index 0 = lateral axis, 1 = vertical axis, 2 = forward axis. Mapping into
// the Fusion frame above therefore defaults to: FusionX<-raw2, FusionY<-raw0, FusionZ<-raw1.
//
// Axis PERMUTATION is derived; the SIGNS (and the gyro unit scale) are confirmed against real
// hardware during bring-up. To make that bring-up fast WITHOUT recompiling, the map and scale can
// be overridden at launch via environment variables:
//   ARWM_ONE_GYRO_MAP / ARWM_ONE_ACCEL_MAP = "i s,i s,i s" e.g. "2+,0+,1-"  (i in 0..2, s in +/-)
//   ARWM_ONE_GYRO_SCALE = float        (raw-gyro -> degrees/second; default assumes raw is rad/s)
// Once the correct values are confirmed they become the compiled-in defaults below.
typedef struct
{
	int src[3];	  // for Fusion axis k, which raw index to read
	float sign[3]; // and its sign
} axis_map;

static axis_map g_gyro_map = {{2, 0, 1}, {+1.0f, +1.0f, +1.0f}};
static axis_map g_accel_map = {{2, 0, 1}, {+1.0f, +1.0f, +1.0f}};
static float g_gyro_scale = 57.29578f; // rad/s -> deg/s (Fusion wants deg/s); verified on hardware
static bool g_map_loaded = false;

static void parse_map_env(const char *name, axis_map *out)
{
	const char *v = getenv(name);
	if (!v)
		return;
	axis_map m = *out;
	int k = 0;
	const char *p = v;
	while (*p && k < 3)
	{
		while (*p == ' ' || *p == ',')
			p++;
		if (*p < '0' || *p > '2')
			break;
		m.src[k] = *p - '0';
		p++;
		if (*p == '-')
			m.sign[k] = -1.0f;
		else
			m.sign[k] = +1.0f;
		if (*p == '+' || *p == '-')
			p++;
		k++;
	}
	if (k == 3)
	{
		*out = m;
		net_imu_log("%s = [%d%c,%d%c,%d%c]\n", name,
					m.src[0], m.sign[0] < 0 ? '-' : '+',
					m.src[1], m.sign[1] < 0 ? '-' : '+',
					m.src[2], m.sign[2] < 0 ? '-' : '+');
	}
}

static void load_maps_once(void)
{
	if (g_map_loaded)
		return;
	g_map_loaded = true;
	parse_map_env("ARWM_ONE_GYRO_MAP", &g_gyro_map);
	parse_map_env("ARWM_ONE_ACCEL_MAP", &g_accel_map);
	const char *s = getenv("ARWM_ONE_GYRO_SCALE");
	if (s)
	{
		float f = (float)atof(s);
		if (f != 0.0f)
		{
			g_gyro_scale = f;
			net_imu_log("ARWM_ONE_GYRO_SCALE = %f\n", g_gyro_scale);
		}
	}
}

static FusionVector apply_map(const axis_map *m, const float raw[3], float scale)
{
	FusionVector v;
	for (int k = 0; k < 3; k++)
		v.array[k] = raw[m->src[k]] * m->sign[k] * scale;
	return v;
}

// --- Little-endian readers (frame fields are little-endian; host is LE on Apple Silicon) -------
static float read_le_f32(const uint8_t *p)
{
	uint32_t u;
	memcpy(&u, p, 4);
	u = OSSwapLittleToHostInt32(u);
	float f;
	memcpy(&f, &u, 4);
	return f;
}

static uint64_t read_le_u64(const uint8_t *p)
{
	uint64_t u;
	memcpy(&u, p, 8);
	return OSSwapLittleToHostInt64(u);
}

// --- Connection ---------------------------------------------------------------------------------
static int connect_timeout(const char *ip, int port, int ms)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;

	int flags = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, flags | O_NONBLOCK);

	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);
	if (inet_pton(AF_INET, ip, &sa.sin_addr) != 1)
	{
		close(fd);
		return -1;
	}

	int r = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
	if (r != 0)
	{
		if (errno != EINPROGRESS)
		{
			close(fd);
			return -1;
		}
		struct pollfd pfd = {fd, POLLOUT, 0};
		r = poll(&pfd, 1, ms);
		if (r <= 0)
		{
			close(fd);
			return -1;
		}
		int err = 0;
		socklen_t el = sizeof(err);
		if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) != 0 || err != 0)
		{
			close(fd);
			return -1;
		}
	}

	fcntl(fd, F_SETFL, flags); // back to blocking
	int one = 1;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)); // low latency for ~1 kHz stream
	return fd;
}

// Build the list of candidate glasses IP addresses. Prefer peers derived from this machine's
// link-local (169.254/16) interfaces — each XREAL CDC-ECM link puts us on a /24 with the glasses at
// .1 — then fall back to the documented defaults. Robust to whichever en* the OS assigns.
static int collect_candidates(char out[][64], int max)
{
	int n = 0;
	struct ifaddrs *ifap = NULL;
	if (getifaddrs(&ifap) == 0)
	{
		for (struct ifaddrs *ifa = ifap; ifa && n < max; ifa = ifa->ifa_next)
		{
			if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
				continue;
			if (!(ifa->ifa_flags & IFF_UP) || !(ifa->ifa_flags & IFF_RUNNING) || (ifa->ifa_flags & IFF_LOOPBACK))
				continue;
			uint32_t ip = ntohl(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr);
			if ((ip & 0xFFFF0000u) != 0xA9FE0000u) // 169.254/16
				continue;
			uint32_t peer = (ip & 0xFFFFFF00u) | 0x01u; // .1 of our /24
			if (peer == ip)
				continue;
			struct in_addr a;
			a.s_addr = htonl(peer);
			char s[64];
			if (!inet_ntop(AF_INET, &a, s, sizeof(s)))
				continue;
			bool dup = false;
			for (int k = 0; k < n; k++)
				if (strcmp(out[k], s) == 0)
					dup = true;
			if (!dup)
			{
				strncpy(out[n], s, 63);
				out[n][63] = '\0';
				n++;
			}
		}
		freeifaddrs(ifap);
	}

	static const char *defaults[] = {"169.254.2.1", "169.254.1.1"};
	for (int i = 0; i < 2 && n < max; i++)
	{
		bool dup = false;
		for (int k = 0; k < n; k++)
			if (strcmp(out[k], defaults[i]) == 0)
				dup = true;
		if (!dup)
		{
			strncpy(out[n], defaults[i], 63);
			out[n][63] = '\0';
			n++;
		}
	}
	return n;
}

bool device_imu_net_available(void)
{
	// Only probe the network if XREAL glasses are actually plugged in — never connect to a
	// coincidental 169.254.x.1 host on some unrelated link-local network.
	if (!xreal_any_connected(NULL))
		return false;

	char cand[8][64];
	int n = collect_candidates(cand, 8);
	for (int i = 0; i < n; i++)
	{
		int fd = connect_timeout(cand[i], DEVICE_IMU_NET_PORT, 300);
		if (fd >= 0)
		{
			close(fd);
			return true;
		}
	}
	return false;
}

device_imu_error_type device_imu_net_open(device_imu_net_type *device, device_imu_event_callback callback)
{
	if (!device)
		return DEVICE_IMU_ERROR_NO_DEVICE;

	memset(device, 0, sizeof(device_imu_net_type));
	device->fd = -1;
	device->vendor_id = xreal_vendor_id;
	device->callback = callback;

	load_maps_once();

	uint16_t pid = 0;
	if (!xreal_any_connected(&pid))
		return DEVICE_IMU_ERROR_NO_DEVICE; // no XREAL plugged in
	device->product_id = pid;

	char cand[8][64];
	int n = collect_candidates(cand, 8);
	for (int i = 0; i < n && device->fd < 0; i++)
	{
		int fd = connect_timeout(cand[i], DEVICE_IMU_NET_PORT, 700);
		if (fd >= 0)
		{
			device->fd = fd;
			strncpy(device->server_ip, cand[i], sizeof(device->server_ip) - 1);
			net_imu_log("connected to %s:%d (pid 0x%04x)\n", device->server_ip, DEVICE_IMU_NET_PORT, pid);
		}
	}

	if (device->fd < 0)
		return DEVICE_IMU_ERROR_NO_HANDLE;

	device->ahrs = malloc(sizeof(FusionAhrs));
	device->offset = malloc(sizeof(FusionOffset));
	device->buf = malloc(DEVICE_IMU_NET_RECV_BUFFER);
	device->buf_len = 0;
	if (!device->ahrs || !device->offset || !device->buf)
	{
		device_imu_net_close(device);
		return DEVICE_IMU_ERROR_NO_ALLOCATION;
	}

	FusionOffsetInitialise((FusionOffset *)device->offset, SAMPLE_RATE);
	FusionAhrsInitialise((FusionAhrs *)device->ahrs);

	// Same fusion settings as the Air path (device_imu.c) for identical downstream behaviour.
	const FusionAhrsSettings settings = {
		.convention = FusionConventionNed,
		.gain = 0.5f,
		.accelerationRejection = 10.0f,
		.magneticRejection = 20.0f,
		.recoveryTriggerPeriod = 5 * SAMPLE_RATE,
	};
	FusionAhrsSetSettings((FusionAhrs *)device->ahrs, &settings);

	return DEVICE_IMU_ERROR_NO_ERROR;
}

// Decode one header-aligned frame. Returns true if `fr` was a valid frame (and the callback fired),
// false if it failed validation (caller should resync by one byte).
static bool process_frame(device_imu_net_type *device, const uint8_t *fr)
{
	float graw[3], araw[3];
	for (int k = 0; k < 3; k++)
		graw[k] = read_le_f32(fr + ONE_GYRO_OFFSET + 4 * k);
	for (int k = 0; k < 3; k++)
		araw[k] = read_le_f32(fr + ONE_ACCEL_OFFSET + 4 * k);

	// Validate: reject NaN/Inf and frames whose accel magnitude isn't ~1 g (a misaligned frame
	// almost never passes this), mirroring the community drivers' sanity checks.
	for (int k = 0; k < 3; k++)
		if (!isfinite(graw[k]) || !isfinite(araw[k]))
			return false;
	float amag = sqrtf(araw[0] * araw[0] + araw[1] * araw[1] + araw[2] * araw[2]);
	if (amag < 5.0f || amag > 15.0f)
		return false;
	for (int k = 0; k < 3; k++)
		if (fabsf(graw[k]) > 2000.0f)
			return false;

	uint64_t ts = read_le_u64(fr + ONE_TS_OFFSET);

	float traw = read_le_f32(fr + ONE_TEMP_OFFSET);
	if (isfinite(traw) && traw > -50.0f && traw < 150.0f)
		device->temperature = traw;

	FusionVector gyroscope = apply_map(&g_gyro_map, graw, g_gyro_scale);			 // deg/s
	FusionVector accelerometer = apply_map(&g_accel_map, araw, 1.0f / GRAVITY_MS2); // g

	float dt;
	if (device->have_last_timestamp && ts > device->last_timestamp)
	{
		dt = (float)((double)(ts - device->last_timestamp) / 1e9);
		if (dt <= 0.0f || dt > 0.1f)
			dt = 1.0f / (float)SAMPLE_RATE; // guard against gaps / batching
	}
	else
	{
		dt = 1.0f / (float)SAMPLE_RATE;
	}
	device->last_timestamp = ts;
	device->have_last_timestamp = true;

	if (device->offset)
		gyroscope = FusionOffsetUpdate((FusionOffset *)device->offset, gyroscope);

	if (device->ahrs)
	{
		FusionAhrsUpdateNoMagnetometer((FusionAhrs *)device->ahrs, gyroscope, accelerometer, dt);

		const device_imu_quat_type q = device_imu_get_orientation((device_imu_ahrs_type *)device->ahrs);
		if (isnan(q.x) || isnan(q.y) || isnan(q.z) || isnan(q.w))
			return true; // consumed, but don't propagate a bad orientation
	}

#ifndef NDEBUG
	{
		static int dbg = 0;
		if ((dbg++ % 200) == 0)
			net_imu_log("G[% .2f % .2f % .2f] A[% .2f % .2f % .2f]\n",
						gyroscope.axis.x, gyroscope.axis.y, gyroscope.axis.z,
						accelerometer.axis.x, accelerometer.axis.y, accelerometer.axis.z);
	}
#endif

	if (device->callback)
		device->callback(ts, DEVICE_IMU_EVENT_UPDATE, (device_imu_ahrs_type *)device->ahrs);
	return true;
}

device_imu_error_type device_imu_net_read(device_imu_net_type *device, int timeout)
{
	if (!device)
		return DEVICE_IMU_ERROR_NO_DEVICE;
	if (device->fd < 0)
		return DEVICE_IMU_ERROR_NO_HANDLE;

	struct pollfd pfd = {device->fd, POLLIN, 0};
	int pr = poll(&pfd, 1, timeout);
	if (pr < 0)
		return (errno == EINTR) ? DEVICE_IMU_ERROR_NO_ERROR : DEVICE_IMU_ERROR_UNPLUGGED;
	if (pr == 0)
		return DEVICE_IMU_ERROR_NO_ERROR; // timed out with no data
	if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))
		return DEVICE_IMU_ERROR_UNPLUGGED;

	if (!device->buf)
		return DEVICE_IMU_ERROR_NO_ALLOCATION;

	// Keep room to append; if the buffer is nearly full we lost sync — drop the older half.
	if (device->buf_len > DEVICE_IMU_NET_RECV_BUFFER - 2048)
	{
		size_t half = device->buf_len / 2;
		memmove(device->buf, device->buf + half, device->buf_len - half);
		device->buf_len -= half;
	}

	ssize_t got = recv(device->fd, device->buf + device->buf_len,
					   DEVICE_IMU_NET_RECV_BUFFER - device->buf_len, 0);
	if (got == 0)
		return DEVICE_IMU_ERROR_UNPLUGGED; // peer closed
	if (got < 0)
		return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
				   ? DEVICE_IMU_ERROR_NO_ERROR
				   : DEVICE_IMU_ERROR_UNPLUGGED;
	device->buf_len += (size_t)got;

	// Decode every complete, header-aligned frame currently buffered.
	size_t pos = 0;
	while (device->buf_len - pos >= ONE_FRAME_LEN)
	{
		if (memcmp(device->buf + pos, ONE_HEADER, sizeof(ONE_HEADER)) != 0)
		{
			pos++; // not a header here — slide forward to resync
			continue;
		}
		if (process_frame(device, device->buf + pos))
			pos += ONE_FRAME_LEN;
		else
			pos++; // header matched but payload invalid — resync
	}

	if (pos > 0)
	{
		memmove(device->buf, device->buf + pos, device->buf_len - pos);
		device->buf_len -= pos;
	}
	return DEVICE_IMU_ERROR_NO_ERROR;
}

device_imu_error_type device_imu_net_close(device_imu_net_type *device)
{
	if (!device)
		return DEVICE_IMU_ERROR_NO_DEVICE;

	if (device->fd >= 0)
	{
		close(device->fd);
		device->fd = -1;
	}
	if (device->ahrs)
	{
		free(device->ahrs);
		device->ahrs = NULL;
	}
	if (device->offset)
	{
		free(device->offset);
		device->offset = NULL;
	}
	if (device->buf)
	{
		free(device->buf);
		device->buf = NULL;
	}
	device->buf_len = 0;
	device->have_last_timestamp = false;
	return DEVICE_IMU_ERROR_NO_ERROR;
}
