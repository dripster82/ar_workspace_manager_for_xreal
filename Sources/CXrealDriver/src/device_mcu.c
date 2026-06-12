//
// Created by thejackimonster on 29.03.23.
//
// Copyright (c) 2023-2024 thejackimonster. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#include "device_mcu.h"
#include "device.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <libkern/OSByteOrder.h>
#include <machine/endian.h>

#include <hidapi/hidapi.h>

#include "crc32.h"
#include "hid_ids.h"

#ifndef htole16
#define htole16(x) OSSwapHostToLittleInt16(x)
#endif

#ifndef htole32
#define htole32(x) OSSwapHostToLittleInt32(x)
#endif

#ifndef htole64
#define htole64(x) OSSwapHostToLittleInt64(x)
#endif

#ifndef le16toh
#define le16toh(x) OSSwapLittleToHostInt16(x)
#endif

#ifndef le32toh
#define le32toh(x) OSSwapLittleToHostInt32(x)
#endif

#ifndef le64toh
#define le64toh(x) OSSwapLittleToHostInt64(x)
#endif

#ifndef NDEBUG
#define device_mcu_error(msg) fprintf(stderr, "ERROR: %s\n", msg)
#else
#define device_mcu_error(msg) (0)
#endif

#define device_mcu_warning(msg) device_mcu_error(msg)

#define MAX_PACKET_SIZE 64
#define PACKET_HEAD 0xFD

static bool send_payload(device_mcu_type *device, uint8_t size, const uint8_t *payload)
{
	int payload_size = size;
	if (payload_size > MAX_PACKET_SIZE)
	{
		payload_size = MAX_PACKET_SIZE;
	}

	int transferred = hid_write(device->handle, payload, payload_size);

	if (transferred != payload_size)
	{
		device_mcu_error("Sending payload failed");
		return false;
	}

	return (transferred == size);
}

static bool recv_payload(device_mcu_type *device, uint8_t size, uint8_t *payload)
{
	int payload_size = size;
	if (payload_size > MAX_PACKET_SIZE)
	{
		payload_size = MAX_PACKET_SIZE;
	}

	int transferred = hid_read(device->handle, payload, payload_size);

	if (transferred >= payload_size)
	{
		transferred = payload_size;
	}

	if (transferred == 0)
	{
		return false;
	}

	if (transferred != payload_size)
	{
		device_mcu_error("Receiving payload failed");
		return false;
	}

	return (transferred == size);
}

static bool send_payload_action(device_mcu_type *device, uint16_t msgid, uint8_t len, const uint8_t *data)
{
	static device_mcu_packet_type packet;

	const uint16_t packet_len = 17 + len;
	const uint16_t payload_len = 5 + packet_len;

	packet.head = PACKET_HEAD;
	packet.length = htole16(packet_len);
	packet.timestamp = htole64(0);
	packet.msgid = htole16(msgid);
	memset(packet.reserved, 0, 5);

	memcpy(packet.data, data, len);
	packet.checksum = htole32(
			crc32_checksum(
					(const uint8_t *)(&packet.length),
					packet.length));

	return send_payload(device, payload_len, (uint8_t *)(&packet));
}

static bool recv_payload_msg(device_mcu_type *device, uint16_t msgid, uint8_t len, uint8_t *data)
{
	static device_mcu_packet_type packet;

	packet.head = 0;
	packet.length = 0;
	packet.msgid = 0;

	const uint16_t packet_len = 18 + len;
	const uint16_t payload_len = 5 + packet_len;

	if (!recv_payload(device, payload_len, (uint8_t *)(&packet)))
	{
		return false;
	}

	if (packet.head != PACKET_HEAD)
	{
		device_mcu_error("Invalid payload received");
		return false;
	}

	if (le16toh(packet.msgid) != msgid)
	{
		device_mcu_error("Unexpected payload received");
		return false;
	}

	const uint8_t status = packet.data[0];

	if (status != 0)
	{
		device_mcu_error("Payload status failed");
		return false;
	}

	const uint16_t data_len = le16toh(packet.length) - 18;

	if (len <= data_len)
	{
		memcpy(data, packet.data + 1, len);
	}
	else
	{
		memcpy(data, packet.data + 1, data_len);
		memset(data + data_len, 0, len - data_len);
	}

	return true;
}

