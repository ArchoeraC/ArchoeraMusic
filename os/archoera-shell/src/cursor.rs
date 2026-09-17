//! 指针光标：加载 XCursor 主题并把当前光标合成为渲染元素。
//!
//! 光标来源按优先级：
//! 1. 客户端 `wl_pointer.set_cursor` 给出的 surface（GTK/Flutter 的常规路径）；
//! 2. 命名形状（`zwp_cursor_shape_v1` 或客户端未给 surface 时）——从 `XCURSOR_THEME`
//!    指定的系统主题按形状名加载（`cursor_icon::CursorIcon::name()` 即 XCursor 名）；
//! 3. 主题不可用时的内置兜底位图（`resources/cursor.rgba`）。
//!
//! 合成器在 Wayland 派发回调里更新 [`PointerElement::set_status`]，在每帧渲染时用
//! [`PointerElement::render_elements`] 生成一个位于指针热点处的光标元素。

use std::{collections::HashMap, io::Read, sync::Mutex};

use smithay::{
    backend::{
        allocator::Fourcc,
        renderer::{
            element::{
                memory::{MemoryRenderBuffer, MemoryRenderBufferRenderElement},
                surface::{render_elements_from_surface_tree, WaylandSurfaceRenderElement},
                Kind,
            },
            gles::GlesRenderer,
            ImportAll, ImportMem,
        },
    },
    input::pointer::{CursorIcon, CursorImageAttributes, CursorImageStatus},
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    utils::{IsAlive, Logical, Physical, Point, Scale, Transform},
    wayland::compositor::with_states,
};
use xcursor::{
    parser::{parse_xcursor, Image},
    CursorTheme,
};

/// 主题缺失时的兜底光标（32×32 预乘 RGBA，热点 (1,1)）。
static FALLBACK_CURSOR_RGBA: &[u8] = include_bytes!("../resources/cursor.rgba");
const FALLBACK_SIZE: i32 = 32;

// 光标渲染元素：客户端 surface 或主题位图。
smithay::backend::renderer::element::render_elements! {
    pub CursorRenderElement<R> where R: ImportAll + ImportMem;
    Surface = WaylandSurfaceRenderElement<R>,
    Memory = MemoryRenderBufferRenderElement<R>,
}

/// 已加载好的一帧光标位图。
#[derive(Clone)]
struct CursorImage {
    buffer: MemoryRenderBuffer,
    hotspot: Point<i32, Logical>,
}

/// 指针光标状态（当前形状 + 形状位图缓存 + 指针位置）。
pub struct PointerElement {
    status: CursorImageStatus,
    /// 当前命名形状对应的位图。
    image: CursorImage,
    /// XCursor 主题（`XCURSOR_THEME`，缺省 `default`）。
    theme: Option<CursorTheme>,
    /// 形状名 → 位图（主题加载成功时缓存）。
    cache: HashMap<String, CursorImage>,
    /// 指针逻辑坐标（相对输出布局原点）。
    location: Point<f64, Logical>,
}

impl Default for PointerElement {
    fn default() -> Self {
        Self::new()
    }
}

impl PointerElement {
    pub fn new() -> Self {
        let theme_name = std::env::var("XCURSOR_THEME").unwrap_or_else(|_| "default".into());
        let theme = CursorTheme::load(&theme_name);
        // 启动即加载主题默认光标：客户端在给出命名形状之前（或只给了空 surface 时）
        // 也能显示与系统一致的光标，而不是内置兜底位图。
        let themed = load_shape(&theme, "default").or_else(|| load_shape(&theme, "left_ptr"));
        tracing::info!(
            theme = %theme_name,
            themed = themed.is_some(),
            size = %std::env::var("XCURSOR_SIZE").as_deref().unwrap_or("24"),
            "已加载光标主题"
        );
        let image = themed.unwrap_or_else(fallback_image);
        Self {
            status: CursorImageStatus::default_named(),
            image,
            theme: Some(theme),
            cache: HashMap::new(),
            location: (0.0, 0.0).into(),
        }
    }

    /// 由 `SeatHandler::cursor_image` 调用：记录客户端要求的光标形状。
    pub fn set_status(&mut self, status: CursorImageStatus) {
        tracing::debug!(?status, "光标状态更新");
        if let CursorImageStatus::Named(icon) = &status {
            self.image = self.image_for(icon);
        }
        self.status = status;
    }

    /// 指针移动到 `location`（逻辑坐标，相对输出布局原点）。
    pub fn set_location(&mut self, location: Point<f64, Logical>) {
        self.location = location;
    }

    pub fn location(&self) -> Point<f64, Logical> {
        self.location
    }

    /// 按形状名加载（带缓存）；失败时回退兜底位图。
    fn image_for(&mut self, icon: &CursorIcon) -> CursorImage {
        let name = icon.name();
        if let Some(image) = self.cache.get(name) {
            return image.clone();
        }
        let image = self
            .theme
            .as_ref()
            .and_then(|theme| load_shape(theme, name))
            .or_else(|| {
                self.theme
                    .as_ref()
                    .and_then(|theme| load_shape(theme, "default"))
            })
            .unwrap_or_else(fallback_image);
        self.cache.insert(name.to_string(), image.clone());
        image
    }

