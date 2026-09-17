# mkosi Autologin=yes 会在 tty1/hvc0 自动登录 root；
# 只在 tty1（VT 会话，logind 可 TakeControl）启动 kiosk 合成器。
if [ "$(id -u)" = "0" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
    exec /usr/local/bin/archoera-session
fi
