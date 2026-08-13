using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Archoera.Vault;

/// 设备指纹采集（device-bound-vault-plan §5.1，三平台）。
///
/// 用途：设备熵封装的绑定因子——本机免密解锁（熵在场）与设备变更检测
/// （指纹不符 → 落恢复口令路径）。指纹是**可公开读取**的系统标识，
/// 软件级绑定的真实价值是「迁移可用性 + 免密体验」，非绝对机密性（§2）。
///
/// 采集策略：主源 → 备选逐级降级；全部失败返回 null（视同设备熵不可用，
/// 对用户表现为需口令）。测试可经 `ARCHOERA_VAULT_FINGERPRINT` 注入覆盖。
public static class Fingerprint
{
    /// 测试注入环境变量（换机/篡改测试：伪造不同指纹）。
    public const string EnvOverride = "ARCHOERA_VAULT_FINGERPRINT";

    /// 采集本机指纹字符串（已 trim；可能含多段组合，HKDF 输入可变长，不 hash）。
    public static string? Collect()
    {
        var injected = Environment.GetEnvironmentVariable(EnvOverride);
        if (!string.IsNullOrEmpty(injected)) return injected.Trim();

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return Linux();
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return Windows();
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return Mac();
        return null; // 未知平台：设备熵不可用
    }

    // ── Linux ──────────────────────────────────────────────────────

    private static string? Linux()
    {
        foreach (var p in new[] { "/etc/machine-id", "/var/lib/dbus/machine-id" })
        {
            var s = ReadTrim(p);
            if (s != null) return s;
        }
        // 备选：hostname + boot_id（容器/无 systemd 环境）
        var bootId = ReadTrim("/proc/sys/kernel/random/boot_id");
        return bootId != null ? Environment.MachineName + "/" + bootId : null;
    }

    // ── Windows ────────────────────────────────────────────────────

    /// MachineGuid（HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid）——
    /// 安装级稳定标识，重装系统变化（符合「设备变更需恢复」语义）。
    private static string? Windows()
    {
        const string subKey = @"SOFTWARE\Microsoft\Cryptography";
        uint type = 0;
        uint len = 0;
        // 先取长度，再取数据（RegGetValue 支持 null 缓冲 + ref pcbData 查询大小）
        if (RegGetValue(HKEY_LOCAL_MACHINE, subKey, "MachineGuid", RRF_RT_REG_SZ,
                out type, null, ref len) == 0 && len > 0)
        {
            var buf = new byte[len];
            if (RegGetValue(HKEY_LOCAL_MACHINE, subKey, "MachineGuid", RRF_RT_REG_SZ,
                    out type, buf, ref len) == 0)
            {
                var s = Encoding.Unicode.GetString(buf).TrimEnd('\0').Trim();
                if (s.Length > 0) return s;
            }
        }
        // 备选：系统卷序列号（磁盘更换会变）
        var vol = new StringBuilder(261);
        var fs = new StringBuilder(261);
        if (GetVolumeInformationW("C:\\", vol, (uint)vol.Capacity,
                out var serial, out _, out _, fs, (uint)fs.Capacity))
        {
            return $"C:{serial:X8}";
        }
        return null;
    }

    // ── macOS ──────────────────────────────────────────────────────

    /// IOPlatformUUID（ioreg 输出解析）——硬件级稳定标识。
    private static string? Mac()
    {
        try
        {
            var psi = new ProcessStartInfo("ioreg", "-rd1 -c IOPlatformExpertDevice")
            {
                RedirectStandardOutput = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            using var p = Process.Start(psi);
            if (p == null) return null;
            var outText = p.StandardOutput.ReadToEnd();
            p.WaitForExit(3000);
            // 输出形如: "IOPlatformUUID" = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
            const string marker = "\"IOPlatformUUID\"";
            var idx = outText.IndexOf(marker, StringComparison.Ordinal);
            if (idx >= 0)
            {
                var rest = outText[(idx + marker.Length)..];
                var eq = rest.IndexOf('=');
                if (eq >= 0)
                {
                    var q = rest[(eq + 1)..].Trim();
                    if (q.StartsWith('"'))
                    {
                        var end = q.IndexOf('"', 1);
                        if (end > 1) return q[1..end];
                    }
                }
            }
        }
        catch
        {
            // ioreg 不可用 → 备选
        }
        // 备选：hostname + 系统 UUID（kern.uuid 存在性高）
        try
        {
            var psi = new ProcessStartInfo("sysctl", "-n kern.uuid")
            {
                RedirectStandardOutput = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            using var p = Process.Start(psi);
            if (p != null)
            {
                var uuid = p.StandardOutput.ReadToEnd().Trim();
                p.WaitForExit(3000);
                if (uuid.Length > 0) return Environment.MachineName + "/" + uuid;
            }
        }
        catch
        {
            // 忽略，继续
        }
        return null;
    }

    // ── 工具 ───────────────────────────────────────────────────────

    private static string? ReadTrim(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path).Trim() : null;
        }
        catch
        {
            return null;
        }
    }

    // ── P/Invoke（Windows）─────────────────────────────────────────

    private const nuint HKEY_LOCAL_MACHINE = 0x80000002;
    private const uint RRF_RT_REG_SZ = 0x00000002;

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegGetValue(
        nuint hkey, [MarshalAs(UnmanagedType.LPWStr)] string? lpSubKey,
        [MarshalAs(UnmanagedType.LPWStr)] string? lpValue, uint dwFlags,
        out uint pdwType, byte[]? pvData, ref uint pcbData);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumeInformationW(
        [MarshalAs(UnmanagedType.LPWStr)] string rootPathName,
        StringBuilder volumeNameBuffer, uint volumeNameSize,
        out uint volumeSerialNumber, out uint maximumComponentLength,
        out uint fileSystemFlags, StringBuilder fileSystemNameBuffer,
        uint fileSystemNameSize);
}
