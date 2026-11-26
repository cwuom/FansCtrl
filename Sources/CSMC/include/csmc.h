#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

// AppleSMC 用户态客户端的结构布局必须与内核一致（80 字节），因此放在 C 里定义，
// 避免依赖 Swift 结构体布局。
typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t attributes;
} csmc_key_info_t;

kern_return_t csmc_open(io_connect_t *conn);
void csmc_close(io_connect_t conn);

/// 返回 0 表示成功；非 0 为 IOKit 错误或 SMC 结果码（高位加 0x1000_0000 区分）。
int32_t csmc_key_info(io_connect_t conn, uint32_t key, csmc_key_info_t *info);
int32_t csmc_read(io_connect_t conn, uint32_t key, csmc_key_info_t *info, uint8_t out[32]);
/// 已知 key 尺寸时跳过 keyinfo 查询，用于高频读取温度/转速。
int32_t csmc_read_sized(io_connect_t conn, uint32_t key, uint32_t size, uint8_t out[32]);
int32_t csmc_write(io_connect_t conn, uint32_t key, const uint8_t *bytes, uint32_t size);
int32_t csmc_key_at_index(io_connect_t conn, uint32_t index, uint32_t *key);

#endif
