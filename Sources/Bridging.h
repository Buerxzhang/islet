#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_mib.h>
#include <libproc.h>
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <stdint.h>

// ---- SMC（系统管理控制器）读取：整机功耗、风扇转速。普通用户权限即可读。----

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SMCKeyData;

static inline uint32_t smc_fourcc(const char *s) { return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3]; }

static inline io_connect_t smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t conn = 0;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return r == KERN_SUCCESS ? conn : 0;
}

static inline kern_return_t smc_call(io_connect_t conn, SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCKeyData), out, &outSize);
}

// 读取一个 SMC 键：返回数据长度，失败返回 -1。type 为四字符类型码（如 'flt '）。
static inline int smc_read(io_connect_t conn, const char *key, uint8_t *bytes, uint32_t *type) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = smc_fourcc(key);
    in.data8 = 9;  // 读取键信息
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    uint32_t size = out.keyInfo.dataSize;
    *type = out.keyInfo.dataType;
    in.keyInfo.dataSize = size;
    in.data8 = 5;  // 读取键值
    memset(&out, 0, sizeof out);
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    memcpy(bytes, out.bytes, size > 32 ? 32 : size);
    return (int)size;
}

// 按序号读取第 index 个键名（data8 = 8），用于枚举温度传感器。
static inline uint32_t smc_key_at(io_connect_t conn, uint32_t index) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = 8; in.data32 = index;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return 0;
    return out.key;
}

// 已知键长度时直接读值（data8 = 5），比 smc_read 少一次查询键信息。成功返回 0。
static inline int smc_read_known(io_connect_t conn, const char *key, uint32_t size, uint8_t *bytes) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = smc_fourcc(key);
    in.keyInfo.dataSize = size;
    in.data8 = 5;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    memcpy(bytes, out.bytes, size > 32 ? 32 : size);
    return 0;
}

// 写入一个 SMC 键（data8 = 6）。需要 root，普通用户会被固件拒绝。
// 成功返回 0；IOKit 调用失败返回 kern_return_t（如 0xE00002C1 没有权限）；固件拒绝返回 SMC 结果码（如 0x84 键不存在）。
static inline int smc_write(io_connect_t conn, const char *key, uint32_t size, const uint8_t *bytes) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = smc_fourcc(key);
    in.keyInfo.dataSize = size;
    in.data8 = 6;
    memcpy(in.bytes, bytes, size > 32 ? 32 : size);
    kern_return_t r = smc_call(conn, &in, &out);
    if (r != KERN_SUCCESS) return r;
    return out.result;
}
