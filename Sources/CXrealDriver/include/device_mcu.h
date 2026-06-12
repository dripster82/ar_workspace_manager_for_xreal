#pragma once
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

#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifndef __cplusplus
#include <stdint.h>
#else
#include <cstdint>
#endif

#define DEVICE_MCU_MSG_R_BRIGHTNESS 0x03
#define DEVICE_MCU_MSG_W_BRIGHTNESS 0x04
#define DEVICE_MCU_MSG_R_DISP_MODE 0x07
#define DEVICE_MCU_MSG_W_DISP_MODE 0x08

#define DEVICE_MCU_MSG_R_GLASSID 0x15
#define DEVICE_MCU_MSG_R_DP7911_FW_VERSION 0x16
#define DEVICE_MCU_MSG_R_DSP_VERSION 0x18
#define DEVICE_MCU_MSG_W_CANCEL_ACTIVATION 0x19
#define DEVICE_MCU_MSG_P_HEARTBEAT 0x1A
#define DEVICE_MCU_MSG_W_SLEEP_TIME 0x1E

#define DEVICE_MCU_MSG_R_DSP_APP_FW_VERSION 0x21
#define DEVICE_MCU_MSG_R_MCU_APP_FW_VERSION 0x26
#define DEVICE_MCU_MSG_R_ACTIVATION_TIME 0x29
#define DEVICE_MCU_MSG_W_ACTIVATION_TIME 0x2A

#define DEVICE_MCU_MSG_R_DP7911_FW_IS_UPDATE 0x3C
#define DEVICE_MCU_MSG_W_UPDATE_DP 0x3D
#define DEVICE_MCU_MSG_W_UPDATE_MCU_APP_FW_PREPARE 0x3E
#define DEVICE_MCU_MSG_W_UPDATE_MCU_APP_FW_START 0x3F

#define DEVICE_MCU_MSG_W_UPDATE_MCU_APP_FW_TRANSMIT 0x40
#define DEVICE_MCU_MSG_W_UPDATE_MCU_APP_FW_FINISH 0x41
#define DEVICE_MCU_MSG_W_BOOT_JUMP_TO_APP 0x42
#define DEVICE_MCU_MSG_W_MCU_APP_JUMP_TO_BOOT 0x44
#define DEVICE_MCU_MSG_W_UPDATE_DSP_APP_FW_PREPARE 0x45
#define DEVICE_MCU_MSG_W_UPDATE_DSP_APP_FW_START 0x46
#define DEVICE_MCU_MSG_W_UPDATE_DSP_APP_FW_TRANSMIT 0x47
#define DEVICE_MCU_MSG_W_UPDATE_DSP_APP_FW_FINISH 0x48
#define DEVICE_MCU_MSG_R_IS_NEED_UPGRADE_DSP_FW 0x49

#define DEVICE_MCU_MSG_W_FORCE_UPGRADE_DSP_FW 0x69

#define DEVICE_MCU_MSG_W_BOOT_UPDATE_MODE 0x1100
#define DEVICE_MCU_MSG_W_BOOT_UPDATE_CONFIRM 0x1101
#define DEVICE_MCU_MSG_W_BOOT_UPDATE_PREPARE 0x1102
#define DEVICE_MCU_MSG_W_BOOT_UPDATE_START 0x1103
#define DEVICE_MCU_MSG_W_BOOT_UPDATE_TRANSMIT 0x1104
#define DEVICE_MCU_MSG_W_BOOT_UPDATE_FINISH 0x1105

#define DEVICE_MCU_MSG_P_START_HEARTBEAT 0x6c02
#define DEVICE_MCU_MSG_P_DISPLAY_TOGGLED 0x6C04
#define DEVICE_MCU_MSG_P_BUTTON_PRESSED 0x6C05
#define DEVICE_MCU_MSG_P_END_HEARTBEAT 0x6c12
#define DEVICE_MCU_MSG_P_ASYNC_TEXT_LOG 0x6c09

#define DEVICE_MCU_MSG_E_DSP_ONE_PACKGE_WRITE_FINISH 0x6C0E
#define DEVICE_MCU_MSG_E_DSP_UPDATE_PROGRES 0x6C10
#define DEVICE_MCU_MSG_E_DSP_UPDATE_ENDING 0x6C11

#define DEVICE_MCU_BUTTON_PHYS_DISPLAY_TOGGLE 0x1
#define DEVICE_MCU_BUTTON_PHYS_BRIGHTNESS_UP 0x2
#define DEVICE_MCU_BUTTON_PHYS_BRIGHTNESS_DOWN 0x3

#define DEVICE_MCU_DISPLAY_MODE_1920x1080_60 0x1
#define DEVICE_MCU_DISPLAY_MODE_3840x1080_60_SBS 0x3
#define DEVICE_MCU_DISPLAY_MODE_3840x1080_72_SBS 0x4
#define DEVICE_MCU_DISPLAY_MODE_1920x1080_72 0x5
#define DEVICE_MCU_DISPLAY_MODE_1920x1080_60_SBS 0x8
#define DEVICE_MCU_DISPLAY_MODE_3840x1080_90_SBS 0x9
#define DEVICE_MCU_DISPLAY_MODE_1920x1080_90 0xA
#define DEVICE_MCU_DISPLAY_MODE_1920x1080_120 0xB

