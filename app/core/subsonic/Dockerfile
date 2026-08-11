# ArchoeraMusic 内置 Subsonic 服务端（standalone/Docker）镜像
#
# 多阶段构建：
#   1. rust   → libarchoera_transcoder.so（symphonia 解码 + mp3lame 编码）
#   2. golang → archoera-subsonic 可执行（-tags standalone，CGO 链接 glibc）
#   3. debian → 运行时镜像
#
# 用法示例：
#   docker build -t archoera-subsonic .
#   docker run -d -p 4533:4533 \
#     -v /path/to/library.db:/data/database/library.db \
#     -v /path/to/music:/music \
#     -e SUB_ADMIN_USER=admin -e SUB_ADMIN_PASSWORD=secret \
#     --name subsonic archoera-subsonic
#
# 环境变量（见 standalone.go configFromEnv）：
#   SUB_ADDR=0.0.0.0:4533  SUB_DATA_DIR=/data  SUB_MUSIC_DIR=/music
#   SUB_TRANSCODER=/app/libarchoera_transcoder.so
#   SUB_ADMIN_USER / SUB_ADMIN_PASSWORD：库内无用户时引导管理员
#
# 注意：扫描为宿主侧（桌面端）能力，Docker 部署需挂载预置的
# library.db（tracks + subsonic 表），或由外部进程写入曲库。

# ---- 阶段 1：Rust 转码器 ----
FROM rust:1-slim AS transcoder
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make autoconf automake libtool pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/transcoder
COPY transcoder/Cargo.toml transcoder/Cargo.lock ./
COPY transcoder/src ./src
RUN cargo build --release

# ---- 阶段 2：Go 服务端（standalone）----
FROM golang:1.23 AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -tags standalone -trimpath -ldflags="-s -w" \
    -o /out/archoera-subsonic .

# ---- 阶段 3：运行时 ----
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /out/archoera-subsonic ./
COPY --from=transcoder /src/transcoder/target/release/libarchoera_transcoder.so ./
ENV SUB_ADDR=0.0.0.0:4533 \
    SUB_DATA_DIR=/data \
    SUB_MUSIC_DIR=/music \
    SUB_TRANSCODER=/app/libarchoera_transcoder.so
EXPOSE 4533
VOLUME ["/data", "/music"]
CMD ["/app/archoera-subsonic"]
