#pragma once
//
// Created by wheaney on 20.11.23.
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

#define NUM_SUPPORTED_PRODUCTS 4

#ifdef __cplusplus
extern "C" {
#endif

extern const uint16_t xreal_vendor_id;
extern const uint16_t xreal_product_ids [NUM_SUPPORTED_PRODUCTS];

bool is_xreal_product_id(uint16_t product_id);

int xreal_imu_interface_id(uint16_t product_id);
int xreal_mcu_interface_id(uint16_t product_id);

// --- XREAL One series ---------------------------------------------------------------------------
// The One / One Pro / One S use the same vendor id (0x3318) but DO NOT expose the Air's 64-byte HID
// IMU protocol. Their head-tracking IMU streams over the glasses' built-in USB-ethernet (CDC-ECM)
// link as a TCP service (see device_imu_net). These helpers are used only for classification and
// naming — the Air HID tables above are deliberately left untouched so the Air path is unchanged.
//
// 0x0436 (XREAL One Pro) is hardware-confirmed. The other ids are best-effort from community
// drivers and only affect the displayed product name, never device selection.
bool is_xreal_one_series(uint16_t product_id);

// Returns true if ANY XREAL HID device (vendor 0x3318) is currently connected, and writes the first
// product id seen to *product_id_out (may be NULL). Used to gate the network IMU path so it never
// probes link-local addresses unless XREAL glasses are actually plugged in.
bool xreal_any_connected(uint16_t *product_id_out);

// Human-readable model name for a product id ("XREAL One Pro", "XREAL Air 2", …) or "XREAL glasses".
const char *xreal_product_name(uint16_t product_id);

#ifdef __cplusplus
} // extern "C"
#endif
