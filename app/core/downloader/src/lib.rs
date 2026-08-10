// ============================================================
// §8 C ABI 导出 + 任务状态机 + 事件推送（戒律 13.1：严禁 poll_* 拉式接口）
//
// 事件推送唯一机制：init() 注册的 event_cb 函数指针直接调用（PUSH），
// 无任何事件队列/轮询。Dart `_handleEvent` 收到 ptr 后立即 free。
//
// 下载核心：reqwest bytes_stream chunk loop + tmp 文件 + fsync + 原子 rename
// （实现思路参考 SPlayer-Next download-engine，代码为本仓库自行编写）。
// ============================================================

pub mod crypto;
pub mod metadata;
pub mod models;
pub mod resolvers;
pub mod tag;

use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures::StreamExt;
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::runtime::Handle;

use crate::crypto::kugou as kg;
use crate::models::*;
use crate::resolvers::{KugouResolver, NeteaseResolver, PlatformUrlResolver};

// ============================================================
// 全局单例状态（戒律 13.2：登录态以 Rust 内部为准，Dart 仅注入）
// ============================================================

struct KugouState {
    /// 进程级设备 mid（init 时生成：kg_calc_mid(kg_random_string(16))）
    mid: Option<String>,
    /// 真实 dfid（register_dev 获取；status=2 时置 None 触发重注册）
    dfid: Option<String>,
    userid: String,
    token: String,
}

struct GlobalState {
    runtime: Option<tokio::runtime::Runtime>,
    client: Option<reqwest::Client>,
    event_cb: Option<unsafe extern "C" fn(*mut c_char)>,
    root_dir: Option<PathBuf>,
    subdir_strategy: i32,
    max_concurrent: usize,
    kugou: KugouState,
    netease_cookie: Option<String>,
    tasks: HashMap<String, TaskEntry>,
    /// 当前占用并发槽的任务数（queued 不占槽）
    running: usize,
    /// 下载历史文件路径（v2：重启恢复；None = 不持久化）
    history_path: Option<PathBuf>,
    /// 全局限速（bytes/sec；0 = 不限速）
    max_speed: u64,
    /// 文件名模板（v2 可配置；占位符 {artist}/{title}/{album}）
    filename_template: String,
    /// 下载记录上限：finished（failed/canceled）条目超过该值淘汰最旧（默认 100）
    history_limit: usize,
    /// 任务序号（入队递增；用于按创建顺序淘汰最旧的 finished 记录）
    task_seq: u64,
}

impl Default for GlobalState {
    fn default() -> Self {
        Self {
            runtime: None,
            client: None,
            event_cb: None,
            root_dir: None,
            subdir_strategy: 0,
            max_concurrent: 3,
            kugou: KugouState { mid: None, dfid: None, userid: String::new(), token: String::new() },
            netease_cookie: None,
            tasks: HashMap::new(),
            running: 0,
            history_path: None,
            max_speed: 0,
            filename_template: "{artist} - {title}".to_string(),
            history_limit: 100,
            task_seq: 0,
        }
    }
}

struct TaskEntry {
    request: EnqueueRequest,
    dest_path: PathBuf,
    tmp_path: PathBuf,
    cancel: Arc<AtomicBool>,
    /// 暂停标志（v2）：运行中置位后在下一个 await 点退出并**保留** .tmp 供续传
    paused: Arc<AtomicBool>,
    phase: TaskPhase,
    /// 创建序号（入队递增；finished 记录超限时淘汰最旧）
    seq: u64,
}