static bool do_payload_action(device_mcu_type *device, uint16_t msgid, uint8_t len, const uint8_t *data)
{
	if (!send_payload_action(device, msgid, len, data))
	{
		return false;
	}

	const uint16_t attempts_per_second = (device->active ? 60 : 1);

	uint16_t attempts = attempts_per_second * 5;

	while (attempts > 0)
	{
		if (recv_payload_msg(device, msgid, 0, NULL))
		{
			return true;
		}

		attempts--;
	}

	return false;
}

device_mcu_error_type device_mcu_open(device_mcu_type *device, device_mcu_event_callback callback)
{
	if (!device)
	{
		device_mcu_error("No device");
		return DEVICE_MCU_ERROR_NO_DEVICE;
	}

	memset(device, 0, sizeof(device_mcu_type));
	device->vendor_id = xreal_vendor_id;
	device->product_id = 0;
	device->callback = callback;

	if (!device_init())
	{
		device_mcu_error("Not initialized");
		return DEVICE_MCU_ERROR_NOT_INITIALIZED;
	}

	struct hid_device_info *info = hid_enumerate(
			device->vendor_id,
			device->product_id);

	struct hid_device_info *it = info;
	while (it)
	{
		int interface_id = xreal_mcu_interface_id(it->product_id);
		if (interface_id != -1 && it->interface_number == interface_id)
		{
#ifndef NDEBUG
			printf("Found MCU device with product_id 0x%x on interface %d\n", it->product_id, interface_id);
#endif
			device->product_id = it->product_id;
			device->handle = hid_open_path(it->path);
			break;
		}

		it = it->next;
	}

	hid_free_enumeration(info);

	if (!device->handle)
	{
		device_mcu_error("No handle");
		return DEVICE_MCU_ERROR_NO_HANDLE;
	}

	device_mcu_clear(device);

	if (!send_payload_action(device, DEVICE_MCU_MSG_R_ACTIVATION_TIME, 0, NULL))
	{
		device_mcu_error("Requesting activation time failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	uint8_t activated;
	if (!recv_payload_msg(device, DEVICE_MCU_MSG_R_ACTIVATION_TIME, 1, &activated))
	{
		device_mcu_error("Receiving activation time failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	device->activated = (activated != 0);

	if (!device->activated)
	{
		device_mcu_warning("Device is not activated");
	}

	if (!send_payload_action(device, DEVICE_MCU_MSG_R_MCU_APP_FW_VERSION, 0, NULL))
	{
		device_mcu_error("Requesting current MCU app firmware version");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!recv_payload_msg(device, DEVICE_MCU_MSG_R_MCU_APP_FW_VERSION, 41, (uint8_t *)device->mcu_app_fw_version))
	{
		device_mcu_error("Receiving current MCU app firmware version failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!send_payload_action(device, DEVICE_MCU_MSG_R_DP7911_FW_VERSION, 0, NULL))
	{
		device_mcu_error("Requesting current DP firmware version");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!recv_payload_msg(device, DEVICE_MCU_MSG_R_DP7911_FW_VERSION, 41, (uint8_t *)device->dp_fw_version))
	{
		device_mcu_error("Receiving current DP firmware version failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!send_payload_action(device, DEVICE_MCU_MSG_R_DSP_APP_FW_VERSION, 0, NULL))
	{
		device_mcu_error("Requesting current DSP app firmware version");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!recv_payload_msg(device, DEVICE_MCU_MSG_R_DSP_APP_FW_VERSION, 41, (uint8_t *)device->dsp_fw_version))
	{
		device_mcu_error("Receiving current DSP app firmware version failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

#ifndef NDEBUG
	printf("MCU: %s\n", device->mcu_app_fw_version);
	printf("DP: %s\n", device->dp_fw_version);
	printf("DSP: %s\n", device->dsp_fw_version);
#endif

	if (!send_payload_action(device, DEVICE_MCU_MSG_R_BRIGHTNESS, 0, NULL))
	{
		device_mcu_error("Requesting initial brightness failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!recv_payload_msg(device, DEVICE_MCU_MSG_R_BRIGHTNESS, 1, &device->brightness))
	{
		device_mcu_error("Receiving initial brightness failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!send_payload_action(device, DEVICE_MCU_MSG_R_DISP_MODE, 0, NULL))
	{
		device_mcu_error("Requesting display mode failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!recv_payload_msg(device, DEVICE_MCU_MSG_R_DISP_MODE, 1, &device->disp_mode))
	{
		device_mcu_error("Receiving display mode failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

#ifndef NDEBUG
	printf("Brightness: %d\n", device->brightness);
	printf("Disp-Mode: %d\n", device->disp_mode);
#endif

	return DEVICE_MCU_ERROR_NO_ERROR;
}

static void device_mcu_callback(device_mcu_type *device,
																uint64_t timestamp,
																device_mcu_event_type event,
																uint8_t brightness,
																const char *msg)
{
	if (!device->callback)
	{
		return;
	}

	device->callback(timestamp, event, brightness, msg);
}

device_mcu_error_type device_mcu_clear(device_mcu_type *device)
{
	return device_mcu_read(device, 10);
}

device_mcu_error_type device_mcu_read(device_mcu_type *device, int timeout)
{
	if (!device)
	{
		device_mcu_error("No device");
		return DEVICE_MCU_ERROR_NO_DEVICE;
	}

	if (!device->handle)
	{
		device_mcu_error("No handle");
		return DEVICE_MCU_ERROR_NO_HANDLE;
	}

	if (MAX_PACKET_SIZE != sizeof(device_mcu_packet_type))
	{
		device_mcu_error("Not proper size");
		return DEVICE_MCU_ERROR_WRONG_SIZE;
	}

	device_mcu_packet_type packet;
	memset(&packet, 0, sizeof(device_mcu_packet_type));

	int transferred = hid_read_timeout(
			device->handle,
			(uint8_t *)&packet,
			MAX_PACKET_SIZE,
			timeout);

	if (transferred == -1)
	{
		device_mcu_error("Device may be unplugged");
		return DEVICE_MCU_ERROR_UNPLUGGED;
	}

	if (transferred == 0)
	{
		return DEVICE_MCU_ERROR_NO_ERROR;
	}

	if (MAX_PACKET_SIZE != transferred)
	{
		device_mcu_error("Unexpected packet size");
		return DEVICE_MCU_ERROR_UNEXPECTED;
	}

	if (packet.head != PACKET_HEAD)
	{
		device_mcu_error("Wrong packet head");
		return DEVICE_MCU_ERROR_WRONG_HEAD;
	}

	const uint32_t timestamp = le32toh(packet.timestamp);
	const uint16_t msgid = le16toh(packet.msgid);
	const uint16_t length = le16toh(packet.length);

	const size_t data_len = (size_t) & (packet.data) - (size_t) & (packet.length);

#ifndef NDEBUG
	printf("MSG: %d = %04x (%d)\n", msgid, msgid, length);

	if (length > 11)
	{
		for (int i = 0; i < length - 11; i++)
		{
			printf("%02x ", packet.data[i]);
		}

		printf("\n");
	}
#endif

	switch (msgid)
	{
	case DEVICE_MCU_MSG_P_START_HEARTBEAT:
	{
		break;
	}
	case DEVICE_MCU_MSG_P_DISPLAY_TOGGLED:
	{
		const uint8_t value = packet.data[0];

		device->active = value;
		
		if (device->active) {
			device_mcu_callback(
					device,
					timestamp,
					DEVICE_MCU_EVENT_SCREEN_ON,
					device->brightness,
					NULL
			);
		} else {
			device_mcu_callback(
					device,
					timestamp,
					DEVICE_MCU_EVENT_SCREEN_OFF,
					device->brightness,
					NULL
			);
		}
		break;
	}
	case DEVICE_MCU_MSG_P_BUTTON_PRESSED:
	{
		const uint8_t phys_button = packet.data[0];
		const uint8_t virt_button = packet.data[4];
		const uint8_t value = packet.data[8];

		switch (virt_button) {
			case DEVICE_MCU_BUTTON_VIRT_DISPLAY_TOGGLE:
				device->active = value;

				if (device->active) {
					device_mcu_callback(
							device,
							timestamp,
							DEVICE_MCU_EVENT_SCREEN_ON,
							device->brightness,
							NULL
					);
				} else {
					device_mcu_callback(
							device,
							timestamp,
							DEVICE_MCU_EVENT_SCREEN_OFF,
							device->brightness,
							NULL
					);
				}
				break;
			case DEVICE_MCU_BUTTON_VIRT_BRIGHTNESS_UP:
				device->brightness = value;

				device_mcu_callback(
						device,
						timestamp,
						DEVICE_MCU_EVENT_BRIGHTNESS_UP,
						device->brightness,
						NULL
				);
				break;
			case DEVICE_MCU_BUTTON_VIRT_BRIGHTNESS_DOWN:
				device->brightness = value;

				device_mcu_callback(
						device,
						timestamp,
						DEVICE_MCU_EVENT_BRIGHTNESS_DOWN,
						device->brightness,
						NULL
				);
				break;
			case DEVICE_MCU_BUTTON_VIRT_UP:
				if (device->control_mode == DEVICE_MCU_CONTROL_MODE_VOLUME)
					device_mcu_callback(
							device,
							timestamp,
							DEVICE_MCU_EVENT_VOLUME_UP,
							device->brightness,
							NULL
					);
				break;
			case DEVICE_MCU_BUTTON_VIRT_DOWN:
				if (device->control_mode == DEVICE_MCU_CONTROL_MODE_VOLUME)
					device_mcu_callback(
							device,
							timestamp,
							DEVICE_MCU_EVENT_VOLUME_DOWN,
							device->brightness,
							NULL
					);
				break;
			case DEVICE_MCU_BUTTON_VIRT_MODE_2D:
				device_mcu_callback(
						device,
						timestamp,
						DEVICE_MCU_EVENT_DISPLAY_MODE_2D,
						device->brightness,
						NULL
				);
				break;
			case DEVICE_MCU_BUTTON_VIRT_MODE_3D:
				device_mcu_callback(
						device,
						timestamp,
						DEVICE_MCU_EVENT_DISPLAY_MODE_3D,
						device->brightness,
						NULL
				);
				break;
			case DEVICE_MCU_BUTTON_VIRT_BLEND_CYCLE:
				device->blend_state = value;

				device_mcu_callback(
						device,
						timestamp,
						DEVICE_MCU_EVENT_BLEND_CYCLE,
						device->brightness,
						NULL		
				);
				break;
			case DEVICE_MCU_BUTTON_VIRT_CONTROL_TOGGLE:
				device->control_mode = value;

				device_mcu_callback(
						device,
						timestamp,
						DEVICE_MCU_EVENT_CONTROL_TOGGLE,
						device->brightness,
						NULL
				);
				break;
			default:
				break;
		}

		break;
	}
	case DEVICE_MCU_MSG_P_ASYNC_TEXT_LOG:
	{
		const char *text = packet.text;
		const size_t text_len = strlen(text);

		device->active = true;

		if (data_len + text_len != length)
		{
			device_mcu_error("Not matching length");
			return DEVICE_MCU_ERROR_INVALID_LENGTH;
		}

		device_mcu_callback(
				device,
				timestamp,
				DEVICE_MCU_EVENT_MESSAGE,
				device->brightness,
				text);
		break;
	}
	case DEVICE_MCU_MSG_P_END_HEARTBEAT:
	{
		break;
	}
	default:
		device_mcu_callback(
				device,
				timestamp,
				DEVICE_MCU_EVENT_UNKNOWN,
				device->brightness,
				NULL);
		break;
	}

	return DEVICE_MCU_ERROR_NO_ERROR;
}

device_mcu_error_type device_mcu_poll_display_mode(device_mcu_type *device)
{
	if (!device)
	{
		device_mcu_error("No device");
		return DEVICE_MCU_ERROR_NO_DEVICE;
	}

	if (!device->handle)
	{
		device_mcu_error("No handle");
		return DEVICE_MCU_ERROR_NO_HANDLE;
	}

	if (!send_payload_action(device, DEVICE_MCU_MSG_R_DISP_MODE, 0, NULL))
	{
		device_mcu_error("Requesting display mode failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	if (!recv_payload_msg(device, DEVICE_MCU_MSG_R_DISP_MODE, 1, &device->disp_mode))
	{
		device_mcu_error("Receiving display mode failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	return DEVICE_MCU_ERROR_NO_ERROR;
}

device_mcu_error_type device_mcu_update_display_mode(device_mcu_type *device)
{
	if (!device)
	{
		device_mcu_error("No device");
		return DEVICE_MCU_ERROR_NO_DEVICE;
	}

	if (!device->handle)
	{
		device_mcu_error("No handle");
		return DEVICE_MCU_ERROR_NO_HANDLE;
	}

	if (!do_payload_action(device, DEVICE_MCU_MSG_W_DISP_MODE, 1, &device->disp_mode))
	{
		device_mcu_error("Sending display mode failed");
		return DEVICE_MCU_ERROR_PAYLOAD_FAILED;
	}

	return DEVICE_MCU_ERROR_NO_ERROR;
}

device_mcu_error_type device_mcu_update_firmware(device_mcu_type *device, const char *path)
{
	if (!device)
	{
		device_mcu_error("No device");
		return DEVICE_MCU_ERROR_NO_DEVICE;
	}

	if (!device->handle)
	{
		device_mcu_error("No handle");
		return DEVICE_MCU_ERROR_NO_HANDLE;
	}

	if (!device->activated)
	{
		device_mcu_error("Device is not activated");
		return DEVICE_MCU_ERROR_NO_ACTIVATION;
	}

	size_t firmware_len = 0;
	uint8_t *firmware = NULL;

	FILE *file = fopen(path, "rb");
	bool result = DEVICE_MCU_ERROR_UNKNOWN;

	if (file)
	{
		fseek(file, 0, SEEK_END);
		firmware_len = ftell(file);

		if (firmware_len > 0)
		{
			firmware = (uint8_t *)malloc(firmware_len);
			fread(firmware, sizeof(uint8_t), firmware_len, file);
		}

		fclose(file);
	}

	device_mcu_clear(device);

	printf("Prepare upload: %lu\n", firmware_len);

	if (!do_payload_action(device, DEVICE_MCU_MSG_W_UPDATE_MCU_APP_FW_PREPARE, 0, NULL))
	{
		device_mcu_error("Failed preparing the device for MCU firmware update!\n");
		goto cleanup;
	}

	if (!do_payload_action(device, DEVICE_MCU_MSG_W_MCU_APP_JUMP_TO_BOOT, 0, NULL))
	{
		device_mcu_error("Failed mcu app jumping to boot");
		goto cleanup;
	}

	if (!send_payload_action(device, DEVICE_MCU_MSG_R_ACTIVATION_TIME, 0, NULL))
	{
		device_mcu_error("Requesting activation time failed");
		goto cleanup;
	}

	uint8_t activated;
	if (!recv_payload_msg(device, DEVICE_MCU_MSG_R_ACTIVATION_TIME, 1, &activated))
	{
		device_mcu_error("Receiving activation time failed");
		goto cleanup;
	}

	if (!activated)
	{
		device_mcu_error("Device is not activated");
		goto jump_to_app;
	}

	size_t offset = 0;

	while (offset < firmware_len)
	{
		const size_t remaining = firmware_len - offset;

		printf("Upload: %lu / %lu\n", offset, firmware_len);

		uint8_t len;
		uint16_t msgid;
		if (offset == 0)
		{
			len = remaining > 24 ? 24 : remaining;
			msgid = DEVICE_MCU_MSG_W_UPDATE_MCU_APP_FW_START;
		}
		else
		{
			len = remaining > 42 ? 42 : remaining;
			msgid = DEVICE_MCU_MSG_W_UPDATE_MCU_APP_FW_TRANSMIT;
		}

		if (!do_payload_action(device, msgid, len, firmware + offset))
		{
			device_mcu_error("Failed sending firmware upload");
			goto jump_to_app;
		}

		offset += len;
	}

	printf("Finish upload");

	if (!do_payload_action(device, DEVICE_MCU_MSG_W_UPDATE_MCU_APP_FW_FINISH, 0, NULL))
	{
		device_mcu_error("Failed finishing firmware upload");
		goto jump_to_app;
	}

	result = DEVICE_MCU_ERROR_NO_ERROR;

jump_to_app:
	if (!do_payload_action(device, DEVICE_MCU_MSG_W_BOOT_JUMP_TO_APP, 0, NULL))
	{
		device_mcu_error("Failed boot jumping back to app");
		goto cleanup;
	}

cleanup:
	if (firmware)
	{
		free(firmware);
	}

	return result;
}

device_mcu_error_type device_mcu_close(device_mcu_type *device)
{
	if (!device)
	{
		device_mcu_error("No device");
		return DEVICE_MCU_ERROR_NO_DEVICE;
	}

	if (device->handle)
	{
		hid_close(device->handle);
	}

	memset(device, 0, sizeof(device_mcu_type));
	device_exit();

	return DEVICE_MCU_ERROR_NO_ERROR;
}
