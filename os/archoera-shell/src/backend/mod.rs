//! 后端选择与渲染后端抽象。
//!
//! - `winit`：嵌套运行在已有 Wayland / X11 / WSLg 会话中，用于开发与集成测试；
//! - `udev`：直接接管 DRM/KMS + libinput，用于裸机 / 虚拟机控制台（需 `--features udev`）。
//!
//! 两种后端都用同一个 `GlesRenderer`。后端对象**上提到共享状态**（而不是关在事件回调里），
//! 目的有二：
//! 1. `zwp_linux_dmabuf_v1` 的 `dmabuf_imported` 需要**同步**拿到 renderer 导入缓冲；
//! 2. 渲染所需的 `Output` / `OutputDamageTracker` / DRM 输出与后端生命周期一致。
//!
//! 因此 `Backend` 自己持有渲染所需的一切，对外只暴露 `render(space)`。

use smithay::{
    backend::{
        renderer::{
            damage::OutputDamageTracker, element::surface::WaylandSurfaceRenderElement,
            gles::GlesRenderer,
        },
        winit::WinitGraphicsBackend,
    },
    desktop::{space::render_output, Space, Window},
    output::Output,
    utils::Rectangle,
};

use crate::{cli::BackendKind, CalloopData};

mod winit;

#[cfg(feature = "udev")]
mod udev;

/// kiosk 桌面底色（对齐 ArchoeraMusic `AppPalette.dark.surface` #0E1117）。
pub const CLEAR_COLOR: [f32; 4] = [0.0549, 0.0667, 0.0902, 1.0];

/// winit 嵌套后端的渲染状态。
pub struct WinitBackend {
    graphics: WinitGraphicsBackend<GlesRenderer>,
    output: Output,
    damage_tracker: OutputDamageTracker,
}

impl WinitBackend {
    fn render(&mut self, space: &Space<Window>) -> anyhow::Result<()> {
        let damage = Rectangle::from_size(self.graphics.window_size());
        {
            let (renderer, mut framebuffer) = self
                .graphics
                .bind()
                .map_err(|e| anyhow::anyhow!("绑定 winit 帧缓冲失败: {e}"))?;
            render_output::<_, WaylandSurfaceRenderElement<GlesRenderer>, _, _>(
                &self.output,
                renderer,
                &mut framebuffer,
                1.0,
                0,
                [space],
                &[],
                &mut self.damage_tracker,
                CLEAR_COLOR,
            )
            .map_err(|e| anyhow::anyhow!("合成输出失败: {e:?}"))?;
        }
        self.graphics
            .submit(Some(&[damage]))
            .map_err(|e| anyhow::anyhow!("提交帧缓冲失败: {e}"))?;
        Ok(())
    }

    fn renderer(&mut self) -> &mut GlesRenderer {
        self.graphics.renderer()
    }

    fn request_redraw(&self) {
        self.graphics.window().request_redraw();
    }
}

/// 渲染后端。持有 renderer，因此需要长期存活在共享状态里。
pub enum Backend {
    /// 嵌套窗口（winit）。
    Winit(WinitBackend),
    /// 裸机 DRM/KMS + libinput。
    #[cfg(feature = "udev")]
    Udev(udev::UdevBackend),
}

impl Backend {
    /// 可变借用底层渲染器（dmabuf 导入 / 格式查询用）。
    pub fn renderer(&mut self) -> &mut GlesRenderer {
        match self {
            Backend::Winit(backend) => backend.renderer(),
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.renderer(),
        }
    }

    /// 合成并提交一帧（渲染 `space` 的全部输出）。
    pub fn render(&mut self, space: &Space<Window>) -> anyhow::Result<()> {
        match self {
            Backend::Winit(backend) => backend.render(space),
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.render(space),
        }
    }

    /// 请求下一帧重绘（winit 需要显式请求；udev 由 vblank 驱动）。
    pub fn request_redraw(&self) {
        match self {
            Backend::Winit(backend) => backend.request_redraw(),
            #[cfg(feature = "udev")]
            Backend::Udev(_) => {}
        }
    }
}

/// 按配置初始化渲染/输入后端。
pub fn init(
    event_loop: &mut smithay::reexports::calloop::EventLoop<CalloopData>,
    data: &mut CalloopData,
) -> anyhow::Result<()> {
    match data.state.config.backend {
        BackendKind::Winit => winit::init_winit(event_loop, data),
        #[cfg(feature = "udev")]
        BackendKind::Udev => udev::init_udev(event_loop, data),
        #[cfg(not(feature = "udev"))]
        BackendKind::Udev => anyhow::bail!(
            "本次构建未启用 udev 后端；请以 `cargo build --features udev` 构建，\
             并确保系统已安装 libseat / libinput / libdrm / gbm / libudev"
        ),
    }
}