/// 记录上限裁剪：finished（failed/canceled）条目超过 [GlobalState::history_limit]
/// 时，按创建序号淘汰最旧（active 不受影响）。任务进入终态后调用。
fn prune_finished() {
    let mut g = GLOBAL.lock().unwrap();
    let limit = g.history_limit;
    let mut finished: Vec<(u64, String)> = g
        .tasks
        .iter()
        .filter(|(_, t)| matches!(t.phase, TaskPhase::Failed | TaskPhase::Canceled))
        .map(|(id, t)| (t.seq, id.clone()))
        .collect();
    if finished.len() <= limit {
        return;
    }
    finished.sort_by_key(|(seq, _)| *seq);
    let drop_count = finished.len() - limit;
    for (_, id) in finished.into_iter().take(drop_count) {
        if let Some(t) = g.tasks.remove(&id) {
            let _ = std::fs::remove_file(&t.tmp_path);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TaskPhase {
    Queued,
    Resolving,
    Downloading,
    Paused,
    Done,
    Failed,
    Canceled,
}

fn phase_str(p: TaskPhase) -> &'static str {
    match p {
        TaskPhase::Queued => "queued",
        TaskPhase::Resolving => "resolving",
        TaskPhase::Downloading => "running",
        TaskPhase::Paused => "paused",
        TaskPhase::Done => "done",
        TaskPhase::Failed => "failed",
        TaskPhase::Canceled => "canceled",
    }
}

static GLOBAL: Lazy<Mutex<GlobalState>> = Lazy::new(|| Mutex::new(GlobalState::default()));

// ============================================================
// stderr 日志器：log::* 在未注册 logger 时是 no-op（此前 resolvers 的
// debug 日志全部不可见），注册后 `flutter run -d linux` 控制台即可看到
// Rust 下载引擎的日志（write_tags 失败、Kugou 档位降级原因等）。
// ============================================================

static LOGGER_ONCE: std::sync::Once = std::sync::Once::new();

struct StderrLogger;

impl log::Log for StderrLogger {
    fn enabled(&self, _metadata: &log::Metadata<'_>) -> bool {
        true
    }
    fn log(&self, record: &log::Record<'_>) {
        eprintln!("[downloader] {}: {}", record.level(), record.args());
    }
    fn flush(&self) {}
}

// ============================================================
// 事件 JSON 协议（§12：Rust push → Dart pull-free）
// ============================================================

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
enum DownloadEvent {
    Progress { task_id: String, received: u64, total: Option<u64>, speed: u64 },
    /// [title]/[artist]/[album] 为 v2.1 元数据增强后的结果（引擎自主寻找）
    Done {
        task_id: String,
        file_path: String,
        file_size: u64,
        actual_quality: String,
        title: String,
        artist: String,
        album: String,
    },
    Error { task_id: String, error: String, retryable: bool, stage: String },
    Already { task_id: String, file_path: String },
    State { task_id: String, from: String, to: String },
}

// ============================================================
// 内部工具：推送事件回调（戒律 13.1：严禁事件队列，直接 call）
// ============================================================

fn push_event(event: &DownloadEvent) {
    let cb = GLOBAL.lock().unwrap().event_cb;
    let Some(cb) = cb else { return };
    let Ok(json) = serde_json::to_string(event) else { return };
    let Ok(cstr) = CString::new(json) else { return };
    let ptr = cstr.into_raw();
    unsafe { cb(ptr) };
}

fn push_error(task_id: &str, msg: &str, retryable: bool, stage: &str) {
    push_event(&DownloadEvent::Error {
        task_id: task_id.to_string(),
        error: msg.to_string(),
        retryable,
        stage: stage.to_string(),
    });
}

fn set_phase(task_id: &str, to: TaskPhase) {
    let from = {
        let mut g = GLOBAL.lock().unwrap();
        let Some(t) = g.tasks.get_mut(task_id) else { return };
        let from = t.phase;
        t.phase = to;
        from
    };
    push_event(&DownloadEvent::State {
        task_id: task_id.to_string(),
        from: phase_str(from).to_string(),
        to: phase_str(to).to_string(),
    });
}

// ============================================================
// 下载历史持久化（v2：重启恢复）
//
// 数据存储位置：由 Dart 通过 set_history_path 注入（app 数据目录
// `~/.local/share/ArchoeraMusic/download_history.json`），Rust 内部
// 原子写（tmp + rename）。只记录进行中任务（queued/resolving/running/
// paused）；done/failed/canceled 已从 tasks 移除，不落盘。
// ============================================================

#[derive(Serialize, Deserialize)]
struct HistoryEntry {
    task_id: String,
    request: EnqueueRequest,
    tmp_path: String,
}

#[derive(Serialize, Deserialize)]
struct HistoryFile {
    version: u32,
    tasks: Vec<HistoryEntry>,
}

/// 把进行中任务序列化到 history_path（原子写）。任何任务状态变化后调用。
fn persist_history() {
    // 先按记录上限裁剪 finished 条目（在途任务不受影响）
    prune_finished();
    let (path, data) = {
        let g = GLOBAL.lock().unwrap();
        let Some(path) = g.history_path.clone() else { return };
        let tasks: Vec<HistoryEntry> = g
            .tasks
            .iter()
            .filter(|(_, t)| {
                matches!(
                    t.phase,
                    TaskPhase::Queued
                        | TaskPhase::Resolving
                        | TaskPhase::Downloading
                        | TaskPhase::Paused
                )
            })
            .map(|(id, t)| HistoryEntry {
                task_id: id.clone(),
                request: t.request.clone(),
                tmp_path: t.tmp_path.to_string_lossy().into_owned(),
            })
            .collect();
        (path, HistoryFile { version: 1, tasks })
    };
    let Ok(json) = serde_json::to_string(&data) else { return };
    // 锁外写盘（IO 不进锁）
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = PathBuf::from(format!("{}.tmp", path.to_string_lossy()));
    if std::fs::write(&tmp, json.as_bytes()).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

/// 递归删除 rootDir 下不属于恢复集合的孤儿 .tmp（崩溃遗留、取消/改名残留）
fn cleanup_orphan_tmps(root: &PathBuf, kept: &HashSet<PathBuf>) {
    fn walk(dir: &PathBuf, kept: &HashSet<PathBuf>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_dir() {
                walk(&p, kept);
            } else if p.to_string_lossy().ends_with(".tmp") && !kept.contains(&p) {
                let _ = std::fs::remove_file(&p);
            }
        }
    }
    walk(root, kept);
}

// ============================================================
// resolvers 使用的全局状态访问器
// ============================================================

pub(crate) fn http_client() -> reqwest::Client {
    GLOBAL.lock()
        .unwrap()
        .client
        .clone()
        .expect("archoera_downloader_init 未调用")
}

pub(crate) fn kugou_mid() -> String {
    GLOBAL.lock()
        .unwrap()
        .kugou
        .mid
        .clone()
        .expect("archoera_downloader_init 未调用")
}

pub(crate) fn kugou_dfid() -> Option<String> {
    GLOBAL.lock().unwrap().kugou.dfid.clone()
}

pub(crate) fn set_kugou_dfid(dfid: Option<String>) {
    GLOBAL.lock().unwrap().kugou.dfid = dfid;
}

pub(crate) fn kugou_session() -> (String, String) {
    let g = GLOBAL.lock().unwrap();
    (g.kugou.userid.clone(), g.kugou.token.clone())
}

pub(crate) fn netease_cookie() -> Option<String> {
    GLOBAL.lock().unwrap().netease_cookie.clone()
}

fn runtime_handle() -> Option<Handle> {
    GLOBAL.lock().unwrap().runtime.as_ref().map(|rt| rt.handle().clone())
}

// ============================================================
// 路径 & 文件名（戒律 13.2：全在 Rust，Dart 只传 title/artist/quality）
// ============================================================

/// 非法字符替换（对齐设计稿 §3.3：\/:*?"<>| → _）
fn sanitize_filename(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c => c,
        })
        .collect()
}

/// 渲染文件名模板（占位符 {artist}/{title}/{album}，未知占位符原样保留）。
fn render_template(template: &str, artist: &str, title: &str, album: &str) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let mut rest = template;
    while let Some(pos) = rest.find('{') {
        out.push_str(&rest[..pos]);
        let Some(end) = rest[pos..].find('}') else {
            out.push_str(&rest[pos..]);
            rest = "";
            break;
        };
        match &rest[pos + 1..pos + end] {
            "artist" => out.push_str(artist),
            "title" => out.push_str(title),
            "album" => out.push_str(album),
            _ => out.push_str(&rest[pos..pos + end + 1]), // 未知占位符原样保留
        }
        rest = &rest[pos + end + 1..];
    }
    out.push_str(rest);
    out
}

