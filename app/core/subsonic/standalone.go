//go:build standalone

// Standalone（Docker/无宿主）入口：
//
//   - 以环境变量/flag 配置（固定端口、曲库/数据目录、转码器路径）
//   - 复用 lib_subsonic.go 的 runServer 与转码器
//   - 无 Dart 宿主，因此：
//       · 启动时经 SUB_ADMIN_USER/SUB_ADMIN_PASSWORD 引导管理员（库内无用户时）
//       · started/error 事件写日志；scan-request 仅提示（扫描为宿主侧能力）；
//         lyric-request 会超时返回空（在线歌词在无宿主下不可用）
//   - 曲库需预置（挂载桌面端生成的 library.db，或由外部进程写入 tracks 表）
//
// 构建：go build -tags standalone -o archoera-subsonic .
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/betastudio2/archoera-subsonic/config"
	"github.com/betastudio2/archoera-subsonic/crypto"
	"github.com/betastudio2/archoera-subsonic/db"
)

const defaultAddr = "0.0.0.0:4533" // 固定端口，供 Docker 端口映射

func main() {
	log.SetPrefix("[subsonic-standalone] ")
	cfg := configFromEnv()

	config.Set(cfg)
	if cfg.DBPath == "" {
		cfg.DBPath = db.DefaultDBPath() // 按 DataDir 计算
	}
	log.Printf("配置: addr=%s db=%s music=%s transcoder=%s",
		cfg.Addr, cfg.DBPath, cfg.MusicDir, cfg.Transcoder)

	// 凭据密钥自举（无 SUB_SECRET_KEY 时生成并持久化到 dataDir/secret.key）
	if _, err := crypto.LoadKey(); err != nil {
		log.Fatalf("初始化凭据密钥失败: %v", err)
	}

	// 管理员引导（先建表：db.Open 只建目录/开库，表结构由 EnsureTables 建）
	if err := db.Open(cfg.DBPath); err != nil {
		log.Fatalf("打开数据库失败: %v", err)
	}
	// 独立用户库（subsonic_* 用户数据）
	if err := db.OpenUserDB(db.DefaultUserDBPath()); err != nil {
		db.Close()
		log.Fatalf("打开用户数据库失败: %v", err)
	}
	if err := db.EnsureTables(); err != nil {
		db.Close()
		log.Fatalf("初始化表结构失败: %v", err)
	}
	// 自动迁移：library.db 中遗留的旧 subsonic_* 数据 → user.db（幂等）
	if err := db.MigrateUserDB(); err != nil {
		db.Close()
		log.Fatalf("迁移用户数据失败: %v", err)
	}
	if err := bootstrapAdmin(); err != nil {
		db.Close()
		log.Fatalf("引导管理员失败: %v", err)
	}
	db.Close()

	st := &serverState{events: make(chan string, 256), done: make(chan struct{})}
	errCh := make(chan error, 1)
	go func() {
		errCh <- runServer(st, cfg)
		close(st.done)
	}()
	go drainEvents(st.events)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	select {
	case <-sigCh:
		log.Printf("收到退出信号，正在关闭…")
		config.SetEventSink(nil)
		if st.srv != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = st.srv.Shutdown(ctx)
			cancel()
		}
		<-st.done
	case <-st.done:
		if err := <-errCh; err != nil {
			log.Fatalf("服务端异常退出: %v", err)
		}
	}
	log.Printf("已安全退出")
}

// configFromEnv 从环境变量读取配置。
//
//	SUB_ADDR            监听地址，默认 0.0.0.0:4533（固定端口供 Docker 映射）
//	SUB_DB_PATH         数据库路径，默认 <dataDir>/database/library.db
//	SUB_MUSIC_DIR       曲库根目录
//	SUB_DATA_DIR        数据目录（secret.key / 封面缓存等）
//	SUB_TRANSCODER      转码器动态库路径，默认 ./libarchoera_transcoder.so
//	SUB_ADMIN_USER      引导管理员用户名（配合 SUB_ADMIN_PASSWORD）
//	SUB_ADMIN_PASSWORD  引导管理员密码
func configFromEnv() config.Config {
	cfg := config.Config{
		DBPath:     strings.TrimSpace(os.Getenv("SUB_DB_PATH")),
		MusicDir:   strings.TrimSpace(os.Getenv("SUB_MUSIC_DIR")),
		DataDir:    strings.TrimSpace(os.Getenv("SUB_DATA_DIR")),
		Addr:       strings.TrimSpace(os.Getenv("SUB_ADDR")),
		Transcoder: strings.TrimSpace(os.Getenv("SUB_TRANSCODER")),
	}
	if cfg.Addr == "" {
		cfg.Addr = defaultAddr
	}
	if cfg.Transcoder == "" {
		cfg.Transcoder = "libarchoera_transcoder.so"
	}
	return cfg
}

// bootstrapAdmin 库中无用户且配置了 SUB_ADMIN_USER/PASSWORD 时创建管理员。
func bootstrapAdmin() error {
	username := strings.TrimSpace(os.Getenv("SUB_ADMIN_USER"))
	password := os.Getenv("SUB_ADMIN_PASSWORD")
	if username == "" || password == "" {
		log.Printf("未设置 SUB_ADMIN_USER/SUB_ADMIN_PASSWORD，跳过管理员引导")
		return nil
	}
	if err := db.CreateUser("admin-"+randHex(), username, password, true); err != nil {
		return err
	}
	log.Printf("已引导管理员用户 %s", username)
	return nil
}

// drainEvents 消费并记录事件（standalone 无 Dart 宿主）。
func drainEvents(events <-chan string) {
	for ev := range events {
		switch {
		case strings.Contains(ev, `"type":"scan-request"`):
			log.Printf("收到扫描请求：standalone 模式扫描为宿主侧能力，需外部预置曲库")
		case strings.Contains(ev, `"type":"lyric-request"`):
			log.Printf("收到在线歌词请求：standalone 模式无宿主，返回空（在线歌词不可用）")
		default:
			log.Printf("事件: %s", ev)
		}
	}
}

// randHex 生成 32 位随机 hex（用于用户 id）。
func randHex() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}
