//
// Created by wheaney on 12.11.23.
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

#include "hid_ids.h"

#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifndef __cplusplus
#include <stdint.h>
#else
#include <cstdint>
#endif

#include <hidapi/hidapi.h>

const uint16_t xreal_vendor_id = 0x3318;
const uint16_t xreal_product_ids[NUM_SUPPORTED_PRODUCTS] = {
    0x0424, // XREAL Air
    0x0428, // XREAL Air 2
    0x0432, // XREAL Air 2 Pro
    0x0426  // XREAL Air 2 Ultra
};

const int xreal_imu_interface_ids[NUM_SUPPORTED_PRODUCTS] = {
    3, // XREAL Air
    3, // XREAL Air 2
    3, // XREAL Air 2 Pro
    2  // XREAL Air 2 Ultra
};

const int xreal_mcu_interface_ids[NUM_SUPPORTED_PRODUCTS] = {
    4,  // XREAL Air
    4,  // XREAL Air 2
    4,  // XREAL Air 2 Pro
    0   // XREAL Air 2 Ultra MCU
};

static int xreal_product_index(uint16_t product_id) {
    for (int i = 0; i < NUM_SUPPORTED_PRODUCTS; i++) {
        if (xreal_product_ids[i] == product_id) {
            return i;
        }
    }

    return -1;
}

bool is_xreal_product_id(uint16_t product_id) {
    return xreal_product_index(product_id) >= 0;
}

int xreal_imu_interface_id(uint16_t product_id) {
    const int index = xreal_product_index(product_id);

    if (index >= 0) {
        return xreal_imu_interface_ids[index];
    } else {
        return -1;
    }
}

int xreal_mcu_interface_id(uint16_t product_id) {
    const int index = xreal_product_index(product_id);

    if (index >= 0) {
        return xreal_mcu_interface_ids[index];
    } else {
        return -1;
    }
}

// --- XREAL One series ---------------------------------------------------------------------------

// One / One Pro / One S product ids. 0x0436 is confirmed on real hardware; the rest are taken from
// community drivers and used for naming only (never for device selection — see header note).
struct xreal_named_product { uint16_t id; const char *name; };

static const struct xreal_named_product xreal_one_products[] = {
    { 0x0436, "XREAL One Pro" }, // hardware-confirmed
    { 0x0435, "XREAL One Pro" },
    { 0x0437, "XREAL One" },
    { 0x0438, "XREAL One" },
    { 0x043d, "XREAL One S" },
    { 0x043e, "XREAL One S" },
};
#define NUM_ONE_PRODUCTS (sizeof(xreal_one_products) / sizeof(xreal_one_products[0]))

static const struct xreal_named_product xreal_air_products[] = {
    { 0x0424, "XREAL Air" },
    { 0x0428, "XREAL Air 2" },
    { 0x0432, "XREAL Air 2 Pro" },
    { 0x0426, "XREAL Air 2 Ultra" },
};
#define NUM_AIR_PRODUCTS (sizeof(xreal_air_products) / sizeof(xreal_air_products[0]))

bool is_xreal_one_series(uint16_t product_id) {
    for (size_t i = 0; i < NUM_ONE_PRODUCTS; i++) {
        if (xreal_one_products[i].id == product_id) {
            return true;
        }
    }
    return false;
}

const char *xreal_product_name(uint16_t product_id) {
    for (size_t i = 0; i < NUM_ONE_PRODUCTS; i++) {
        if (xreal_one_products[i].id == product_id) {
            return xreal_one_products[i].name;
        }
    }
    for (size_t i = 0; i < NUM_AIR_PRODUCTS; i++) {
        if (xreal_air_products[i].id == product_id) {
            return xreal_air_products[i].name;
        }
    }
    return "XREAL glasses";
}

bool xreal_any_connected(uint16_t *product_id_out) {
    if (hid_init() != 0) {
        return false;
    }

    struct hid_device_info *info = hid_enumerate(xreal_vendor_id, 0);
    bool found = false;
    if (info) {
        found = true;
        if (product_id_out) {
            *product_id_out = info->product_id;
        }
    }
    hid_free_enumeration(info);
    return found;
}