/// 计算基础路径（不做同名去重）：root[/Platform|/Artist]/`<模板渲染>.{ext}`
///
/// [template] 为文件名模板（含 {artist}/{title}/{album} 占位符）；
/// 渲染后经 [sanitize_filename] 清洗，空结果回退 "untitled"。
fn compute_base_path(
    root: &PathBuf,
    strategy: i32,
    template: &str,
    request: &EnqueueRequest,
) -> PathBuf {
    let mut dir = root.clone();
    match strategy {
        // 1 = bySource：root/Platform/
        1 => dir.push(request.source.as_str().to_uppercase()),
        // 2 = byArtist：root/<artist>/（歌手名为空时回退平铺）
        2 => {
            let artist = sanitize_filename(request.artist.trim());
            if !artist.is_empty() {
                dir.push(artist);
            }
        }
        _ => {}
    }
    let artist = sanitize_filename(request.artist.trim());
    let title = sanitize_filename(request.title.trim());
    let album = sanitize_filename(request.album.as_deref().unwrap_or("").trim());
    let stem = render_template(template, &artist, &title, &album);
    // 模板字面量也可能含非法字符 → 整体清洗（\ / : * ? " < > | → _）
    let stem = sanitize_filename(&stem);
    // 艺术家为空时去除模板首尾的分隔符（如 "{artist} - {title}" → "Title"）
    let stem = stem.trim().trim_matches('-').trim().to_string();
    let stem = if stem.is_empty() { "untitled".to_string() } else { stem };
    let ext = request.quality.guess_ext();
    dir.join(format!("{stem}.{ext}"))
}

/// 计算最终 dest / tmp 路径：
/// - 目录策略：0=flat（root 下平铺），1=bySource（root/Platform/）
/// - 已存在同路径 → 追加 " (1)"、" (2)" ...（同名不覆盖）
fn compute_paths(
    root: &PathBuf,
    strategy: i32,
    template: &str,
    request: &EnqueueRequest,
) -> (PathBuf, PathBuf) {
    let base = compute_base_path(root, strategy, template, request);
    let mut n = 0usize;
    let dest = loop {
        let candidate = if n == 0 {
            base.clone()
        } else {
            let stem = base.file_stem().unwrap_or_default().to_string_lossy().into_owned();
            let ext = base.extension().unwrap_or_default().to_string_lossy().into_owned();
            base.with_file_name(format!("{stem} ({n}).{ext}"))
        };
        if !candidate.exists() {
            break candidate;
        }
        n += 1;
    };
    let tmp = PathBuf::from(format!("{}.tmp", dest.to_string_lossy()));
    (dest, tmp)
}

/// 替换扩展名为 [ext] 并做同名去重（已存在则追加 " (1)"、" (2)"...）。
/// 下载 URL 解析完成后音质可能降级，用实际格式校正 dest 扩展名时调用。
fn compute_unique_dest(original: &PathBuf, ext: &str) -> PathBuf {
    let stem = original
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let mut n = 0usize;
    loop {
        let candidate = if n == 0 {
            original.with_file_name(format!("{stem}.{ext}"))
        } else {
            original.with_file_name(format!("{stem} ({n}).{ext}"))
        };
        if !candidate.exists() {
            return candidate;
        }
        n += 1;
    }
}

// ============================================================
// 并发槽 & 调度
// ============================================================

fn spawn_task(task_id: String) {
    let Some(handle) = runtime_handle() else { return };
    let (request, cancel, paused, dest, tmp) = {
        let g = GLOBAL.lock().unwrap();
        let Some(t) = g.tasks.get(&task_id) else { return };
        (
            t.request.clone(),
            t.cancel.clone(),
            t.paused.clone(),
            t.dest_path.clone(),
            t.tmp_path.clone(),
        )
    };
    let run = async move {
        run_task(&task_id, request, cancel, paused, dest, tmp).await;
        let _ = {
            let mut g = GLOBAL.lock().unwrap();
            g.running = g.running.saturating_sub(1);
        };
        pick_next();
    };
    handle.spawn(run);
}

/// 拉 queued 下一条进入 resolving（任何释放并发槽的路径都必须调用）
fn pick_next() {
    if runtime_handle().is_none() {
        return;
    }
    loop {
        let id = {
            let mut g = GLOBAL.lock().unwrap();
            if g.running >= g.max_concurrent {
                return;
            }
            let Some(id) = g
                .tasks
                .iter()
                .find(|(_, t)| t.phase == TaskPhase::Queued)
                .map(|(id, _)| id.clone())
            else {
                return;
            };
            g.tasks.get_mut(&id).unwrap().phase = TaskPhase::Resolving;
            g.running += 1;
            id
        };
        push_event(&DownloadEvent::State {
            task_id: id.clone(),
            from: "queued".to_string(),
            to: "resolving".to_string(),
        });
        spawn_task(id);
    }
}

// ============================================================
// 单任务执行：resolving → downloading → done/error（所有路径释放并发槽）
// ============================================================

