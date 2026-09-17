//! ArchoeraOS 冒烟客户端。
//!
//! 一个刻意保持最小的 Wayland 客户端：创建 xdg-toplevel，填充动画的 `wl_shm`
//! 缓冲区并持续提交。它不含任何业务逻辑，唯一目的是验证 `archoera-shell` 合成器
//! 的「客户端面渲染通路」——xdg-shell 配置、kiosk 全屏策略、shm 缓冲、帧回调
//! ——是否完整可用，为随后接入 Flutter（ArchoeraMusic）铺路。
//!
//! 用法：
//! ```text
//! archoera-smoke [--socket <name>]
//! ```

use std::{convert::TryInto, time::Duration};

use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_output, delegate_registry, delegate_shm, delegate_xdg_shell,
    delegate_xdg_window,
    output::{OutputHandler, OutputState},
    reexports::{
        calloop::{EventLoop, LoopHandle},
        calloop_wayland_source::WaylandSource,
    },
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    shell::{
        xdg::{
            window::{Window, WindowConfigure, WindowDecorations, WindowHandler},
            XdgShell,
        },
        WaylandSurface,
    },
    shm::{
        slot::{Buffer, SlotPool},
        Shm, ShmHandler,
    },
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_output, wl_shm, wl_surface},
    Connection, QueueHandle,
};

fn main() {
    // 允许 `--socket <name>` 指定 WAYLAND_DISPLAY（与 archoera-control 一致）。
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socket" | "-s" => {
                let Some(name) = args.next() else {
                    eprintln!("archoera-smoke: --socket 需要一个参数");
                    std::process::exit(2);
                };
                std::env::set_var("WAYLAND_DISPLAY", name);
            }
            "-h" | "--help" => {
                println!("用法: archoera-smoke [--socket <name>]");
                return;
            }
            other => {
                eprintln!("archoera-smoke: 未知参数 `{other}`");
                std::process::exit(2);
            }
        }
    }

    if let Err(err) = run() {
        eprintln!("archoera-smoke: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let conn = Connection::connect_to_env().map_err(|e| {
        anyhow::anyhow!("连接 Wayland 失败（WAYLAND_DISPLAY 未指向 archoera-shell？）: {e}")
    })?;

    let (globals, event_queue) =
        registry_queue_init(&conn).map_err(|e| anyhow::anyhow!("初始化 registry 失败: {e}"))?;
    let qh = event_queue.handle();

    let mut event_loop: EventLoop<Smoke> = EventLoop::try_new()?;
    let loop_handle = event_loop.handle();
    WaylandSource::new(conn.clone(), event_queue)
        .insert(loop_handle.clone())
        .map_err(|e| anyhow::anyhow!("注册 Wayland 事件源失败: {e}"))?;

    let compositor = CompositorState::bind(&globals, &qh)
        .map_err(|e| anyhow::anyhow!("wl_compositor 不可用: {e}"))?;
    let xdg_shell =
        XdgShell::bind(&globals, &qh).map_err(|e| anyhow::anyhow!("xdg-shell 不可用: {e}"))?;
    let shm = Shm::bind(&globals, &qh).map_err(|e| anyhow::anyhow!("wl_shm 不可用: {e}"))?;

    let surface = compositor.create_surface(&qh);
    let window = xdg_shell.create_window(surface, WindowDecorations::RequestServer, &qh);
    window.set_title("ArchoeraOS 冒烟客户端");
    window.set_app_id("org.archoera.Smoke");
    // 无 buffer 的首次 commit 触发合成器下发初始 configure。
    window.commit();

    let pool = SlotPool::new(64 * 64 * 4, &shm)?;

    let mut state = Smoke {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        shm,
        window,
        pool,
        buffer: None,
        width: 64,
        height: 64,
        phase: 0,
        first_configure: true,
        exit: false,
        loop_handle,
    };

    println!("ArchoeraOS 冒烟客户端已连接（Ctrl-C 退出）");
    while !state.exit {
        event_loop.dispatch(Duration::from_millis(16), &mut state)?;
    }
    println!("冒烟客户端退出");
    Ok(())
}