#define DEVICE_MCU_BUTTON_VIRT_DISPLAY_TOGGLE 0x1
#define DEVICE_MCU_BUTTON_VIRT_BRIGHTNESS_UP 0x6
#define DEVICE_MCU_BUTTON_VIRT_BRIGHTNESS_DOWN 0x7
#define DEVICE_MCU_BUTTON_VIRT_UP 0x8
#define DEVICE_MCU_BUTTON_VIRT_DOWN 0x9
#define DEVICE_MCU_BUTTON_VIRT_MODE_2D 0xA
#define DEVICE_MCU_BUTTON_VIRT_MODE_3D 0xB
#define DEVICE_MCU_BUTTON_VIRT_BLEND_CYCLE 0xC
#define DEVICE_MCU_BUTTON_VIRT_CONTROL_TOGGLE 0xF

#define DEVICE_MCU_BLEND_STATE_LOW 0x0
#define DEVICE_MCU_BLEND_STATE_MEDIUM 0x2
#define DEVICE_MCU_BLEND_STATE_FULL 0x3

#define DEVICE_MCU_CONTROL_MODE_BRIGHTNESS 0x0
#define DEVICE_MCU_CONTROL_MODE_VOLUME 0x1

#ifdef __cplusplus
extern "C" {
#endif

enum device_mcu_error_t {
	DEVICE_MCU_ERROR_NO_ERROR = 0,
	DEVICE_MCU_ERROR_NO_DEVICE = 1,
	DEVICE_MCU_ERROR_NO_HANDLE = 2,
	DEVICE_MCU_ERROR_NO_ACTIVATION = 3,
	DEVICE_MCU_ERROR_WRONG_SIZE = 4,
	DEVICE_MCU_ERROR_UNPLUGGED = 5,
	DEVICE_MCU_ERROR_UNEXPECTED = 6,
	DEVICE_MCU_ERROR_WRONG_HEAD = 7,
	DEVICE_MCU_ERROR_INVALID_LENGTH = 8,
	DEVICE_MCU_ERROR_NOT_INITIALIZED = 9,
	DEVICE_MCU_ERROR_PAYLOAD_FAILED = 10,
	DEVICE_MCU_ERROR_UNKNOWN = 11,
};

struct __attribute__((__packed__)) device_mcu_packet_t {
	uint8_t head;
	uint32_t checksum;
	uint16_t length;
	uint64_t timestamp;
	uint16_t msgid;
	uint8_t reserved [5];
	union {
		char text [42];
		uint8_t data [42];
	};
};

enum device_mcu_event_t {
	DEVICE_MCU_EVENT_UNKNOWN = 0,
	DEVICE_MCU_EVENT_SCREEN_ON = 1,
	DEVICE_MCU_EVENT_SCREEN_OFF = 2,
	DEVICE_MCU_EVENT_BRIGHTNESS_UP = 3,
	DEVICE_MCU_EVENT_BRIGHTNESS_DOWN = 4,
	DEVICE_MCU_EVENT_MESSAGE = 5,
	DEVICE_MCU_EVENT_DISPLAY_MODE_2D = 6,
	DEVICE_MCU_EVENT_DISPLAY_MODE_3D = 7,
	DEVICE_MCU_EVENT_BLEND_CYCLE = 8,
	DEVICE_MCU_EVENT_CONTROL_TOGGLE = 9,
	DEVICE_MCU_EVENT_VOLUME_UP = 10,
	DEVICE_MCU_EVENT_VOLUME_DOWN = 11,
};

typedef enum device_mcu_error_t device_mcu_error_type;
typedef struct device_mcu_packet_t device_mcu_packet_type;
typedef enum device_mcu_event_t device_mcu_event_type;
typedef void (*device_mcu_event_callback)(
		uint64_t timestamp,
		device_mcu_event_type event,
		uint8_t brightness,
		const char* msg
);

struct device_mcu_t {
	uint16_t vendor_id;
	uint16_t product_id;
	
	void* handle;

	bool activated;
	char mcu_app_fw_version [42];
	char dp_fw_version [42];
	char dsp_fw_version [42];
	
	bool active;
	uint8_t brightness;
	uint8_t disp_mode;
	uint8_t blend_state;
	uint8_t control_mode;
	
	device_mcu_event_callback callback;
};

typedef struct device_mcu_t device_mcu_type;

device_mcu_error_type device_mcu_open(device_mcu_type* device, device_mcu_event_callback callback);

device_mcu_error_type device_mcu_clear(device_mcu_type* device);

device_mcu_error_type device_mcu_read(device_mcu_type* device, int timeout);

device_mcu_error_type device_mcu_poll_display_mode(device_mcu_type* device);

device_mcu_error_type device_mcu_update_display_mode(device_mcu_type* device);

device_mcu_error_type device_mcu_update_firmware(device_mcu_type* device, const char* path);

device_mcu_error_type device_mcu_close(device_mcu_type* device);

#ifdef __cplusplus
} // extern "C"
#endif