async fn run_task(
    task_id: &str,
    request: EnqueueRequest,
    cancel: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    dest: PathBuf,
    tmp: PathBuf,
) {
    set_phase(task_id, TaskPhase::Resolving);

    let client = http_client();
    let resolver: Box<dyn PlatformUrlResolver> = match request.source {
        SourcePlatform::Kugou => Box::new(KugouResolver),
        SourcePlatform::Netease => Box::new(NeteaseResolver),
    };

    let resolved = match resolver.resolve_play_url(&request, &cancel).await {
        Ok(r) => r,
        Err(e) => {
            set_phase(task_id, TaskPhase::Failed);
            if cancel.load(Ordering::Relaxed) {
                push_error(task_id, "已取消", false, "resolving");
            } else {
                push_error(task_id, &e.to_string(), true, "resolving");
            }
            persist_history();
            return;
        }
    };
    if cancel.load(Ordering::Relaxed) {
        set_phase(task_id, TaskPhase::Failed);
        push_error(task_id, "已取消", false, "resolving");
        persist_history();
        return;
    }
    // resolving 期间被暂停 → 置 Paused（保留 .tmp 供恢复续传）
    if paused.load(Ordering::Relaxed) {
        set_phase(task_id, TaskPhase::Paused);
        persist_history();
        return;
    }

    set_phase(task_id, TaskPhase::Downloading);

    // 实际命中档位与请求档位不同（音质降级）时，扩展名跟随实际内容，
    // 避免「无损」降级后 .flac 文件里是 mp3（原版由 declaredFormat 保证一致）。
    let (dest, tmp) = if resolved.file_ext.eq_ignore_ascii_case(
        &dest
            .extension()
            .map(|e| e.to_string_lossy().into_owned())
            .unwrap_or_default(),
    ) {
        (dest, tmp)
    } else {
        let new_dest = compute_unique_dest(&dest, &resolved.file_ext);
        let new_tmp = PathBuf::from(format!("{}.tmp", new_dest.to_string_lossy()));
        // 同步 TaskEntry（persist_history / 取消清理依赖 dest/tmp 一致性）
        if let Some(t) = GLOBAL.lock().unwrap().tasks.get_mut(task_id) {
            t.dest_path = new_dest.clone();
            t.tmp_path = new_tmp.clone();
        }
        (new_dest, new_tmp)
    };
    log::debug!(
        "解析完成: quality_key={} file_ext={} → dest={}",
        resolved.quality_key,
        resolved.file_ext,
        dest.display()
    );

    match download_to_file(&client, &resolved, &dest, &tmp, &cancel, &paused, task_id).await {
        Ok(size) => {
            // v2.1：下载完成后自主寻找元数据（内嵌标签 + 平台 API）并写完整标签
            // （标签/封面/歌词），best-effort 不阻断下载。enrich 在 rename 落盘后
            // 执行，保证读到的即最终文件。
            let enriched = metadata::enrich_file(&client, &request, &dest).await;
            if let Err(e) = tag::write_tags(
                &dest,
                &tag::TagContent {
                    title: &enriched.title,
                    artist: &enriched.artist,
                    album: &enriched.album,
                    lyrics: enriched.lyrics.as_deref(),
                    cover: enriched
                        .cover
                        .as_ref()
                        .map(|(data, mime)| (data.as_slice(), mime.as_str())),
                },
            ) {
                log::warn!(
                    "写标签失败（不阻断下载）: {} title={} artist={} album={} 有歌词={} 有封面={} err={e}",
                    dest.display(),
                    enriched.title,
                    enriched.artist,
                    enriched.album,
                    enriched.lyrics.is_some(),
                    enriched.cover.is_some(),
                );
            } else {
                log::debug!("写标签完成: {}", dest.display());
            }
            set_phase(task_id, TaskPhase::Done);
            let _ = {
                let mut g = GLOBAL.lock().unwrap();
                g.tasks.remove(task_id)
            };
            push_event(&DownloadEvent::Done {
                task_id: task_id.to_string(),
                file_path: dest.to_string_lossy().into_owned(),
                file_size: size,
                actual_quality: resolved.quality_key,
                title: enriched.title,
                artist: enriched.artist,
                album: enriched.album,
            });
        }
        Err(e) => {
            if e.paused {
                // 暂停：保留 .tmp 供恢复续传，相位落 Paused（不发 error）
                set_phase(task_id, TaskPhase::Paused);
                persist_history();
                return;
            }
            // 失败相位必须先落（retry 依赖 phase == Failed/Canceled/Paused 判断）
            set_phase(task_id, TaskPhase::Failed);
            if e.cancel {
                push_error(task_id, "已取消", false, "downloading");
            } else {
                push_error(task_id, &e.msg, true, "downloading");
            }
        }
    }
    persist_history();
}

struct DownloadError {
    msg: String,
    cancel: bool,
    /// true = 暂停退出（保留 .tmp 供续传；不会推送 error，由调用方置 Paused 相位）
    paused: bool,
}

fn max_speed_bytes() -> Option<u64> {
    let v = GLOBAL.lock().unwrap().max_speed;
    if v == 0 {
        None
    } else {
        Some(v)
    }
}