struct Smoke {
    registry_state: RegistryState,
    output_state: OutputState,
    shm: Shm,
    window: Window,
    pool: SlotPool,
    buffer: Option<Buffer>,
    width: u32,
    height: u32,
    phase: u32,
    first_configure: bool,
    exit: bool,
    #[allow(dead_code)]
    loop_handle: LoopHandle<'static, Smoke>,
}

impl CompositorHandler for Smoke {
    fn scale_factor_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _new_factor: i32,
    ) {
    }

    fn transform_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _new_transform: wl_output::Transform,
    ) {
    }

    fn frame(
        &mut self,
        conn: &Connection,
        qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _time: u32,
    ) {
        self.draw(conn, qh);
    }

    fn surface_enter(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }

    fn surface_leave(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }
}

impl OutputHandler for Smoke {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output_state
    }

    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl WindowHandler for Smoke {
    fn request_close(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &Window) {
        self.exit = true;
    }

    fn configure(
        &mut self,
        conn: &Connection,
        qh: &QueueHandle<Self>,
        _window: &Window,
        configure: WindowConfigure,
        _serial: u32,
    ) {
        // kiosk 会把窗口配置为输出尺寸 + Maximized + Activated。
        self.buffer = None;
        self.width = configure.new_size.0.map(|v| v.get()).unwrap_or(64);
        self.height = configure.new_size.1.map(|v| v.get()).unwrap_or(64);
        println!("configure: {}x{} {:?}", self.width, self.height, configure);

        if self.first_configure {
            self.first_configure = false;
            self.draw(conn, qh);
        }
    }
}

impl ShmHandler for Smoke {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

impl Smoke {
    fn draw(&mut self, _conn: &Connection, qh: &QueueHandle<Self>) {
        let width = self.width.max(1);
        let height = self.height.max(1);
        let stride = width as i32 * 4;

        // 缓冲尺寸变化时重建；否则复用（合成器未释放时创建备用缓冲实现双缓冲）。
        let need_new = self
            .buffer
            .as_ref()
            .and_then(|b| self.pool.canvas(b))
            .is_none();
        let buffer = if need_new {
            let (buf, _) = match self.pool.create_buffer(
                width as i32,
                height as i32,
                stride,
                wl_shm::Format::Xrgb8888,
            ) {
                Ok(v) => v,
                Err(err) => {
                    eprintln!("创建 shm 缓冲失败: {err}");
                    return;
                }
            };
            self.buffer = Some(buf);
            self.buffer.as_ref().unwrap()
        } else {
            self.buffer.as_ref().unwrap()
        };

        let Some(canvas) = self.pool.canvas(buffer) else {
            return;
        };

        // 生成流动的 Archoera 配色渐变（暗底 + 青/紫光带）。
        let phase = self.phase;
        for (index, chunk) in canvas.chunks_exact_mut(4).enumerate() {
            let x = (index % width as usize) as u32;
            let y = (index / width as usize) as u32;
            let wave = ((x + phase) / 24 + y / 24) % 2;
            let (r, g, b) = if wave == 0 {
                (0x0E, 0x11, 0x17)
            } else {
                (0x2A, 0x9D, 0x8F)
            };
            // Xrgb8888：直接写 little-endian 的 B,G,R,X。
            let array: &mut [u8; 4] = chunk.try_into().unwrap();
            *array = [b as u8, g as u8, r as u8, 0xFF];
        }

        self.phase = self.phase.wrapping_add(2);

        let surface = self.window.wl_surface();
        surface.damage_buffer(0, 0, width as i32, height as i32);
        surface.frame(qh, surface.clone());
        let _ = buffer.attach_to(surface);
        self.window.commit();
    }
}

delegate_compositor!(Smoke);
delegate_output!(Smoke);
delegate_shm!(Smoke);
delegate_xdg_shell!(Smoke);
delegate_xdg_window!(Smoke);
delegate_registry!(Smoke);

impl ProvidesRegistryState for Smoke {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry_state
    }
    registry_handlers![OutputState];
}
