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
    output::{Output, Scale},
    utils::{Rectangle, Transform},
};

use crate::{
    cli::{BackendKind, TransformKind},
    CalloopData,
};

mod winit;

#[cfg(feature = "udev")]
mod udev;

/// kiosk 桌面底色（对齐 ArchoeraMusic `AppPalette.dark.surface` #0E1117）。
pub const CLEAR_COLOR: [f32; 4] = [0.0549, 0.0667, 0.0902, 1.0];

/// f64 缩放倍数 → smithay 输出缩放。
///
/// 整数用 [`Scale::Integer`]；分数用 [`Scale::Custom`]（`wl_output` 取整向上，
/// 真值经 `wp_fractional_scale_v1` 下发，客户端可据此清晰渲染）。
pub fn output_scale(scale: f64) -> Scale {
    let integral = scale.fract().abs() < f64::EPSILON;
    if integral && scale >= 1.0 {
        Scale::Integer(scale.round() as i32)
    } else {
        Scale::Custom {
            advertised_integer: scale.ceil().max(1.0) as i32,
            fractional: scale,
        }
    }
}

/// CLI 变换枚举 → smithay 输出变换。
pub fn output_transform(kind: TransformKind) -> Transform {
    match kind {
        TransformKind::Normal => Transform::Normal,
        TransformKind::R90 => Transform::_90,
        TransformKind::R180 => Transform::_180,
        TransformKind::R270 => Transform::_270,
        TransformKind::Flipped => Transform::Flipped,
        TransformKind::Flipped90 => Transform::Flipped90,
        TransformKind::Flipped180 => Transform::Flipped180,
        TransformKind::Flipped270 => Transform::Flipped270,
    }
}

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
// udev 变体较大（DrmOutputManager 等）；kiosk 单实例，省一次间接寻址比省 7KB 更值。
#[allow(clippy::large_enum_variant)]
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

    /// 请求下一帧：把「需要重绘」落到具体后端。
    ///
    /// - winit：请求一次窗口重绘，合成在 `WinitEvent::Redraw` 里发生；
    /// - udev：没有重绘事件，直接同步合成一帧，由下一次 vblank 回收。
    #[cfg_attr(not(feature = "udev"), allow(unused_variables))]
    pub fn request_frame(&mut self, space: &Space<Window>) -> anyhow::Result<()> {
        match self {
            Backend::Winit(backend) => {
                backend.request_redraw();
                Ok(())
            }
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.render(space),
        }
    }

    /// 开关屏幕（DPMS）。仅 udev 后端实现（暂停 / 激活 DRM 输出管理器）；
    /// 嵌套后端不置位该能力，这里为无操作。
    #[cfg_attr(not(feature = "udev"), allow(unused_variables))]
    pub fn set_screen_power(&mut self, enabled: bool) -> anyhow::Result<()> {
        match self {
            Backend::Winit(_) => Ok(()),
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.set_screen_power(enabled),
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