/// 流式下载：HTTP GET → tmpPath → fsync → 原子 rename（参考 download-engine）
///
/// v2 增强：
/// - **断点续传**：tmpPath 已存在 → 带 `Range: bytes=<len>-` 请求；服务器返回 206
///   则以追加模式续写，received 从已有字节起算；服务器忽略 Range（200）则从头重写。
/// - **限速**：读入全局限速值，按窗口累计字节数 sleep 到目标耗时。
/// - **暂停**：paused 标志置位后在下一个 await 点退出，**保留 .tmp**（供恢复续传）。
async fn download_to_file(
    client: &reqwest::Client,
    resolved: &ResolvedUrl,
    dest: &PathBuf,
    tmp: &PathBuf,
    cancel: &AtomicBool,
    paused: &AtomicBool,
    task_id: &str,
) -> std::result::Result<u64, DownloadError> {
    // 已存在的 .tmp → 尝试断点续传
    let existing = tokio::fs::metadata(tmp)
        .await
        .map(|m| m.len())
        .unwrap_or(0);

    let mut req = client.get(&resolved.url).timeout(Duration::from_secs(30));
    if existing > 0 {
        req = req.header(reqwest::header::RANGE, format!("bytes={existing}-"));
    }
    for (k, v) in &resolved.extra_headers {
        req = req.header(k, v);
    }
    let resp = match req.send().await {
        Ok(r) => r,
        Err(e) => return Err(DownloadError { msg: format!("下载请求失败: {e}"), cancel: false, paused: false }),
    };
    let status = resp.status();
    if !status.is_success() {
        return Err(DownloadError { msg: format!("下载 HTTP {status}"), cancel: false, paused: false });
    }
    // resume 判定：206 Partial Content（服务器接受 Range）
    let resume = existing > 0 && status == reqwest::StatusCode::PARTIAL_CONTENT;
    // total：206 时 content-length 是剩余量，需加上已有字节
    let total = if resume {
        resp.content_length().map(|cl| existing + cl).or(resolved.file_size)
    } else {
        resp.content_length().or(resolved.file_size)
    };

    if let Some(parent) = dest.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    let mut file = if resume {
        match tokio::fs::OpenOptions::new().append(true).open(tmp).await {
            Ok(f) => f,
            Err(e) => return Err(DownloadError { msg: format!("打开临时文件失败: {e}"), cancel: false, paused: false }),
        }
    } else {
        match tokio::fs::File::create(tmp).await {
            Ok(f) => f,
            Err(e) => return Err(DownloadError { msg: format!("创建临时文件失败: {e}"), cancel: false, paused: false }),
        }
    };

    let mut stream = resp.bytes_stream();
    let mut received: u64 = if resume { existing } else { 0 };
    let mut last_push = Instant::now();
    let mut last_received = received;
    let mut pushed_any = false;
    // 限速窗口：窗口内累计字节 / 窗口耗时 = 实际速度，超限则 sleep 补齐
    let mut window_start = Instant::now();
    let mut window_bytes: u64 = 0;

    loop {
        if paused.load(Ordering::Relaxed) {
            drop(file);
            // 保留 .tmp，返回 paused 退出（run_task 置 Paused 相位，不推 error）
            return Err(DownloadError { msg: "已暂停".to_string(), cancel: false, paused: true });
        }
        if cancel.load(Ordering::Relaxed) {
            drop(file);
            let _ = tokio::fs::remove_file(tmp).await;
            return Err(DownloadError { msg: "已取消".to_string(), cancel: true, paused: false });
        }
        let chunk = match tokio::time::timeout(Duration::from_secs(30), stream.next()).await {
            Err(_) => {
                drop(file);
                return Err(DownloadError { msg: "读取超时".to_string(), cancel: false, paused: false });
            }
            Ok(None) => break,
            Ok(Some(Err(e))) => {
                drop(file);
                return Err(DownloadError { msg: format!("流读取错误: {e}"), cancel: false, paused: false });
            }
            Ok(Some(Ok(c))) => c,
        };
        if let Err(e) = file.write_all(&chunk).await {
            drop(file);
            return Err(DownloadError { msg: format!("写文件失败: {e}"), cancel: false, paused: false });
        }
        received += chunk.len() as u64;
        // 限速（bytes/sec；0 = 不限速）：目标耗时 = 窗口累计字节 / 限速值
        window_bytes += chunk.len() as u64;
        if let Some(limit) = max_speed_bytes() {
            let elapsed = window_start.elapsed();
            let target = Duration::from_secs_f64(window_bytes as f64 / limit as f64);
            if elapsed < target {
                tokio::time::sleep(target - elapsed).await;
            } else if elapsed > target.saturating_mul(2) {
                // 速度远低于限速（网络慢/上游受限）→ 重置窗口，避免长时间 sleep 补偿
                window_start = Instant::now();
                window_bytes = 0;
            }
        }
        // 进度节流 ≥500ms（Rust 侧，戒律 13.1：非轮询）；附带实时速度
        if !pushed_any || last_push.elapsed() >= Duration::from_millis(500) {
            pushed_any = true;
            let dt = last_push.elapsed().as_secs_f64().max(0.1);
            let speed = ((received - last_received) as f64 / dt) as u64;
            last_push = Instant::now();
            last_received = received;
            push_event(&DownloadEvent::Progress {
                task_id: task_id.to_string(),
                received,
                total,
                speed,
            });
        }
    }

    // fsync + 原子落盘（戒律 13.3：不留下半写文件）
    if let Err(e) = file.sync_all().await {
        drop(file);
        let _ = tokio::fs::remove_file(tmp).await;
        return Err(DownloadError { msg: format!("fsync 失败: {e}"), cancel: false, paused: false });
    }
    drop(file);
    // 优先 rename（同盘原子）；跨盘（EXDEV）失败时 copy + fsync + remove 兜底
    if let Err(e) = finalize_file(tmp, dest).await {
        let _ = tokio::fs::remove_file(tmp).await;
        return Err(DownloadError { msg: format!("落盘失败（rename/copy 兜底）: {e}"), cancel: false, paused: false });
    }
    Ok(received)
}

/// 临时文件 → 目标文件：先尝试原子 rename；跨盘失败则 copy → fsync → remove 兜底。
async fn finalize_file(tmp: &PathBuf, dest: &PathBuf) -> std::io::Result<()> {
    match tokio::fs::rename(tmp, dest).await {
        Ok(()) => Ok(()),
        Err(_) => {
            let mut src = tokio::fs::File::open(tmp).await?;
            let mut out = tokio::fs::File::create(dest).await?;
            tokio::io::copy(&mut src, &mut out).await?;
            out.sync_all().await?;
            drop(out);
            tokio::fs::remove_file(tmp).await?;
            Ok(())
        }
    }
}

// ============================================================
// §8.1 C ABI 导出函数
// ============================================================

#[no_mangle]
pub extern "C" fn archoera_downloader_init(
    root_dir: *const c_char,
    subdir_strategy: c_int,
    max_concurrent: c_int,
    event_cb: *mut c_void,
    free_fn: *mut c_void,
) -> c_int {
    let _ = free_fn; // 保持签名兼容：事件/任务 id 的 C 字符串一律用 CString::from_raw 释放
    if root_dir.is_null() || event_cb.is_null() {
        return -1;
    }

    // 注册 stderr 日志器（幂等，仅首次生效）
    LOGGER_ONCE.call_once(|| {
        log::set_boxed_logger(Box::new(StderrLogger)).ok();
        log::set_max_level(log::LevelFilter::Debug);
    });
    let root_dir_str = match unsafe { CStr::from_ptr(root_dir) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };

    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(_) => return -3,
    };

    let client = match reqwest::Client::builder()
        // 对齐 Dart HttpClient：仅 HTTP/1.1（酷狗风控对 HTTP/2 请求返回空 data）
        .http1_only()
        .build()
    {
        Ok(c) => c,
        Err(_) => return -4,
    };

    let mid = kg::kg_calc_mid(&kg::kg_random_string(16));

    let mut guard = GLOBAL.lock().unwrap();
    guard.runtime = Some(rt);
    guard.client = Some(client);
    guard.root_dir = Some(PathBuf::from(root_dir_str));
    guard.subdir_strategy = subdir_strategy;
    guard.max_concurrent = (max_concurrent.max(1)) as usize;
    guard.event_cb = Some(unsafe {
        std::mem::transmute::<*mut c_void, unsafe extern "C" fn(*mut c_char)>(event_cb)
    });
    guard.kugou.mid = Some(mid);
    guard.tasks.clear();
    guard.running = 0;
    0
}

