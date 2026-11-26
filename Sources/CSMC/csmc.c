#include "csmc.h"
#include <string.h>

enum {
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCWriteKey = 6,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

#define CSMC_RESULT_FLAG 0x10000000

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} smc_vers_t;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} smc_plimit_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} smc_keyinfo_raw_t;

typedef struct {
    uint32_t key;
    smc_vers_t vers;
    smc_plimit_t pLimitData;
    smc_keyinfo_raw_t keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param_t;

_Static_assert(sizeof(smc_param_t) == 80, "SMC param struct must be 80 bytes");

static int32_t call(io_connect_t conn, smc_param_t *in, smc_param_t *out) {
    size_t outSize = sizeof(smc_param_t);
    kern_return_t kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(smc_param_t), out, &outSize);
    if (kr != KERN_SUCCESS) return (int32_t)kr;
    if (out->result != 0) return CSMC_RESULT_FLAG | out->result;
    return 0;
}

kern_return_t csmc_open(io_connect_t *conn) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return kr;
}

void csmc_close(io_connect_t conn) {
    if (conn != IO_OBJECT_NULL) IOServiceClose(conn);
}

int32_t csmc_key_info(io_connect_t conn, uint32_t key, csmc_key_info_t *info) {
    smc_param_t in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    int32_t r = call(conn, &in, &out);
    if (r != 0) return r;
    info->dataSize = out.keyInfo.dataSize;
    info->dataType = out.keyInfo.dataType;
    info->attributes = out.keyInfo.dataAttributes;
    return 0;
}

int32_t csmc_read(io_connect_t conn, uint32_t key, csmc_key_info_t *info, uint8_t outBytes[32]) {
    int32_t r = csmc_key_info(conn, key, info);
    if (r != 0) return r;
    if (info->dataSize > 32) return CSMC_RESULT_FLAG | 0xFF;
    smc_param_t in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = kSMCReadKey;
    r = call(conn, &in, &out);
    if (r != 0) return r;
    memcpy(outBytes, out.bytes, 32);
    return 0;
}

int32_t csmc_read_sized(io_connect_t conn, uint32_t key, uint32_t size, uint8_t outBytes[32]) {
    if (size == 0 || size > 32) return CSMC_RESULT_FLAG | 0xFF;
    smc_param_t in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = kSMCReadKey;
    int32_t r = call(conn, &in, &out);
    if (r != 0) return r;
    memcpy(outBytes, out.bytes, 32);
    return 0;
}

int32_t csmc_write(io_connect_t conn, uint32_t key, const uint8_t *bytes, uint32_t size) {
    csmc_key_info_t info;
    int32_t r = csmc_key_info(conn, key, &info);
    if (r != 0) return r;
    // 尺寸不一致时拒绝写入，防止把错误长度的数据写进 SMC
    if (info.dataSize != size || size > 32) return CSMC_RESULT_FLAG | 0xFE;
    smc_param_t in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = kSMCWriteKey;
    memcpy(in.bytes, bytes, size);
    return call(conn, &in, &out);
}

int32_t csmc_key_at_index(io_connect_t conn, uint32_t index, uint32_t *key) {
    smc_param_t in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    int32_t r = call(conn, &in, &out);
    if (r != 0) return r;
    *key = out.key;
    return 0;
}