    /// 生成当前光标在 `output_position`（逻辑坐标，相对该输出左上角）处的元素。
    pub fn render_elements(
        &self,
        renderer: &mut GlesRenderer,
        output_position: Point<f64, Logical>,
        scale: Scale<f64>,
        alpha: f32,
    ) -> Vec<CursorRenderElement<GlesRenderer>> {
        match &self.status {
            CursorImageStatus::Hidden => Vec::new(),
            CursorImageStatus::Named(_) => self.named_elements(renderer, output_position, scale),
            CursorImageStatus::Surface(surface) => {
                if surface.alive() {
                    let hotspot = cursor_hotspot(surface);
                    let location = physical_location(output_position, hotspot, scale);
                    let elements: Vec<CursorRenderElement<GlesRenderer>> =
                        render_elements_from_surface_tree(
                            renderer,
                            surface,
                            location,
                            scale,
                            alpha,
                            Kind::Cursor,
                        )
                        .into_iter()
                        .map(CursorRenderElement::Surface)
                        .collect();
                    if !elements.is_empty() {
                        tracing::debug!(count = elements.len(), "渲染客户端 cursor surface");
                        return elements;
                    }
                }
                // 客户端给了没有缓冲的 cursor surface（典型：GTK 主题查找失败后仍调用
                // `wl_pointer.set_cursor`，只挂了一个空 surface）。此时若照渲染就是「指针
                // 凭空消失」；退回命名默认光标保证指针始终可见。
                tracing::debug!("客户端 cursor surface 不可渲染，回退命名默认光标");
                self.named_elements(renderer, output_position, scale)
            }
        }
    }

    /// 命名形状（主题位图）的光标元素。
    fn named_elements(
        &self,
        renderer: &mut GlesRenderer,
        output_position: Point<f64, Logical>,
        scale: Scale<f64>,
    ) -> Vec<CursorRenderElement<GlesRenderer>> {
        let location = physical_location(output_position, self.image.hotspot, scale);
        match MemoryRenderBufferRenderElement::from_buffer(
            renderer,
            location.to_f64(),
            &self.image.buffer,
            None,
            None,
            None,
            Kind::Cursor,
        ) {
            Ok(element) => vec![CursorRenderElement::Memory(element)],
            Err(err) => {
                tracing::warn!(%err, "光标位图导入失败");
                Vec::new()
            }
        }
    }
}

/// 逻辑坐标（减热点）→ 该输出的物理像素坐标。
fn physical_location(
    position: Point<f64, Logical>,
    hotspot: Point<i32, Logical>,
    scale: Scale<f64>,
) -> Point<i32, Physical> {
    (position - hotspot.to_f64())
        .to_physical(scale)
        .to_i32_round()
}

/// 读取客户端设置的热点（`wl_pointer.set_cursor` 的 hotspot_x/y）。
fn cursor_hotspot(surface: &WlSurface) -> Point<i32, Logical> {
    with_states(surface, |states| {
        states
            .data_map
            .get::<Mutex<CursorImageAttributes>>()
            .map(|attrs| attrs.lock().unwrap().hotspot)
    })
    .unwrap_or_default()
}

/// 从主题解析某个形状，选出与 `XCURSOR_SIZE` 最接近的一帧。
fn load_shape(theme: &CursorTheme, name: &str) -> Option<CursorImage> {
    let path = theme.load_icon(name)?;
    let mut data = Vec::new();
    std::fs::File::open(path)
        .ok()?
        .read_to_end(&mut data)
        .ok()?;
    let images = parse_xcursor(&data)?;
    let size = std::env::var("XCURSOR_SIZE")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(24) as i32;
    let image = nearest_image(size, &images)?;
    let buffer = buffer_from_image(image);
    Some(CursorImage {
        buffer,
        hotspot: (image.xhot as i32, image.yhot as i32).into(),
    })
}

/// 选择标称尺寸最接近目标者（同尺寸多帧时取第一帧）。
fn nearest_image(size: i32, images: &[Image]) -> Option<&Image> {
    images
        .iter()
        .min_by_key(|image| (size - image.size as i32).abs())
}

fn buffer_from_image(image: &Image) -> MemoryRenderBuffer {
    MemoryRenderBuffer::from_slice(
        &image.pixels_rgba,
        Fourcc::Argb8888,
        (image.width as i32, image.height as i32),
        1,
        Transform::Normal,
        None,
    )
}

fn fallback_image() -> CursorImage {
    CursorImage {
        buffer: MemoryRenderBuffer::from_slice(
            FALLBACK_CURSOR_RGBA,
            Fourcc::Argb8888,
            (FALLBACK_SIZE, FALLBACK_SIZE),
            1,
            Transform::Normal,
            None,
        ),
        hotspot: (1, 1).into(),
    }
}