/// 入队下载任务（§3.2 流程：去重 → already → 路径 → 并发槽分配）
#[no_mangle]
pub extern "C" fn archoera_downloader_enqueue(
    request_json: *const c_char,
    out_task_id: *mut *mut c_char,
) -> c_int {
    if request_json.is_null() || out_task_id.is_null() {
        return -1;
    }
    let req_str = match unsafe { CStr::from_ptr(request_json) }.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let request: EnqueueRequest = match serde_json::from_str(req_str) {
        Ok(r) => r,
        Err(_) => return -10,
    };

    match internal_enqueue(request) {
        Ok(task_id) => {
            let ctask = match CString::new(task_id) {
                Ok(c) => c,
                Err(_) => return -3,
            };
            unsafe {
                *out_task_id = ctask.into_raw();
            }
            0
        }
        Err(code) => code,
    }
}

fn internal_enqueue(request: EnqueueRequest) -> std::result::Result<String, c_int> {
    let (root_dir, strategy, template) = {
        let g = GLOBAL.lock().unwrap();
        (
            g.root_dir.clone(),
            g.subdir_strategy,
            g.filename_template.clone(),
        )
    };
    let root = root_dir.ok_or(-11)?; // 未 init

    let (mut dest, mut tmp) = compute_paths(&root, strategy, &template, &request);

    // ① 去重检查：同 trackId + 同目标路径的任务仍在进行中 → 直接返回已有 taskId
    {
        let g = GLOBAL.lock().unwrap();
        if let Some((tid, _)) = g.tasks.iter().find(|(_, t)| {
            (t.phase == TaskPhase::Queued
                || t.phase == TaskPhase::Resolving
                || t.phase == TaskPhase::Downloading)
                && t.request.track_id == request.track_id
                && t.dest_path == dest
        }) {
            return Ok(tid.clone());
        }
    }

    // 期望大小（用声明 sizes 的最高档判断"已完成"）
    let expected_size = request
        .extra
        .sizes
        .get(request.quality.quality_chain()[0])
        .copied();

    // ② 已完成去重：destPath 存在且 fsize == expected_size → already 事件
    if let Some(sz) = expected_size {
        if std::fs::metadata(&dest).map(|m| m.len() == sz).unwrap_or(false) {
            let task_id = uuid::Uuid::new_v4().to_string();
            push_event(&DownloadEvent::Already {
                task_id: task_id.clone(),
                file_path: dest.to_string_lossy().into_owned(),
            });
            return Ok(task_id);
        }
    }
    // 同名文件不覆盖：base 名已存在（大小不符）→ 换序号名，直到 tmp 也不冲突
    while dest.exists() {
        let (d2, t2) = compute_paths(&root, strategy, &template, &request);
        dest = d2;
        tmp = t2;
        break;
    }

    let task_id = uuid::Uuid::new_v4().to_string();
    let cancel = Arc::new(AtomicBool::new(false));
    let paused = Arc::new(AtomicBool::new(false));
    let mut g = GLOBAL.lock().unwrap();
    g.task_seq += 1;
    let seq = g.task_seq;
    g.tasks.insert(
        task_id.clone(),
        TaskEntry {
            request,
            dest_path: dest,
            tmp_path: tmp,
            cancel,
            paused,
            phase: TaskPhase::Queued,
            seq,
        },
    );

    // ③ 并发槽分配
    let need_start = if g.running < g.max_concurrent {
        g.running += 1;
        true
    } else {
        false
    };
    drop(g);

    push_event(&DownloadEvent::State {
        task_id: task_id.clone(),
        from: String::new(),
        to: if need_start { "resolving" } else { "queued" }.to_string(),
    });
    if need_start {
        spawn_task(task_id.clone());
    }
    persist_history();
    Ok(task_id)
}

/// 取消任务：置 cancel 标志（运行中在下一个 await 点退出并删 tmp）；
/// queued / paused 直接移除（paused 任务的 .tmp 一并删除）。
#[no_mangle]
pub extern "C" fn archoera_downloader_cancel(task_id: *const c_char) -> c_int {
    if task_id.is_null() {
        return -1;
    }
    let tid = match unsafe { CStr::from_ptr(task_id) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };
    let was_idle = {
        let mut g = GLOBAL.lock().unwrap();
        let Some(t) = g.tasks.get_mut(&tid) else { return -20 };
        let was_idle = t.phase == TaskPhase::Queued || t.phase == TaskPhase::Paused;
        t.cancel.store(true, Ordering::Relaxed);
        was_idle
    };
    if was_idle {
        let tmp = {
            let mut g = GLOBAL.lock().unwrap();
            g.tasks.remove(&tid).map(|t| t.tmp_path)
        };
        if let Some(t) = tmp {
            let _ = std::fs::remove_file(&t);
        }
        push_error(&tid, "已取消", false, "queued");
        persist_history();
    }
    0
}

/// 重试失败/已取消/已暂停任务：**复用原 taskId**（UI 任务状态机依赖 taskId 稳定）——
/// 相位重置为 queued，重置取消/暂停标志，按并发槽分配走一遍 resolving → downloading。
/// 已暂停任务恢复时 .tmp 存在 → 下载阶段自动断点续传。
#[no_mangle]
pub extern "C" fn archoera_downloader_retry(task_id: *const c_char) -> c_int {
    if task_id.is_null() {
        return -1;
    }
    let tid = match unsafe { CStr::from_ptr(task_id) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };
    match retry_internal(&tid) {
        Ok(()) => {
            persist_history();
            0
        }
        Err(code) => code,
    }
}

