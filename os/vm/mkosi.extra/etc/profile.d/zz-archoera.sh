# ArchoeraOS kiosk 会话入口。
# 只在 tty1（VT 会话——systemd-logind 仅对 VT 允许 TakeControl，libseat 才能打开
# DRM/输入设备）以默认用户 archoera（普通用户，非 root）启动会话脚本。
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ "$(id -u)" != "0" ]; then
    exec /usr/local/bin/archoera-session
fi
