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
    desktop::{space::render_output, space::SpaceRenderElements, Space, Window},
    output::{Output, Scale},
    utils::{Rectangle, Transform},
};

use crate::{
    cli::{BackendKind, TransformKind},
    cursor::{CursorRenderElement, PointerElement},
    CalloopData,
};

mod winit;

#[cfg(feature = "udev")]
mod udev;

/// kiosk 桌面底色（对齐 ArchoeraMusic `AppPalette.dark.surface` #0E1117）。
pub const CLEAR_COLOR: [f32; 4] = [0.0549, 0.0667, 0.0902, 1.0];

// 每个输出的一帧渲染元素：桌面内容 + 指针光标（光标最后绘制，位于最上层）。
smithay::backend::renderer::element::render_elements! {
    pub OutputElement<=GlesRenderer>;
    Space = SpaceRenderElements<GlesRenderer, WaylandSurfaceRenderElement<GlesRenderer>>,
    Cursor = CursorRenderElement<GlesRenderer>,
}

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

/// 输出变换 → 协议 `output_transform` 数值（与 `wl_output.transform` 一致）。
pub fn transform_code(transform: Transform) -> u32 {
    match transform {
        Transform::Normal => 0,
        Transform::_90 => 1,
        Transform::_180 => 2,
        Transform::_270 => 3,
        Transform::Flipped => 4,
        Transform::Flipped90 => 5,
        Transform::Flipped180 => 6,
        Transform::Flipped270 => 7,
    }
}

/// 协议 `output_transform` 数值 → 输出变换。
pub fn transform_from_code(code: u32) -> Transform {
    match code {
        1 => Transform::_90,
        2 => Transform::_180,
        3 => Transform::_270,
        4 => Transform::Flipped,
        5 => Transform::Flipped90,
        6 => Transform::Flipped180,
        7 => Transform::Flipped270,
        _ => Transform::Normal,
    }
}

/// winit 嵌套后端的渲染状态。
pub struct WinitBackend {
    graphics: WinitGraphicsBackend<GlesRenderer>,
    output: Output,
    damage_tracker: OutputDamageTracker,
}

impl WinitBackend {
    fn render(&mut self, space: &Space<Window>, _pointer: &PointerElement) -> anyhow::Result<()> {
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

    /// 合成并提交一帧（渲染 `space` 的全部输出 + 指针光标）。
    pub fn render(
        &mut self,
        space: &Space<Window>,
        pointer: &PointerElement,
    ) -> anyhow::Result<()> {
        match self {
            Backend::Winit(backend) => backend.render(space, pointer),
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.render(space, pointer),
        }
    }

    /// 请求下一帧：把「需要重绘」落到具体后端。
    ///
    /// - winit：请求一次窗口重绘，合成在 `WinitEvent::Redraw` 里发生；
    /// - udev：没有重绘事件，直接同步合成一帧，由下一次 vblank 回收。
    #[cfg_attr(not(feature = "udev"), allow(unused_variables))]
    pub fn request_frame(
        &mut self,
        space: &Space<Window>,
        pointer: &PointerElement,
    ) -> anyhow::Result<()> {
        match self {
            Backend::Winit(backend) => {
                backend.request_redraw();
                Ok(())
            }
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.render(space, pointer),
        }
    }

    /// 按输出名 + 模式索引切换 DRM 模式；嵌套后端无操作。
    #[cfg_attr(not(feature = "udev"), allow(unused_variables))]
    pub fn set_output_mode_index(
        &mut self,
        name: &str,
        index: usize,
    ) -> anyhow::Result<Option<smithay::output::Mode>> {
        match self {
            Backend::Winit(_) => Ok(None),
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.set_output_mode_index(name, index),
        }
    }

    /// 各输出的（连接器名, 模式列表）；嵌套后端没有真实输出，返回空。
    pub fn output_meta(&self) -> Vec<OutputMeta> {
        match self {
            Backend::Winit(_) => Vec::new(),
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.output_meta(),
        }
    }

    /// 上一次 `render()` 是否真的提交了帧（udev 空帧不提交，也就没有 vblank）。
    /// 用于把「一帧在飞行中」的多次脏标记合并成一次合成，同时避免空帧把门控卡死。
    #[cfg_attr(not(feature = "udev"), allow(unused_variables))]
    pub fn last_render_queued(&self) -> bool {
        match self {
            Backend::Winit(_) => false,
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.frame_queued,
        }
    }

    /// 切换 VT（Ctrl+Alt+Fn 转发给 libseat/logind）。
    ///
    /// DRM/KMS 会话处于 `KD_GRAPHICS` 时内核**不再处理** VT 切换组合键，必须由合成器转发，
    /// 否则用户无法切到 tty（安装器的 tty2 也进不去）。
    #[cfg_attr(not(feature = "udev"), allow(unused_variables))]
    pub fn change_vt(&mut self, vt: i32) -> anyhow::Result<()> {
        match self {
            Backend::Winit(_) => Ok(()), // 嵌套后端无 VT 概念
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.change_vt(vt),
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

    /// 应用输出配置到硬件：切换 DRM 模式（udev）等；返回实际生效的模式。
    ///
    /// 缩放/变换只改 `wl_output` 状态，无需硬件动作；模式切换必须走 DRM。
    #[cfg_attr(not(feature = "udev"), allow(unused_variables))]
    pub fn apply_output_config(
        &mut self,
        scale: f64,
        transform: Transform,
        mode: Option<(i32, i32)>,
    ) -> anyhow::Result<Option<smithay::output::Mode>> {
        match self {
            Backend::Winit(_) => Ok(None),
            #[cfg(feature = "udev")]
            Backend::Udev(backend) => backend.apply_output_config(scale, transform, mode),
        }
    }
}

/// 一个显示模式：(宽, 高, 刷新率 mHz)。
pub type OutputMode = (i32, i32, u32);

/// 一个输出的元数据：(连接器名, 模式列表)。
pub type OutputMeta = (String, Vec<OutputMode>);

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transform_code_round_trips_every_kind() {
        for kind in [
            TransformKind::Normal,
            TransformKind::R90,
            TransformKind::R180,
            TransformKind::R270,
            TransformKind::Flipped,
            TransformKind::Flipped90,
            TransformKind::Flipped180,
            TransformKind::Flipped270,
        ] {
            let transform = output_transform(kind);
            assert_eq!(transform_from_code(transform_code(transform)), transform);
        }
    }

    #[test]
    fn unknown_transform_code_falls_back_to_normal() {
        assert_eq!(transform_from_code(42), Transform::Normal);
    }

    #[test]
    fn output_scale_distinguishes_integral_and_fractional() {
        assert_eq!(output_scale(2.0).fractional_scale(), 2.0);
        assert_eq!(output_scale(1.0).fractional_scale(), 1.0);
        match output_scale(1.5) {
            Scale::Custom {
                advertised_integer,
                fractional,
            } => {
                assert_eq!(advertised_integer, 2);
                assert!((fractional - 1.5).abs() < f64::EPSILON);
            }
            other => panic!("期望分数缩放，得到 {other:?}"),
        }
    }
}