/// 内部重试（[archoera_downloader_retry] 与「全部开始」共用）。
fn retry_internal(tid: &str) -> std::result::Result<(), c_int> {
    let (from, need_start) = {
        let mut g = GLOBAL.lock().unwrap();
        let Some(t) = g.tasks.get_mut(tid) else {
            return Err(-20); // 任务不存在（已完成已移除 / 从未入队）
        };
        if t.phase != TaskPhase::Failed
            && t.phase != TaskPhase::Canceled
            && t.phase != TaskPhase::Paused
        {
            return Err(-21); // 任务仍在进行中，不允许重试
        }
        let from = phase_str(t.phase).to_string();
        t.phase = TaskPhase::Queued;
        t.cancel = Arc::new(AtomicBool::new(false));
        t.paused = Arc::new(AtomicBool::new(false));
        let need_start = if g.running < g.max_concurrent {
            g.running += 1;
            true
        } else {
            false
        };
        (from, need_start)
    };
    push_event(&DownloadEvent::State {
        task_id: tid.to_string(),
        from,
        to: if need_start { "resolving" } else { "queued" }.to_string(),
    });
    if need_start {
        spawn_task(tid.to_string());
    }
    Ok(())
}

/// 移除下载任务：立即从任务表删除（running/resolving 同时置取消标志，
/// 下载循环在下一个检查点退出）；删除其 .tmp 缓存；[delete_file] 为 true 时
/// **精确**删除该任务记录的目标文件（仅 dest_path 本身，不做模糊匹配/目录扫描）。
#[no_mangle]
pub extern "C" fn archoera_downloader_remove(task_id: *const c_char, delete_file: bool) -> c_int {
    if task_id.is_null() {
        return -1;
    }
    let tid = match unsafe { CStr::from_ptr(task_id) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };
    {
        let mut g = GLOBAL.lock().unwrap();
        let Some(t) = g.tasks.remove(&tid) else {
            return -20; // 任务不存在
        };
        t.cancel.store(true, Ordering::Relaxed);
        let _ = std::fs::remove_file(&t.tmp_path);
        if delete_file {
            let _ = std::fs::remove_file(&t.dest_path);
        }
    }
    persist_history();
    0
}

/// 一键清空下载任务：所有任务从任务表删除并清理 .tmp 缓存；
/// [delete_files] 为 true 时**精确**删除各任务记录的目标文件。
#[no_mangle]
pub extern "C" fn archoera_downloader_clear(delete_files: bool) -> c_int {
    {
        let mut g = GLOBAL.lock().unwrap();
        for (_, t) in g.tasks.drain() {
            t.cancel.store(true, Ordering::Relaxed);
            let _ = std::fs::remove_file(&t.tmp_path);
            if delete_files {
                let _ = std::fs::remove_file(&t.dest_path);
            }
        }
        g.running = 0;
    }
    persist_history();
    0
}

/// 全部暂停：queued 立即转 Paused；resolving/downloading 置暂停标志
/// （下载循环在下一个检查点退出并**保留** .tmp 供续传）。
#[no_mangle]
pub extern "C" fn archoera_downloader_pause_all() -> c_int {
    let mut switched = Vec::new();
    {
        let mut g = GLOBAL.lock().unwrap();
        let ids: Vec<String> = g.tasks.iter().map(|(id, _)| id.clone()).collect();
        for id in ids {
            let Some(t) = g.tasks.get_mut(&id) else { continue };
            match t.phase {
                TaskPhase::Queued => {
                    t.phase = TaskPhase::Paused;
                    switched.push(id);
                }
                TaskPhase::Resolving | TaskPhase::Downloading => {
                    t.paused.store(true, Ordering::Relaxed);
                }
                _ => {}
            }
        }
    }
    for id in switched {
        push_event(&DownloadEvent::State {
            task_id: id,
            from: "queued".to_string(),
            to: "paused".to_string(),
        });
    }
    persist_history();
    0
}

/// 全部开始：恢复所有暂停任务（续传）并重试所有失败任务。
#[no_mangle]
pub extern "C" fn archoera_downloader_resume_all() -> c_int {
    let ids: Vec<String> = {
        let g = GLOBAL.lock().unwrap();
        g.tasks
            .iter()
            .filter(|(_, t)| matches!(t.phase, TaskPhase::Paused | TaskPhase::Failed))
            .map(|(id, _)| id.clone())
            .collect()
    };
    for id in ids {
        let _ = retry_internal(&id);
    }
    persist_history();
    0
}

/// 设置下载记录上限（finished 条目超过该值淘汰最旧；<=0 恢复默认 100）。
#[no_mangle]
pub extern "C" fn archoera_downloader_set_history_limit(limit: c_int) -> c_int {
    {
        let mut g = GLOBAL.lock().unwrap();
        g.history_limit = if limit > 0 { limit as usize } else { 100 };
    }
    prune_finished(); // 立即生效
    persist_history();
    0
}

/// 暂停任务（v2）：运行中在下一个 await 点退出并**保留 .tmp** 供恢复续传；
/// queued 直接置 Paused（不占并发槽）；resolving 置暂停标志。
#[no_mangle]
pub extern "C" fn archoera_downloader_pause(task_id: *const c_char) -> c_int {
    if task_id.is_null() {
        return -1;
    }
    let tid = match unsafe { CStr::from_ptr(task_id) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };
    {
        let mut g = GLOBAL.lock().unwrap();
        let Some(t) = g.tasks.get_mut(&tid) else {
            return -20;
        };
        match t.phase {
            TaskPhase::Queued => {
                t.phase = TaskPhase::Paused;
            }
            TaskPhase::Resolving | TaskPhase::Downloading => {
                // 置暂停标志；run_task 在下一个检查点置 Paused 相位
                t.paused.store(true, Ordering::Relaxed);
            }
            _ => return -21, // 非进行中（已完成/失败/已取消/已暂停）
        }
    }
    // queued → paused 是即时相位切换，同步推 state；running 由 run_task 推
    persist_history();
    0
}

/// 设置下载历史文件路径（重启恢复用；None 不持久化）。可多次调，覆盖上一次。
#[no_mangle]
pub extern "C" fn archoera_downloader_set_history_path(path: *const c_char) -> c_int {
    if path.is_null() {
        return -1;
    }
    let p = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };
    GLOBAL.lock().unwrap().history_path = Some(PathBuf::from(p));
    0
}

/// 设置全局限速（bytes/sec；0 = 不限速）。可多次调，立即生效。
#[no_mangle]
pub extern "C" fn archoera_downloader_set_max_speed(bytes_per_sec: i64) -> c_int {
    GLOBAL.lock().unwrap().max_speed = if bytes_per_sec > 0 { bytes_per_sec as u64 } else { 0 };
    0
}

/// 设置文件名模板（占位符 {artist}/{title}/{album}；空串恢复默认）。
/// 只影响之后入队的任务，不回溯已有任务。
#[no_mangle]
pub extern "C" fn archoera_downloader_set_filename_template(template: *const c_char) -> c_int {
    if template.is_null() {
        return -1;
    }
    let t = match unsafe { CStr::from_ptr(template) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };
    let mut g = GLOBAL.lock().unwrap();
    g.filename_template = if t.trim().is_empty() {
        "{artist} - {title}".to_string()
    } else {
        t
    };
    0
}

/// 重启恢复：读 history_path 中的进行中任务，重建任务并续传；同时清理孤儿 .tmp。
/// 返回恢复的任务数；错误返回负错误码。
#[no_mangle]
pub extern "C" fn archoera_downloader_resume_from_history() -> c_int {
    let path = {
        let g = GLOBAL.lock().unwrap();
        match &g.history_path {
            Some(p) => p.clone(),
            None => return -30, // 未设置 history 路径
        }
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return 0; // 无历史文件
    };
    let parsed: HistoryFile = match serde_json::from_str(&text) {
        Ok(h) => h,
        Err(_) => {
            let _ = std::fs::remove_file(&path);
            return 0;
        }
    };
    // 恢复后清空历史，避免重复恢复
    let _ = std::fs::write(&path, r#"{"version":1,"tasks":[]}"#);
    if parsed.tasks.is_empty() {
        return 0;
    }

    let mut recovered = 0i32;
    let mut kept_tmp: HashSet<PathBuf> = HashSet::new();

    for entry in parsed.tasks {
        let tmp = PathBuf::from(&entry.tmp_path);
        // dest = tmp 去掉 `.tmp` 后缀
        let mut dest = tmp.clone();
        dest.set_extension("");
        if dest.exists() {
            push_event(&DownloadEvent::Already {
                task_id: entry.task_id.clone(),
                file_path: dest.to_string_lossy().into_owned(),
            });
            continue;
        }
        kept_tmp.insert(tmp.clone());

        let mut g = GLOBAL.lock().unwrap();
        if g.tasks.contains_key(&entry.task_id) {
            continue;
        }
        g.task_seq += 1;
        let seq = g.task_seq;
        g.tasks.insert(
            entry.task_id.clone(),
            TaskEntry {
                request: entry.request,
                dest_path: dest,
                tmp_path: tmp,
                cancel: Arc::new(AtomicBool::new(false)),
                paused: Arc::new(AtomicBool::new(false)),
                phase: TaskPhase::Queued,
                seq,
            },
        );
        let need_start = g.running < g.max_concurrent;
        if need_start {
            g.running += 1;
        }
        drop(g);

        push_event(&DownloadEvent::State {
            task_id: entry.task_id.clone(),
            from: String::new(),
            to: if need_start { "resolving" } else { "queued" }.to_string(),
        });
        if need_start {
            spawn_task(entry.task_id.clone());
        }
        recovered += 1;
    }

    // 孤儿 .tmp 清理：rootDir 下不属于恢复集合的 .tmp 一律删除
    let root = GLOBAL.lock().unwrap().root_dir.clone();
    if let Some(root) = root {
        cleanup_orphan_tmps(&root, &kept_tmp);
    }
    persist_history();
    recovered
}

#[no_mangle]
pub extern "C" fn archoera_downloader_set_kugou_session(
    userid: *const c_char,
    token: *const c_char,
) -> c_int {
    if userid.is_null() || token.is_null() {
        return -1;
    }
    let uid = match unsafe { CStr::from_ptr(userid) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };
    let tok = match unsafe { CStr::from_ptr(token) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -3,
    };
    let mut g = GLOBAL.lock().unwrap();
    g.kugou.userid = uid;
    g.kugou.token = tok;
    0
}

#[no_mangle]
pub extern "C" fn archoera_downloader_set_netease_cookie(cookie_header: *const c_char) -> c_int {
    if cookie_header.is_null() {
        return -1;
    }
    let ck = match unsafe { CStr::from_ptr(cookie_header) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return -2,
    };
    let mut g = GLOBAL.lock().unwrap();
    g.netease_cookie = Some(ck);
    0
}

/// 释放 Rust 分配的 C 字符串（task_id、回调事件 ptr 都要调）
#[no_mangle]
pub extern "C" fn archoera_downloader_free(ptr: *mut c_void) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr as *mut c_char);
    }
}

/// 销毁（App 退出）：abort 全部任务、Drop tokio Runtime、释放全局单例
#[no_mangle]
pub extern "C" fn archoera_downloader_destroy() {
    let mut g = GLOBAL.lock().unwrap();
    g.event_cb = None;
    g.kugou = KugouState { mid: None, dfid: None, userid: String::new(), token: String::new() };
    g.netease_cookie = None;
    g.tasks.clear();
    g.running = 0;
    g.root_dir = None;
    g.client = None;
    g.runtime = None; // Drop Runtime：取消所有在途任务
}

#[cfg(test)]
mod template_tests {
    use super::render_template;
    use super::sanitize_filename;

    #[test]
    fn render_default() {
        assert_eq!(
            render_template("{artist} - {title}", "周杰伦", "晴天", ""),
            "周杰伦 - 晴天"
        );
    }

    #[test]
    fn render_album_and_missing() {
        // 空 artist → 模板渲染后由调用方 trim 分隔符，此处只验证渲染本身
        assert_eq!(render_template("{title}", "周杰伦", "晴天", ""), "晴天");
        assert_eq!(
            render_template("{album}/{title}", "周杰伦", "晴天", "叶惠美"),
            "叶惠美/晴天"
        );
    }

    #[test]
    fn render_unknown_placeholder_preserved() {
        assert_eq!(
            render_template("{artist} - {foo} {title}", "周杰伦", "晴天", ""),
            "周杰伦 - {foo} 晴天"
        );
    }

    #[test]
    fn sanitize_illegal_chars() {
        assert_eq!(sanitize_filename("a/b\\c:d*e?f\"g<h>i|j"), "a_b_c_d_e_f_g_h_i_j");
    }
}
